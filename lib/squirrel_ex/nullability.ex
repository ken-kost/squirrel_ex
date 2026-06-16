defmodule SquirrelEx.Nullability do
  @moduledoc """
  Infers result-column nullability by asking PostgreSQL to `EXPLAIN` the query.

  The describe step (`Postgrex.prepare/4`) does not report nullability, so a
  column produced by a `LEFT`/`RIGHT`/`FULL JOIN` would otherwise be mis-typed as
  non-`nil`. For each query we run

      EXPLAIN (format json, verbose, generic_plan) <sql>

  via the **simple** query protocol (so the embedded `$n` placeholders are left
  for `generic_plan` to handle rather than bound as Postgrex parameters — this
  requires PostgreSQL 16+). We then:

    1. walk the plan tree, marking every relation alias on the nullable side of
       an outer join (`Left` -> inner, `Right` -> outer, `Full` -> both);
    2. align the top node's verbose `Output` expressions with the result columns
       and, for each plain column reference, decide a verdict from the join set
       and the base column's `pg_attribute.attnotnull`.

  Returns one verdict per column: `:nullable`, `:not_null`, or `:unknown`
  (anything we cannot prove — computed expressions, un-EXPLAIN-able statements).
  `SquirrelEx.Query` resolves these against the explicit `?`/`!` annotations and
  the `:default_nullable` config.
  """

  @type verdict :: :nullable | :not_null | :unknown

  @doc """
  Returns a list of nullability verdicts, one per entry in `column_names`
  (in order). Falls back to all-`:unknown` whenever the query cannot be planned.
  """
  @spec verdicts(pid() | atom() | nil, String.t(), [String.t()]) :: [verdict()]
  def verdicts(conn, sql, column_names)

  def verdicts(_conn, _sql, []), do: []
  def verdicts(nil, _sql, names), do: unknown(names)

  def verdicts(conn, sql, names) do
    with {:ok, plan} <- explain(conn, sql),
         outputs when is_list(outputs) <- plan["Output"] do
      nullable_aliases = nullable_aliases(plan, false, MapSet.new())
      alias_rel = alias_relations(plan, %{})
      attnotnull = attnotnull_lookup(conn, Map.values(alias_rel))

      outputs
      |> Enum.take(length(names))
      |> pad(length(names))
      |> Enum.map(&verdict(&1, nullable_aliases, alias_rel, attnotnull))
    else
      _ -> unknown(names)
    end
  end

  defp unknown(names), do: Enum.map(names, fn _ -> :unknown end)

  defp pad(list, n) when length(list) >= n, do: list
  defp pad(list, n), do: list ++ List.duplicate(nil, n - length(list))

  # --- EXPLAIN -------------------------------------------------------------

  defp explain(conn, sql) do
    statement = "EXPLAIN (format json, verbose, generic_plan) " <> sql

    try do
      case Postgrex.query(conn, statement, [], query_type: :text) do
        {:ok, %{rows: [[raw]]}} -> decode_plan(raw)
        _ -> :error
      end
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp decode_plan(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, [%{"Plan" => plan} | _]} -> {:ok, plan}
      _ -> :error
    end
  end

  defp decode_plan([%{"Plan" => plan} | _]), do: {:ok, plan}
  defp decode_plan(_), do: :error

  # --- Join walk -----------------------------------------------------------

  # Collects the set of relation aliases whose rows can be NULL-extended by an
  # outer join. `forced?` is inherited down from an ancestor nullable branch.
  defp nullable_aliases(node, forced?, acc) do
    acc = if forced? and node["Alias"], do: MapSet.put(acc, node["Alias"]), else: acc
    join_type = node["Join Type"]

    node
    |> Map.get("Plans", [])
    |> Enum.reduce(acc, fn child, acc ->
      nullable_aliases(child, forced? or child_nullable?(join_type, child), acc)
    end)
  end

  defp child_nullable?("Full", _child), do: true
  defp child_nullable?("Left", child), do: child["Parent Relationship"] == "Inner"
  defp child_nullable?("Right", child), do: child["Parent Relationship"] == "Outer"
  defp child_nullable?(_join_type, _child), do: false

  # Maps every relation alias in the plan to its {schema, relation} pair.
  defp alias_relations(node, acc) do
    acc =
      case {node["Alias"] || node["Relation Name"], node["Relation Name"]} do
        {alias, rel} when is_binary(alias) and is_binary(rel) ->
          Map.put(acc, alias, {node["Schema"] || "public", rel})

        _ ->
          acc
      end

    node
    |> Map.get("Plans", [])
    |> Enum.reduce(acc, &alias_relations/2)
  end

  # --- attnotnull lookup ---------------------------------------------------

  defp attnotnull_lookup(_conn, []), do: %{}

  defp attnotnull_lookup(conn, relations) do
    {schemas, names} = relations |> Enum.uniq() |> Enum.unzip()

    query = """
    SELECT n.nspname, c.relname, a.attname, a.attnotnull
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE a.attnum > 0 AND NOT a.attisdropped
      AND n.nspname = ANY($1) AND c.relname = ANY($2)
    """

    case Postgrex.query(conn, query, [Enum.uniq(schemas), Enum.uniq(names)]) do
      {:ok, %{rows: rows}} ->
        Map.new(rows, fn [schema, rel, col, notnull] -> {{schema, rel, col}, notnull} end)

      _ ->
        %{}
    end
  end

  # --- Per-column verdict --------------------------------------------------

  defp verdict(nil, _nullable, _alias_rel, _attnotnull), do: :unknown

  defp verdict(output, nullable_aliases, alias_rel, attnotnull) do
    case parse_column_ref(output) do
      {qualifier, column} ->
        qualifier = qualifier || sole_alias(alias_rel)
        from_join_or_catalog(qualifier, column, nullable_aliases, alias_rel, attnotnull)

      :expression ->
        :unknown
    end
  end

  defp from_join_or_catalog(nil, _column, _nullable, _alias_rel, _attnotnull), do: :unknown

  defp from_join_or_catalog(qualifier, column, nullable_aliases, alias_rel, attnotnull) do
    cond do
      MapSet.member?(nullable_aliases, qualifier) ->
        :nullable

      rel = Map.get(alias_rel, qualifier) ->
        {schema, relname} = rel

        case Map.get(attnotnull, {schema, relname, column}) do
          true -> :not_null
          false -> :nullable
          nil -> :unknown
        end

      true ->
        :unknown
    end
  end

  defp sole_alias(alias_rel) do
    case Map.keys(alias_rel) do
      [only] -> only
      _ -> nil
    end
  end

  # Parses a verbose Output expression. Returns `{qualifier, column}` for a plain
  # column reference (qualifier is nil when unqualified), or `:expression` for
  # anything computed (functions, casts, literals, operators, ...).
  @qualified ~r/\A([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\z/
  @bare ~r/\A([a-z_][a-z0-9_]*)\z/

  defp parse_column_ref(expr) do
    cond do
      caps = Regex.run(@qualified, expr) -> {Enum.at(caps, 1), Enum.at(caps, 2)}
      caps = Regex.run(@bare, expr) -> {nil, Enum.at(caps, 1)}
      true -> :expression
    end
  end
end

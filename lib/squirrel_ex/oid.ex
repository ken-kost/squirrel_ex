defmodule SquirrelEx.Oid do
  @moduledoc """
  Maps PostgreSQL type OIDs to Ecto types and Elixir typespecs.

  The well-known builtin OIDs are compiled into PostgreSQL and stable across
  installations, so we hardcode them. Any OID not in the table (custom types,
  enums, domains) is resolved at compile time with a `pg_type` lookup via
  `resolve/2`.
  """

  @typedoc "An Elixir typespec fragment, e.g. `\"integer()\"`."
  @type typespec :: String.t()

  @typedoc "An Ecto type, e.g. `:integer` or `Ecto.UUID`."
  @type ecto_type :: term()

  # {oid, typename, ecto_type, typespec}
  @builtins [
    {16, "bool", :boolean, "boolean()"},
    {17, "bytea", :binary, "binary()"},
    {18, "char", :string, "String.t()"},
    {19, "name", :string, "String.t()"},
    {20, "int8", :integer, "integer()"},
    {21, "int2", :integer, "integer()"},
    {23, "int4", :integer, "integer()"},
    {25, "text", :string, "String.t()"},
    {114, "json", :map, "map()"},
    {700, "float4", :float, "float()"},
    {701, "float8", :float, "float()"},
    {1042, "bpchar", :string, "String.t()"},
    {1043, "varchar", :string, "String.t()"},
    {1082, "date", :date, "Date.t()"},
    {1083, "time", :time, "Time.t()"},
    {1114, "timestamp", :naive_datetime, "NaiveDateTime.t()"},
    {1184, "timestamptz", :utc_datetime, "DateTime.t()"},
    {1700, "numeric", :decimal, "Decimal.t()"},
    {2950, "uuid", Ecto.UUID, "String.t()"},
    {3802, "jsonb", :map, "map()"}
  ]

  @by_oid Map.new(@builtins, fn {oid, name, ecto, spec} -> {oid, {name, ecto, spec}} end)

  @doc """
  Returns `{:ok, {ecto_type, typespec}}` for a known builtin OID, or `:error`.
  """
  @spec fetch(non_neg_integer()) :: {:ok, {ecto_type(), typespec()}} | :error
  def fetch(oid) do
    case Map.fetch(@by_oid, oid) do
      {:ok, {_name, ecto, spec}} -> {:ok, {ecto, spec}}
      :error -> :error
    end
  end

  @doc "Returns the builtin type name for an OID, or `nil`."
  @spec name(non_neg_integer()) :: String.t() | nil
  def name(oid) do
    case Map.fetch(@by_oid, oid) do
      {:ok, {name, _ecto, _spec}} -> name
      :error -> nil
    end
  end

  @doc """
  Resolves a list of OIDs to `{ecto_type, typespec}` pairs (in order).

  Builtin OIDs are resolved from the static table. Unknown OIDs are looked up in
  `pg_type` through `conn` in a single query: enums (`typtype = 'e'`) map to
  `:string`/`String.t()`; any other unknown maps to a permissive `term()` and is
  reported in the returned warnings list.

  Returns `{:ok, [{ecto_type, typespec}], warnings}` where `warnings` is a list
  of human-readable strings about unmapped types.
  """
  @spec resolve([non_neg_integer()], pid() | atom()) ::
          {:ok, [{ecto_type(), typespec()}], [String.t()]}
  def resolve(oids, conn) do
    unknown = oids |> Enum.reject(&Map.has_key?(@by_oid, &1)) |> Enum.uniq()
    {catalog, warnings} = lookup_unknown(unknown, conn)

    pairs =
      Enum.map(oids, fn oid ->
        case Map.fetch(@by_oid, oid) do
          {:ok, {_name, ecto, spec}} -> {ecto, spec}
          :error -> Map.get(catalog, oid, {:string, "term()"})
        end
      end)

    {:ok, pairs, warnings}
  end

  defp lookup_unknown([], _conn), do: {%{}, []}

  defp lookup_unknown(oids, conn) do
    query = "SELECT oid, typname, typtype FROM pg_type WHERE oid = ANY($1)"

    case Postgrex.query(conn, query, [oids]) do
      {:ok, %{rows: rows}} ->
        found = Map.new(rows, fn [oid, _name, _type] -> {oid, true} end)

        catalog =
          Map.new(rows, fn
            [oid, _name, "e"] -> {oid, {:string, "String.t()"}}
            [oid, _name, _other] -> {oid, {:string, "term()"}}
          end)

        warnings =
          for [oid, name, type] <- rows, type != "e" do
            "unsupported PostgreSQL type #{inspect(name)} (oid #{oid}); generated as a permissive `term()`"
          end

        missing =
          for oid <- oids, not Map.has_key?(found, oid) do
            "unknown PostgreSQL type oid #{oid}; generated as a permissive `term()`"
          end

        {catalog, warnings ++ missing}

      {:error, _} ->
        warnings =
          Enum.map(oids, &"could not resolve PostgreSQL type oid #{&1}; generated as `term()`")

        {%{}, warnings}
    end
  end
end

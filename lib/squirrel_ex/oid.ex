defmodule SquirrelEx.Oid do
  @moduledoc """
  Maps PostgreSQL type OIDs to `SquirrelEx.Type` structs (Ecto type + Elixir
  typespec + runtime decoder).

  The well-known builtin OIDs are compiled into PostgreSQL and stable across
  installations, so we hardcode them — including the common array OIDs. Any OID
  not in the table (custom types, enums, domains, exotic arrays) is resolved at
  compile time with a `pg_type` lookup via `resolve/3`:

    * enums (`typtype = 'e'`) expand to an atom-union typespec (`:a | :b`) and a
      `String.to_existing_atom/1` decoder, their variants fetched from `pg_enum`;
    * arrays (`typcategory = 'A'`) resolve their element type recursively and
      wrap the typespec in a list;
    * anything else falls back to a permissive `term()` with a warning.

  A caller-supplied override map (keyed by OID **or** PostgreSQL type name) is
  consulted before everything else, so teams can pin e.g. `numeric -> "float()"`.
  """

  alias SquirrelEx.Type

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

  # Common builtin array OIDs -> their element OID. Resolved by wrapping the
  # element type, so we never need a catalog round trip for these.
  @array_builtins %{
    1000 => 16,
    1001 => 17,
    1005 => 21,
    1007 => 23,
    1009 => 25,
    1014 => 1042,
    1015 => 1043,
    1016 => 20,
    1021 => 700,
    1022 => 701,
    1115 => 1114,
    1182 => 1082,
    1183 => 1083,
    1185 => 1184,
    1231 => 1700,
    2951 => 2950,
    199 => 114,
    3807 => 3802
  }

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
  Resolves a list of OIDs to `SquirrelEx.Type` structs (in order).

  ## Options

    * `:overrides` — a map keyed by OID (integer) or PostgreSQL type name
      (string) whose value is a typespec string (e.g. `%{"numeric" => "float()"}`)
      or a `{ecto_type, typespec}` tuple. Consulted before the builtin table.

  Returns `{:ok, [SquirrelEx.Type.t()], warnings}` where `warnings` is a list of
  human-readable strings about unmapped types.
  """
  @spec resolve([non_neg_integer()], pid() | atom() | nil, keyword()) ::
          {:ok, [Type.t()], [String.t()]}
  def resolve(oids, conn, opts \\ []) do
    overrides = Keyword.get(opts, :overrides, %{})

    {types, warnings} =
      Enum.map_reduce(oids, [], fn oid, warns ->
        {type, w} = resolve_one(oid, conn, overrides)
        {type, warns ++ w}
      end)

    {:ok, types, warnings}
  end

  # Resolves a single OID to a {Type.t(), warnings} pair.
  defp resolve_one(oid, conn, overrides) do
    case override(overrides, oid, name(oid)) do
      nil -> resolve_known(oid, conn, overrides)
      type -> {type, []}
    end
  end

  defp resolve_known(oid, conn, overrides) do
    cond do
      builtin = Map.get(@by_oid, oid) ->
        {_name, ecto, spec} = builtin
        {Type.simple(spec, ecto), []}

      elem_oid = Map.get(@array_builtins, oid) ->
        {elem, w} = resolve_one(elem_oid, conn, overrides)
        {wrap_array(elem), w}

      true ->
        resolve_catalog(oid, conn, overrides)
    end
  end

  # Looks up an OID we do not recognise statically in the pg_type catalog.
  defp resolve_catalog(oid, nil, _overrides) do
    {%Type{}, ["could not resolve PostgreSQL type oid #{oid}; generated as `term()`"]}
  end

  defp resolve_catalog(oid, conn, overrides) do
    query = """
    SELECT typname, typtype, typcategory, typelem
    FROM pg_type WHERE oid = $1
    """

    case Postgrex.query(conn, query, [oid]) do
      {:ok, %{rows: [[name, typtype, typcategory, typelem]]}} ->
        case override(overrides, oid, name) do
          nil -> resolve_catalog_row(oid, name, typtype, typcategory, typelem, conn, overrides)
          type -> {type, []}
        end

      _ ->
        {%Type{}, ["unknown PostgreSQL type oid #{oid}; generated as a permissive `term()`"]}
    end
  end

  defp resolve_catalog_row(_oid, name, "e", _category, _elem, conn, _overrides) do
    {enum_type(name, conn), []}
  end

  defp resolve_catalog_row(_oid, _name, _typtype, "A", elem_oid, conn, overrides)
       when is_integer(elem_oid) and elem_oid != 0 do
    {elem, w} = resolve_one(elem_oid, conn, overrides)
    {wrap_array(elem), w}
  end

  defp resolve_catalog_row(oid, name, _typtype, _category, _elem, _conn, _overrides) do
    {%Type{},
     [
       "unsupported PostgreSQL type #{inspect(name)} (oid #{oid}); generated as a permissive `term()`"
     ]}
  end

  # Builds the atom-union type for an enum from its `pg_enum` variants.
  defp enum_type(name, conn) do
    variants = enum_variants(name, conn)

    case variants do
      [] ->
        %Type{typespec: "atom()", input: "String.t()", decoder: :enum, ecto: :string, enum: []}

      _ ->
        union = Enum.map_join(variants, " | ", &":#{atomish(&1)}")

        %Type{
          typespec: union,
          input: "String.t()",
          decoder: :enum,
          ecto: Ecto.Enum,
          enum: variants
        }
    end
  end

  defp enum_variants(_name, nil), do: []

  defp enum_variants(name, conn) do
    query = """
    SELECT e.enumlabel
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    WHERE t.typname = $1
    ORDER BY e.enumsortorder
    """

    case Postgrex.query(conn, query, [name]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [label] -> label end)
      _ -> []
    end
  end

  # Wraps a resolved element type into a one-dimensional array type. The describe
  # step does not report array dimensionality, so we default to a single level
  # (matching the Gleam squirrel).
  defp wrap_array(%Type{} = elem) do
    decoder =
      case elem.decoder do
        :enum -> :enum_array
        other -> other
      end

    %Type{
      typespec: "[#{elem.typespec}]",
      input: "[#{Type.input_typespec(elem)}]",
      decoder: decoder,
      ecto: if(elem.ecto, do: {:array, elem.ecto}),
      enum: elem.enum
    }
  end

  # Resolves an override value (a typespec string or {ecto, typespec} tuple) into
  # a Type, or nil if there is no override for this OID/name.
  defp override(overrides, oid, name) when is_map(overrides) do
    case Map.get(overrides, oid) || (name && Map.get(overrides, name)) do
      nil -> nil
      spec when is_binary(spec) -> Type.simple(spec)
      {ecto, spec} when is_binary(spec) -> Type.simple(spec, ecto)
    end
  end

  defp override(_overrides, _oid, _name), do: nil

  # Enum labels are arbitrary text; produce a best-effort atom literal. Labels
  # that are not already valid unquoted atoms are wrapped via inspect.
  defp atomish(label) do
    if Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*[?!]?\z/, label) do
      label
    else
      inspect(label)
      |> String.replace_prefix(":", "")
    end
  end
end

defmodule SquirrelEx.Introspection do
  @moduledoc """
  Programmatic, compile-time introspection of a single SQL statement — the same
  pipeline that backs code generation (Parse/Describe → OID resolution →
  `EXPLAIN` nullability → parameter naming), but returning structured metadata
  instead of writing an `.ex` file.

  This is the entry point for consumers that introspect SQL they hold in memory
  (e.g. an inline `~SQL` sigil) rather than `.sql` files. The returned shape is
  identical to the generated `__squirrel__/0` accessor:

      %{
        sql: "select id, status from posts where author_id = $1",
        params: [%{name: "author_id", type: "integer()", ecto: :integer}],
        columns: [
          %{name: "id", type: "Ecto.UUID.raw()", ecto: Ecto.UUID, nullable: false, enum: nil},
          %{name: "status", type: ":draft | :published | nil", ecto: Ecto.Enum,
            nullable: true, enum: ["draft", "published"]}
        ]
      }

  ## Caching

  Pass `:manifest` (a file path) to memoize results by content hash. The cache
  key is the SQL plus the options that affect the result (`:overrides`,
  `:default_nullable`), so a hit returns instantly **without querying the
  database** — and the `conn` argument is not used. This is what keeps inline
  introspection from hammering the DB on every compile. A miss introspects via
  `conn`, writes the result back to the manifest, and returns it.
  """

  alias SquirrelEx.{Introspector, Manifest, Nullability, Oid, Params, Query}

  @typedoc "The metadata returned for a statement (mirrors `__squirrel__/0`)."
  @type metadata :: %{sql: String.t(), params: [map()], columns: [map()]}

  @doc """
  Returns `{:ok, metadata}` for `sql`, or `{:error, reason}`.

  `conn` is a started `Postgrex` connection (see `SquirrelEx.Introspector.connect/1`).
  It may be `nil` only when the result is already cached in `:manifest`; a cache
  miss with no connection returns `{:error, :no_connection}`.

  ## Options

    * `:overrides` — type override map (see `SquirrelEx.Oid.resolve/3`)
    * `:default_nullable` — nullability default for unprovable columns (default `false`)
    * `:manifest` — path to a content-hash cache file (optional)
  """
  @spec metadata(pid() | atom() | nil, String.t(), keyword()) ::
          {:ok, metadata()} | {:error, term()}
  def metadata(conn, sql, opts \\ []) do
    manifest_path = Keyword.get(opts, :manifest)
    key = cache_key(sql, opts)

    case cache_get(manifest_path, key) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        with {:ok, meta} <- introspect(conn, sql, opts) do
          cache_put(manifest_path, key, meta)
          {:ok, meta}
        end
    end
  end

  # --- introspection -------------------------------------------------------

  defp introspect(nil, _sql, _opts), do: {:error, :no_connection}

  defp introspect(conn, sql, opts) do
    overrides = Keyword.get(opts, :overrides, %{})
    default_nullable = Keyword.get(opts, :default_nullable, false)
    {clean, annotations, _doc, _directives} = Query.parse_source(sql)

    case Introspector.introspect(conn, clean) do
      {:ok, %{params: param_oids, columns: columns}} ->
        {:ok, param_types, _w1} = Oid.resolve(param_oids, conn, overrides: overrides)
        {col_names, col_oids} = Enum.unzip(columns)
        {:ok, col_types, _w2} = Oid.resolve(col_oids, conn, overrides: overrides)
        verdicts = Nullability.verdicts(conn, clean, col_names)

        query =
          Query.build(
            namespace: "Inline",
            sql_path: "inline.sql",
            rel_path: "inline",
            clean_sql: clean,
            annotations: annotations,
            param_names: Params.names(clean, length(param_oids)),
            param_types: param_types,
            columns: Enum.zip(col_names, col_types),
            nullability: verdicts,
            default_nullable: default_nullable
          )

        {:ok, Query.metadata(query)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- cache ---------------------------------------------------------------

  defp cache_key(sql, opts) do
    relevant =
      {sql, Keyword.get(opts, :overrides, %{}), Keyword.get(opts, :default_nullable, false)}

    Manifest.hash(:erlang.term_to_binary(relevant))
  end

  defp cache_get(nil, _key), do: :miss

  defp cache_get(path, key) do
    case Manifest.read(path) do
      %{^key => meta} -> {:ok, meta}
      _ -> :miss
    end
  end

  defp cache_put(nil, _key, _meta), do: :ok

  defp cache_put(path, key, meta) do
    cache = Manifest.read(path)
    Manifest.write(path, Map.put(cache, key, meta))
  end
end

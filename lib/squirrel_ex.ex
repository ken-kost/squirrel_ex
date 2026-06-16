defmodule SquirrelEx do
  @moduledoc """
  Type-safe SQL for Elixir.

  Write plain `.sql` files (one query per file) under `priv/sql/`. On every
  `mix compile`, the `:squirrel_ex` compiler introspects each query against a
  live PostgreSQL database — learning its parameter types and result column
  names + types — and generates a typed wrapper module *next to* the `.sql`
  file (`priv/sql/list_posts.sql` → `priv/sql/list_posts.ex`).

  The generated module is committed to source control, readable by your IDE,
  and carries a `DO NOT EDIT` header. It exposes a typed `run/N`:

      {:ok, rows} = MyApp.Sql.ListPosts.run(MyApp.Repo, "elixir")

  See the README for host-application setup. This module is the programmatic
  engine behind `Mix.Tasks.Compile.SquirrelEx`; you normally interact with it
  through `mix compile`.
  """

  alias SquirrelEx.{Codegen, Diagnostic, Introspector, Manifest, Oid, Params, Query}

  @typedoc "Result of a compilation run, mirroring `Mix.Task.Compiler.run/1`."
  @type result :: {:ok | :noop | :error, [Mix.Task.Compiler.Diagnostic.t()]}

  @doc """
  Runs the full generate-from-SQL pipeline.

  ## Options

    * `:sql_paths` — list of globs to search (required)
    * `:namespace` — output module namespace (required)
    * `:connection` — `Postgrex.start_link/1` opts (required if anything is stale)
    * `:manifest` — path to the incremental-build manifest (required)
    * `:cwd` — base directory for display paths (default `File.cwd!/0`)
    * `:default_nullable` — unannotated columns nullable? (default `false`)
  """
  @spec run(keyword()) :: result()
  def run(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    manifest_path = Keyword.fetch!(opts, :manifest)

    files =
      opts
      |> Keyword.fetch!(:sql_paths)
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()

    manifest = Manifest.read(manifest_path)
    {stale, orphans} = Manifest.diff(files, manifest)

    Enum.each(orphans, &File.rm/1)
    manifest = Map.drop(manifest, orphaned_keys(manifest, files))

    cond do
      files == [] ->
        {:noop, []}

      stale == [] ->
        Manifest.write(manifest_path, manifest)
        {:noop, []}

      true ->
        compile_stale(stale, manifest, manifest_path, opts, cwd)
    end
  end

  defp compile_stale(stale, manifest, manifest_path, opts, cwd) do
    namespace = Keyword.fetch!(opts, :namespace)
    default_nullable = Keyword.get(opts, :default_nullable, false)

    case Introspector.connect(Keyword.fetch!(opts, :connection)) do
      {:ok, conn} ->
        results =
          try do
            Enum.map(stale, fn sql_path ->
              {sql_path, generate(conn, sql_path, namespace, default_nullable, cwd)}
            end)
          after
            Introspector.disconnect(conn)
          end

        finish(results, manifest, manifest_path)

      {:error, reason} ->
        {:error, [Diagnostic.error(hd(stale), connection_message(reason))]}
    end
  end

  # Generates one file. Returns `{:ok, entry, warnings}` or `{:error, diagnostic}`.
  defp generate(conn, sql_path, namespace, default_nullable, cwd) do
    raw = File.read!(sql_path)
    {clean, annotations, doc} = Query.parse_source(raw)

    case Introspector.introspect(conn, clean) do
      {:ok, %{params: param_oids, columns: columns}} ->
        {:ok, param_specs, w1} = Oid.resolve(param_oids, conn)
        {col_names, col_oids} = Enum.unzip(columns)
        {:ok, col_specs, w2} = Oid.resolve(col_oids, conn)

        query =
          Query.build(
            namespace: namespace,
            sql_path: sql_path,
            rel_path: Path.relative_to(sql_path, cwd),
            clean_sql: clean,
            doc: doc,
            annotations: annotations,
            param_names: Params.names(clean, length(param_oids)),
            param_typespecs: Enum.map(param_specs, fn {_ecto, spec} -> spec end),
            columns: Enum.zip(col_names, Enum.map(col_specs, fn {_ecto, spec} -> spec end)),
            default_nullable: default_nullable
          )

        source = Codegen.generate(query)
        File.write!(query.ex_path, source)

        warnings = Enum.map(w1 ++ w2, &Diagnostic.warning(sql_path, &1))
        {:ok, %{hash: Manifest.hash(raw), generated: query.ex_path}, warnings}

      {:error, %Postgrex.Error{} = error} ->
        {:error, Diagnostic.from_postgrex(sql_path, clean, error)}

      {:error, other} ->
        {:error, Diagnostic.error(sql_path, "introspection failed: #{inspect(other)}")}
    end
  end

  defp finish(results, manifest, manifest_path) do
    {manifest, diagnostics, errored?} =
      Enum.reduce(results, {manifest, [], false}, fn
        {sql_path, {:ok, entry, warnings}}, {man, diags, err?} ->
          {Map.put(man, sql_path, entry), diags ++ warnings, err?}

        {_sql_path, {:error, diagnostic}}, {man, diags, _err?} ->
          {man, diags ++ [diagnostic], true}
      end)

    Manifest.write(manifest_path, manifest)

    status = if errored?, do: :error, else: :ok
    {status, diagnostics}
  end

  defp orphaned_keys(manifest, files) do
    current = MapSet.new(files)
    for {sql_path, _} <- manifest, not MapSet.member?(current, sql_path), do: sql_path
  end

  defp connection_message(reason) do
    "could not connect to PostgreSQL for query introspection: #{inspect(reason)}"
  end
end

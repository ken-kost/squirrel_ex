defmodule SquirrelEx do
  @moduledoc """
  Type-safe SQL for Elixir.

  Write plain `.sql` files (one query per file) under `priv/sql/`. On every
  `mix compile`, the `:squirrel_ex` compiler introspects each query against a
  live PostgreSQL database — learning its parameter types and result column
  names + types, and (via `EXPLAIN`) their nullability — and generates a typed
  wrapper module *next to* the `.sql` file (`priv/sql/list_posts.sql` →
  `priv/sql/list_posts.ex`).

  The generated module is committed to source control, readable by your IDE,
  and carries a `DO NOT EDIT` header. It exposes a typed `run/N`:

      {:ok, rows} = MyApp.Sql.ListPosts.run(MyApp.Repo, "elixir")

  See the README for host-application setup. This module is the programmatic
  engine behind `Mix.Tasks.Compile.SquirrelEx`; you normally interact with it
  through `mix compile`.
  """

  alias SquirrelEx.{Codegen, Diagnostic, Introspector, Manifest, Nullability, Oid, Params, Query}

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
    * `:row_type` — `:struct` (default) or `:map`
    * `:mode` — `:full` (default) or `:metadata` (types + `__squirrel__/0` only)
    * `:overrides` — type override map (default `%{}`)
    * `:repo` — bake this repo into `run/N` (default `nil`)
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
    gen_opts = %{
      namespace: Keyword.fetch!(opts, :namespace),
      default_nullable: Keyword.get(opts, :default_nullable, false),
      row_type: Keyword.get(opts, :row_type, :struct),
      overrides: Keyword.get(opts, :overrides, %{}),
      repo: Keyword.get(opts, :repo),
      mode: Keyword.get(opts, :mode, :full),
      cwd: cwd
    }

    case Introspector.connect(Keyword.fetch!(opts, :connection)) do
      {:ok, conn} ->
        results =
          try do
            Enum.map(stale, fn sql_path ->
              {sql_path, generate(conn, sql_path, gen_opts)}
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
  defp generate(conn, sql_path, gen_opts) do
    :telemetry.span([:squirrel_ex, :generate], %{sql_path: sql_path}, fn ->
      {do_generate(conn, sql_path, gen_opts), %{sql_path: sql_path}}
    end)
  end

  defp do_generate(conn, sql_path, gen_opts) do
    raw = File.read!(sql_path)
    {clean, annotations, doc, directives} = Query.parse_source(raw)

    case Introspector.introspect(conn, clean) do
      {:ok, %{params: param_oids, columns: columns}} ->
        {:ok, param_types, w1} = Oid.resolve(param_oids, conn, overrides: gen_opts.overrides)
        {col_names, col_oids} = Enum.unzip(columns)
        {:ok, col_types, w2} = Oid.resolve(col_oids, conn, overrides: gen_opts.overrides)
        verdicts = Nullability.verdicts(conn, clean, col_names)

        query =
          Query.build(
            namespace: gen_opts.namespace,
            sql_path: sql_path,
            rel_path: Path.relative_to(sql_path, gen_opts.cwd),
            clean_sql: clean,
            doc: doc,
            annotations: annotations,
            directives: directives,
            param_names: Params.names(clean, length(param_oids)),
            param_types: param_types,
            columns: Enum.zip(col_names, col_types),
            nullability: verdicts,
            default_nullable: gen_opts.default_nullable,
            row_type: gen_opts.row_type,
            repo: gen_opts.repo,
            mode: gen_opts.mode
          )

        write_generated(query, sql_path, raw, w1 ++ w2)

      {:error, %Postgrex.Error{} = error} ->
        {:error, Diagnostic.from_postgrex(sql_path, clean, error)}

      {:error, other} ->
        {:error, Diagnostic.error(sql_path, "introspection failed: #{inspect(other)}")}
    end
  end

  # Writes the generated module, refusing to clobber a file that lacks our header
  # (i.e. one a developer has hand-edited or hand-written).
  defp write_generated(query, sql_path, raw, warnings) do
    if clobber?(query.ex_path) do
      {:error,
       Diagnostic.error(
         query.ex_path,
         "refusing to overwrite #{Path.relative_to_cwd(query.ex_path)}: it is missing the " <>
           "squirrel_ex header, so it looks hand-edited. Delete it to regenerate from #{Path.basename(sql_path)}."
       )}
    else
      source = Codegen.generate(query)
      File.write!(query.ex_path, source)
      warnings = Enum.map(warnings, &Diagnostic.warning(sql_path, &1))
      {:ok, %{hash: Manifest.hash(raw), generated: query.ex_path}, warnings}
    end
  end

  defp clobber?(ex_path) do
    case File.read(ex_path) do
      {:ok, existing} -> not String.starts_with?(existing, Codegen.header())
      _ -> false
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

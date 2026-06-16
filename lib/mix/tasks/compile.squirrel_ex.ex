defmodule Mix.Tasks.Compile.SquirrelEx do
  @moduledoc """
  Mix compiler that generates typed wrapper modules from `.sql` files by
  introspecting PostgreSQL.

  Register it in your host application's `mix.exs`, before the `:elixir`
  compiler, and add the SQL directory to `elixirc_paths` so the generated
  modules get compiled:

      def project do
        [
          # ...
          compilers: [:squirrel_ex] ++ Mix.compilers(),
          elixirc_paths: ["lib", "priv/sql"]
        ]
      end

  Configuration is read from `config :squirrel_ex, ...`; see `SquirrelEx.Config`.
  """

  use Mix.Task.Compiler

  alias SquirrelEx.{Config, Diagnostic}

  @recursive true
  @manifest "compile.squirrel_ex"

  @impl true
  def run(_argv) do
    targets = Config.targets()

    {status, diagnostics} =
      Enum.reduce(targets, {:noop, []}, fn target, {status, diags} ->
        {s, d} = SquirrelEx.run(target_opts(target))
        {merge_status(status, s), diags ++ d}
      end)

    diagnostics = diagnostics ++ elixirc_paths_warnings(status)
    Enum.each(diagnostics, &print_diagnostic/1)
    {status, diagnostics}
  end

  @doc false
  def target_opts(target) do
    [
      sql_paths: target.sql_paths,
      namespace: target.namespace,
      connection: target.connection,
      default_nullable: target.default_nullable,
      row_type: target.row_type,
      mode: target.mode,
      overrides: target.overrides,
      repo: target.repo,
      manifest: manifest_path(target.key),
      cwd: File.cwd!()
    ]
  end

  @impl true
  def manifests, do: Enum.map(Config.targets(), &manifest_path(&1.key))

  @impl true
  def clean do
    for target <- Config.targets() do
      path = manifest_path(target.key)

      for {_sql, %{generated: ex_path}} <- SquirrelEx.Manifest.read(path) do
        File.rm(ex_path)
      end

      File.rm(path)
    end

    :ok
  end

  defp merge_status(:error, _), do: :error
  defp merge_status(_, :error), do: :error
  defp merge_status(:ok, _), do: :ok
  defp merge_status(_, :ok), do: :ok
  defp merge_status(_, other), do: other

  defp manifest_path(:default), do: Path.join(Mix.Project.manifest_path(), @manifest)

  defp manifest_path(key),
    do: Path.join(Mix.Project.manifest_path(), "#{@manifest}.#{key}")

  # Warn (once, on a real build) if the configured SQL directories are not on
  # elixirc_paths, since the generated modules would never be compiled.
  defp elixirc_paths_warnings(:noop), do: []

  defp elixirc_paths_warnings(_status) do
    paths = Mix.Project.config()[:elixirc_paths] || ["lib"]

    Config.sql_paths()
    |> Enum.map(&sql_root/1)
    |> Enum.uniq()
    |> Enum.reject(&covered?(&1, paths))
    |> Enum.map(fn root ->
      Diagnostic.warning(
        root,
        "#{root} is not in :elixirc_paths, so generated modules there will not be compiled. " <>
          "Add it to elixirc_paths in mix.exs, e.g. elixirc_paths: [\"lib\", \"#{root}\"]."
      )
    end)
  end

  # Reduce a glob like "priv/sql/**/*.sql" to its static root "priv/sql".
  defp sql_root(glob) do
    glob
    |> Path.split()
    |> Enum.take_while(&(not String.contains?(&1, ["*", "?", "[", "{"])))
    |> Path.join()
  end

  defp covered?(root, paths) do
    Enum.any?(paths, fn p ->
      root == p or String.starts_with?(root <> "/", p <> "/")
    end)
  end

  defp print_diagnostic(%{severity: severity, message: message, file: file}) do
    label = if severity == :error, do: "error", else: "warning"
    Mix.shell().info("squirrel_ex #{label}: #{file}: #{message}")
  end
end

defmodule Mix.Tasks.SquirrelEx.Check do
  @shortdoc "Fails if any generated wrapper is stale vs its .sql (no DB needed)"

  @moduledoc """
  CI / pre-commit gate that verifies the committed generated modules are
  up to date with their `.sql` sources — **without touching the database**.

  For each configured `.sql` file it compares the file's content hash against
  the build manifest (and checks the generated `.ex` still exists). If anything
  is stale or missing, it prints the offending files and exits non-zero.

      mix squirrel_ex.check

  Run `mix compile` (or `mix squirrel_ex.gen`) and commit the result to fix a
  failure.
  """

  use Mix.Task

  alias Mix.Tasks.Compile.SquirrelEx, as: Compiler
  alias SquirrelEx.{Config, Manifest}

  @impl true
  def run(_argv) do
    Mix.Task.run("app.config")

    stale =
      Enum.flat_map(Config.targets(), fn target ->
        opts = Compiler.target_opts(target)

        files =
          opts |> Keyword.fetch!(:sql_paths) |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq()

        manifest = Manifest.read(Keyword.fetch!(opts, :manifest))
        {stale, _orphans} = Manifest.diff(files, manifest)
        stale
      end)

    case stale do
      [] ->
        Mix.shell().info("squirrel_ex: all generated modules are up to date")

      files ->
        Mix.shell().error("squirrel_ex: generated modules are stale for:")
        Enum.each(files, &Mix.shell().error("  #{&1}"))
        Mix.raise("Run `mix squirrel_ex.gen` and commit the result.")
    end
  end
end

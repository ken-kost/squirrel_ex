defmodule Mix.Tasks.SquirrelEx.Gen do
  @shortdoc "Regenerates squirrel_ex wrapper modules from .sql files"

  @moduledoc """
  Regenerates the typed wrapper modules for all configured `.sql` files,
  on demand, without relying on incremental-build staleness.

  Unlike a plain `mix compile`, this removes the build manifest first, so every
  query is re-introspected and rewritten. Useful after a schema change that does
  not alter the `.sql` text but does change result types (e.g. a column became
  `NOT NULL`).

      mix squirrel_ex.gen

  Reads the same `config :squirrel_ex` configuration as the compiler. Connects
  to the configured database.
  """

  use Mix.Task

  alias Mix.Tasks.Compile.SquirrelEx, as: Compiler
  alias SquirrelEx.Config

  @impl true
  def run(_argv) do
    Mix.Task.run("app.config")

    {status, diagnostics} =
      Enum.reduce(Config.targets(), {:noop, []}, fn target, {status, diags} ->
        opts = Compiler.target_opts(target)
        File.rm(Keyword.fetch!(opts, :manifest))
        {s, d} = SquirrelEx.run(opts)
        {worst(status, s), diags ++ d}
      end)

    Enum.each(diagnostics, fn d ->
      Mix.shell().info("squirrel_ex #{d.severity}: #{d.file}: #{d.message}")
    end)

    case status do
      :error -> Mix.raise("squirrel_ex.gen failed; see diagnostics above")
      _ -> Mix.shell().info("squirrel_ex: generation complete")
    end
  end

  defp worst(:error, _), do: :error
  defp worst(_, :error), do: :error
  defp worst(:ok, _), do: :ok
  defp worst(_, :ok), do: :ok
  defp worst(_, other), do: other
end

defmodule Mix.Tasks.SquirrelEx.Watch do
  @shortdoc "Watches .sql files and regenerates wrappers on change"

  @moduledoc """
  Watches the configured `.sql` directories and regenerates the typed wrapper
  modules whenever a `.sql` file changes — without a full `mix compile`.

      mix squirrel_ex.watch

  Generates once on start, then blocks, regenerating on each change (press
  Ctrl+C twice to stop). Reads the same `config :squirrel_ex` configuration as
  the compiler and connects to the configured database.
  """

  use Mix.Task

  alias Mix.Tasks.Compile.SquirrelEx, as: Compiler
  alias SquirrelEx.Config

  @requirements ["app.config"]

  @impl true
  def run(_argv) do
    targets = Enum.map(Config.targets(), &Compiler.target_opts/1)

    {:ok, _pid} =
      SquirrelEx.Watcher.start_link(
        targets: targets,
        log: fn msg -> Mix.shell().info(msg) end,
        name: SquirrelEx.Watcher
      )

    Mix.shell().info("squirrel_ex: watching for .sql changes (Ctrl+C twice to stop)")
    Process.sleep(:infinity)
  end
end

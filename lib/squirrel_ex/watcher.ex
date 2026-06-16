defmodule SquirrelEx.Watcher do
  @moduledoc """
  A `GenServer` that watches the configured `.sql` directories and regenerates
  the wrapper modules whenever a `.sql` file changes. Powers `mix squirrel_ex.watch`.

  It subscribes to `FileSystem` events for the static roots of each target's
  `:sql_paths`. On any `.sql` change it re-runs `SquirrelEx.run/1` for every
  target — regeneration is manifest-incremental, so only files whose content
  actually changed are rewritten.

  ## Options

    * `:targets` — a list of `SquirrelEx.run/1` option keyword lists (required)
    * `:dirs` — directories to watch (default: derived from the targets' globs)
    * `:subscribe` — whether to start a `FileSystem` watcher (default `true`);
      set to `false` in tests to drive events manually
    * `:log` — a 1-arity function for progress messages (default: `IO.puts/1`)
    * `:name` — optional GenServer name
  """

  use GenServer

  @doc "Starts the watcher. See the module doc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Derives the set of directories to watch from a list of run-option lists."
  @spec watch_dirs([keyword()]) :: [String.t()]
  def watch_dirs(targets) do
    targets
    |> Enum.flat_map(&Keyword.get(&1, :sql_paths, []))
    |> Enum.map(&glob_root/1)
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
  end

  @impl true
  def init(opts) do
    targets = Keyword.fetch!(opts, :targets)
    log = Keyword.get(opts, :log, &IO.puts/1)

    state = %{targets: targets, log: log}

    if Keyword.get(opts, :subscribe, true) do
      dirs = Keyword.get_lazy(opts, :dirs, fn -> watch_dirs(targets) end)
      {:ok, pid} = FileSystem.start_link(dirs: dirs)
      FileSystem.subscribe(pid)
    end

    # Generate once up front so the tree is current the moment the watch starts.
    regenerate(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if String.ends_with?(path, ".sql"), do: regenerate(state)
    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Re-runs every target. SquirrelEx.run/1 is manifest-incremental, so unchanged
  # files are skipped.
  defp regenerate(%{targets: targets, log: log}) do
    Enum.each(targets, fn opts ->
      case SquirrelEx.run(opts) do
        {:noop, _} ->
          :ok

        {status, diagnostics} ->
          log.("squirrel_ex: regenerated (#{status})")

          Enum.each(diagnostics, fn d ->
            log.("squirrel_ex #{d.severity}: #{d.file}: #{d.message}")
          end)
      end
    end)
  end

  # Reduces a glob like "priv/sql/**/*.sql" to its static root "priv/sql".
  defp glob_root(glob) do
    glob
    |> Path.split()
    |> Enum.take_while(&(not String.contains?(&1, ["*", "?", "[", "{"])))
    |> Path.join()
  end
end

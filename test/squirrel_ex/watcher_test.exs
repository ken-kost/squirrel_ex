defmodule SquirrelEx.WatcherTest do
  use ExUnit.Case, async: false

  alias SquirrelEx.Watcher

  describe "watch_dirs/1" do
    test "derives the static glob roots that exist on disk" do
      tmp = System.tmp_dir!()
      sub = Path.join(tmp, "sq_watch_dirs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sub)
      on_exit(fn -> File.rm_rf!(sub) end)

      targets = [
        [sql_paths: [Path.join(sub, "**/*.sql")]],
        [sql_paths: ["/definitely/missing/**/*.sql"]]
      ]

      assert Watcher.watch_dirs(targets) == [sub]
    end
  end

  describe "regeneration (driven by synthetic events)" do
    @moduletag :db

    @connection Application.compile_env!(:squirrel_ex, :connection)

    setup do
      dir = Path.join(System.tmp_dir!(), "sq_watch_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir, manifest: Path.join(dir, "manifest")}
    end

    defp target(ctx, namespace) do
      [
        sql_paths: [Path.join(ctx.dir, "*.sql")],
        namespace: namespace,
        connection: @connection,
        manifest: ctx.manifest,
        cwd: ctx.dir
      ]
    end

    test "generates once on start and regenerates on a .sql file_event", ctx do
      ns = "SquirrelEx.Watch#{System.unique_integer([:positive])}"
      sql_path = Path.join(ctx.dir, "q.sql")
      File.write!(sql_path, "select id from posts")

      {:ok, pid} =
        Watcher.start_link(targets: [target(ctx, ns)], subscribe: false, log: fn _ -> :ok end)

      # init generated the file up front.
      ex_path = Path.join(ctx.dir, "q.ex")
      assert File.exists?(ex_path)
      refute File.read!(ex_path) =~ "title"

      # Change the SQL and feed the watcher a synthetic file event.
      File.write!(sql_path, "select id, title from posts")
      send(pid, {:file_event, self(), {sql_path, [:modified]}})
      _ = :sys.get_state(pid)

      assert File.read!(ex_path) =~ "title:"
    end

    @tag :integration
    @tag timeout: 30_000
    test "regenerates from a real filesystem event (subscribe: true)", ctx do
      ns = "SquirrelEx.Watch#{System.unique_integer([:positive])}"
      sql_path = Path.join(ctx.dir, "q.sql")
      File.write!(sql_path, "select id from posts")

      {:ok, _pid} =
        Watcher.start_link(targets: [target(ctx, ns)], subscribe: true, log: fn _ -> :ok end)

      ex_path = Path.join(ctx.dir, "q.ex")
      assert File.exists?(ex_path)
      refute File.read!(ex_path) =~ "title"

      # A real edit should trigger a real inotify event and a regeneration.
      File.write!(sql_path, "select id, title from posts")

      assert eventually(fn -> File.read!(ex_path) =~ "title:" end),
             "expected the watcher to regenerate q.ex after a real file change"
    end

    # Polls `fun` until it returns true or the deadline passes.
    defp eventually(fun, attempts \\ 100) do
      Enum.reduce_while(1..attempts, false, fn _, _ ->
        if fun.() do
          {:halt, true}
        else
          Process.sleep(50)
          {:cont, false}
        end
      end)
    end

    test "ignores non-.sql events", ctx do
      ns = "SquirrelEx.Watch#{System.unique_integer([:positive])}"
      File.write!(Path.join(ctx.dir, "q.sql"), "select id from posts")

      {:ok, pid} =
        Watcher.start_link(targets: [target(ctx, ns)], subscribe: false, log: fn _ -> :ok end)

      ex_path = Path.join(ctx.dir, "q.ex")
      mtime = File.stat!(ex_path, time: :posix).mtime

      send(pid, {:file_event, self(), {Path.join(ctx.dir, "notes.txt"), [:modified]}})
      send(pid, {:file_event, self(), :stop})
      _ = :sys.get_state(pid)

      assert File.stat!(ex_path, time: :posix).mtime == mtime
    end
  end
end

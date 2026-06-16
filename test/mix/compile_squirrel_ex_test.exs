defmodule Mix.Tasks.Compile.SquirrelExTest do
  @moduledoc """
  Exercises the thin Mix compiler wrapper (config resolution, manifest path,
  diagnostics) end to end. The generation engine itself is covered in
  `SquirrelEx.IntegrationTest`.
  """

  use ExUnit.Case, async: false

  @moduletag :db

  setup do
    dir = Path.join(System.tmp_dir!(), "sq_task_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    saved = Application.get_all_env(:squirrel_ex)

    Application.put_env(:squirrel_ex, :sql_paths, [Path.join(dir, "*.sql")])
    Application.put_env(:squirrel_ex, :namespace, "SquirrelEx.TaskTest.Sql")

    on_exit(fn ->
      File.rm_rf!(dir)

      for {k, _} <- Application.get_all_env(:squirrel_ex),
          do: Application.delete_env(:squirrel_ex, k)

      for {k, v} <- saved, do: Application.put_env(:squirrel_ex, k, v)
      Mix.Tasks.Compile.SquirrelEx.clean()
    end)

    %{dir: dir}
  end

  test "run/1 generates wrappers and reports :ok", %{dir: dir} do
    File.write!(Path.join(dir, "ping.sql"), "select id from posts where id = $1")

    assert {status, diagnostics} = Mix.Tasks.Compile.SquirrelEx.run([])
    assert status == :ok
    assert is_list(diagnostics)

    ex_path = Path.join(dir, "ping.ex")
    assert File.exists?(ex_path)
    assert File.read!(ex_path) =~ "defmodule SquirrelEx.TaskTest.Sql.Ping do"

    # A second run is a no-op (manifest-backed incremental build).
    assert {:noop, []} = Mix.Tasks.Compile.SquirrelEx.run([])
  end

  test "manifests/0 points at the build manifest" do
    assert [path] = Mix.Tasks.Compile.SquirrelEx.manifests()
    assert String.ends_with?(path, "compile.squirrel_ex")
  end

  test "squirrel_ex.check passes when up to date and fails when stale", %{dir: dir} do
    sql_path = Path.join(dir, "checked.sql")
    File.write!(sql_path, "select id from posts")

    assert {:ok, _} = Mix.Tasks.Compile.SquirrelEx.run([])

    # Up to date now: does not raise.
    Mix.Tasks.SquirrelEx.Check.run([])

    # Change the .sql without regenerating -> stale -> raises.
    File.write!(sql_path, "select id, title from posts")
    assert_raise Mix.Error, fn -> Mix.Tasks.SquirrelEx.Check.run([]) end
  end

  test "squirrel_ex.gen regenerates from the .sql files", %{dir: dir} do
    sql_path = Path.join(dir, "regen.sql")
    File.write!(sql_path, "select id from posts")
    ex_path = Path.join(dir, "regen.ex")

    Mix.Tasks.SquirrelEx.Gen.run([])
    assert File.read!(ex_path) =~ "defmodule SquirrelEx.TaskTest.Sql.Regen"

    # A plain recompile afterwards is a no-op (gen left a fresh manifest).
    assert {:noop, []} = Mix.Tasks.Compile.SquirrelEx.run([])
  end
end

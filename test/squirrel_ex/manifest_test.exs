defmodule SquirrelEx.ManifestTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Manifest

  setup do
    dir = Path.join(System.tmp_dir!(), "sq_manifest_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "read returns empty map when the file is missing", %{dir: dir} do
    assert Manifest.read(Path.join(dir, "nope")) == %{}
  end

  test "write then read round-trips", %{dir: dir} do
    path = Path.join(dir, "manifest")
    manifest = %{"a.sql" => %{hash: "abc", generated: "a.ex"}}
    assert Manifest.write(path, manifest) == :ok
    assert Manifest.read(path) == manifest
  end

  test "hash is stable and content-sensitive" do
    assert Manifest.hash("select 1") == Manifest.hash("select 1")
    refute Manifest.hash("select 1") == Manifest.hash("select 2")
  end

  describe "diff/2" do
    setup %{dir: dir} do
      sql = Path.join(dir, "q.sql")
      ex = Path.join(dir, "q.ex")
      File.write!(sql, "select 1")
      File.write!(ex, "# generated")
      %{sql: sql, ex: ex}
    end

    test "a never-seen file is stale", %{sql: sql} do
      assert {[^sql], []} = Manifest.diff([sql], %{})
    end

    test "an unchanged file with an existing .ex is not stale", %{sql: sql, ex: ex} do
      manifest = %{sql => %{hash: Manifest.hash("select 1"), generated: ex}}
      assert {[], []} = Manifest.diff([sql], manifest)
    end

    test "a changed file is stale", %{sql: sql, ex: ex} do
      manifest = %{sql => %{hash: "stale", generated: ex}}
      assert {[^sql], []} = Manifest.diff([sql], manifest)
    end

    test "an unchanged file whose .ex was deleted is stale", %{sql: sql, ex: ex} do
      File.rm!(ex)
      manifest = %{sql => %{hash: Manifest.hash("select 1"), generated: ex}}
      assert {[^sql], []} = Manifest.diff([sql], manifest)
    end

    test "a deleted .sql yields its .ex as an orphan", %{sql: sql, ex: ex} do
      gone = Path.join(Path.dirname(sql), "gone.sql")

      manifest = %{
        gone => %{hash: "x", generated: ex},
        sql => %{hash: Manifest.hash("select 1"), generated: ex}
      }

      assert {[], orphans} = Manifest.diff([sql], manifest)
      assert orphans == [ex]
    end
  end
end

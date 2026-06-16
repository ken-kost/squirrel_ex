defmodule SquirrelEx.IntegrationTest do
  use SquirrelEx.Test.DataCase, async: false

  @moduletag :db

  @connection Application.compile_env!(:squirrel_ex, :connection)

  setup do
    dir = Path.join(System.tmp_dir!(), "sq_it_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, manifest: Path.join(dir, "manifest")}
  end

  defp write_sql(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp run(dir, manifest, namespace) do
    SquirrelEx.run(
      sql_paths: [Path.join(dir, "*.sql")],
      namespace: namespace,
      connection: @connection,
      manifest: manifest,
      cwd: dir
    )
  end

  test "generates a wrapper that compiles and runs against the database", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"

    write_sql(ctx.dir, "posts_by_author.sql", """
    -- Posts for an author.
    select id, title, body? from posts where author_id = $1 order by title
    """)

    assert {:ok, []} = run(ctx.dir, ctx.manifest, namespace)

    ex_path = Path.join(ctx.dir, "posts_by_author.ex")
    source = File.read!(ex_path)

    # Snapshot the salient parts of the generated source.
    assert source =~ "defmodule #{namespace}.PostsByAuthor do"
    assert source =~ "@type row :: %{id: String.t(), title: String.t(), body: String.t() | nil}"
    assert source =~ "def run(repo, author_id) do"

    # The generated module compiles...
    [{mod, _}] = Code.compile_file(ex_path)

    # ...and runs against the live database, returning correctly-shaped maps.
    Repo.query!("insert into posts (title, body, author_id) values ($1, $2, $3)", [
      "Hello",
      nil,
      42
    ])

    assert {:ok, [row]} = mod.run(Repo, 42)
    assert %{id: id, title: "Hello", body: nil} = row
    assert is_binary(id)
  end

  test "is idempotent: a second run with unchanged SQL is a no-op", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    write_sql(ctx.dir, "all.sql", "select id from posts")

    assert {:ok, []} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "all.ex")
    mtime = File.stat!(ex_path, time: :posix).mtime

    assert {:noop, []} = run(ctx.dir, ctx.manifest, namespace)
    assert File.stat!(ex_path, time: :posix).mtime == mtime
  end

  test "regenerates only when the SQL content changes", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    sql_path = write_sql(ctx.dir, "q.sql", "select id from posts")

    assert {:ok, []} = run(ctx.dir, ctx.manifest, namespace)
    refute File.read!(Path.join(ctx.dir, "q.ex")) =~ "title"

    File.write!(sql_path, "select id, title from posts")
    assert {:ok, []} = run(ctx.dir, ctx.manifest, namespace)
    assert File.read!(Path.join(ctx.dir, "q.ex")) =~ "title:"
  end

  test "removes the generated .ex when its .sql is deleted (orphan)", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    sql_path = write_sql(ctx.dir, "temp.sql", "select id from posts")
    assert {:ok, []} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "temp.ex")
    assert File.exists?(ex_path)

    File.rm!(sql_path)
    assert {:noop, []} = run(ctx.dir, ctx.manifest, namespace)
    refute File.exists?(ex_path)
  end

  test "reports a diagnostic for invalid SQL", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    write_sql(ctx.dir, "broken.sql", "select * from table_that_does_not_exist")

    assert {:error, [diagnostic]} = run(ctx.dir, ctx.manifest, namespace)
    assert diagnostic.severity == :error
    assert diagnostic.compiler_name == "squirrel_ex"
    assert diagnostic.message =~ "does not exist"
  end
end

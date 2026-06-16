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
    assert source =~ "@type row :: __MODULE__.Row.t()"
    assert source =~ "body: String.t() | nil"
    assert source =~ "def run(repo, author_id) do"

    # The generated module compiles (plus its nested Row struct)...
    mod = Module.concat(namespace, "PostsByAuthor")
    Code.compile_file(ex_path)

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

  test "left-joined columns are typed nullable without an annotation", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"

    write_sql(ctx.dir, "posts_with_author.sql", """
    select p.id, p.title, a.name as author_name
    from posts p
    left join authors a on a.id = p.author_id
    """)

    assert {:ok, _} = run(ctx.dir, ctx.manifest, namespace)
    source = File.read!(Path.join(ctx.dir, "posts_with_author.ex"))

    # author_name comes from the inner side of a LEFT JOIN -> nullable.
    assert source =~ "author_name: String.t() | nil"
    # p.title is NOT NULL in the base table and not nullable here.
    assert source =~ "title: String.t(),"
  end

  test "enum columns decode to atoms with an atom-union type", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    Repo.query!("insert into widgets (state) values ('published')")

    write_sql(ctx.dir, "widget_states.sql", "select id, state from widgets order by id")

    assert {:ok, _} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "widget_states.ex")
    source = File.read!(ex_path)

    assert source =~ "state: :draft | :published | :archived"
    assert source =~ "decode_state"

    mod = Module.concat(namespace, "WidgetStates")
    Code.compile_file(ex_path)
    assert {:ok, [row]} = mod.run(Repo)
    assert row.state == :published
  end

  test "array columns are typed as lists", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    Repo.query!("insert into taglists (tags) values (array['a','b'])")

    write_sql(ctx.dir, "tag_lists.sql", "select id, tags from taglists order by id")

    assert {:ok, _} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "tag_lists.ex")
    assert File.read!(ex_path) =~ "tags: [String.t()]"

    mod = Module.concat(namespace, "TagLists")
    Code.compile_file(ex_path)
    assert {:ok, [%{tags: ["a", "b"]}]} = mod.run(Repo)
  end

  test "the @one directive returns a single row or nil", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"

    write_sql(ctx.dir, "post_by_id.sql", """
    -- @one
    select id, title from posts where id = $1
    """)

    assert {:ok, _} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "post_by_id.ex")
    assert File.read!(ex_path) =~ "{:ok, row() | nil}"

    mod = Module.concat(namespace, "PostById")
    Code.compile_file(ex_path)

    %{rows: [[id]]} =
      Repo.query!("insert into posts (title, author_id) values ('X', 1) returning id")

    assert {:ok, %{title: "X"}} = mod.run(Repo, id)
    assert {:ok, nil} = mod.run(Repo, Ecto.UUID.bingenerate())
  end

  test "refuses to clobber a generated file that lacks the squirrel_ex header", ctx do
    namespace = "SquirrelEx.Gen#{System.unique_integer([:positive])}"
    sql_path = write_sql(ctx.dir, "guarded.sql", "select id from posts")

    assert {:ok, _} = run(ctx.dir, ctx.manifest, namespace)
    ex_path = Path.join(ctx.dir, "guarded.ex")

    # Simulate a developer hand-editing the generated file.
    File.write!(ex_path, "defmodule Hand.Edited do\n  # mine!\nend\n")
    File.write!(sql_path, "select id, title from posts")

    assert {:error, [diagnostic]} = run(ctx.dir, ctx.manifest, namespace)
    assert diagnostic.severity == :error
    assert diagnostic.message =~ "refusing to overwrite"
    # Untouched.
    assert File.read!(ex_path) =~ "Hand.Edited"
  end
end

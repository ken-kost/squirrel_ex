defmodule SquirrelEx.IntrospectionTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias SquirrelEx.Introspection

  @connection Application.compile_env!(:squirrel_ex, :connection)

  setup_all do
    {:ok, conn} = Postgrex.start_link(@connection)
    %{conn: conn}
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "sq_introspect_#{System.unique_integer([:positive])}.manifest")

    on_exit(fn -> File.rm(path) end)
    %{manifest: path}
  end

  test "returns __squirrel__-shaped metadata for a statement", %{conn: conn} do
    sql = "select id, title, body? from posts where author_id = $1"

    assert {:ok, meta} = Introspection.metadata(conn, sql)

    # SQL is annotation-stripped.
    assert meta.sql == "select id, title, body from posts where author_id = $1"

    assert meta.params == [%{name: "author_id", type: "integer()", ecto: :integer}]

    by_name = Map.new(meta.columns, &{&1.name, &1})

    assert by_name["id"] == %{
             name: "id",
             type: "Ecto.UUID.raw()",
             ecto: Ecto.UUID,
             nullable: false,
             enum: nil
           }

    assert by_name["title"].nullable == false
    assert by_name["body"].nullable == true
  end

  test "infers nullability from joins (LEFT JOIN inner side)", %{conn: conn} do
    sql = "select p.id, a.name from posts p left join authors a on a.id = p.author_id"
    assert {:ok, meta} = Introspection.metadata(conn, sql)
    by_name = Map.new(meta.columns, &{&1.name, &1})
    assert by_name["id"].nullable == false
    assert by_name["name"].nullable == true
  end

  test "caches by content hash: a hit needs no connection", %{conn: conn, manifest: path} do
    sql = "select id from posts where id = $1"

    assert {:ok, meta} = Introspection.metadata(conn, sql, manifest: path)
    # Second call with conn: nil can only succeed from the cache.
    assert {:ok, ^meta} = Introspection.metadata(nil, sql, manifest: path)
  end

  test "cache invalidates when options that affect the result change", %{
    conn: conn,
    manifest: path
  } do
    sql = "select coalesce(body, '') as b from posts"

    assert {:ok, strict} =
             Introspection.metadata(conn, sql, manifest: path, default_nullable: false)

    assert {:ok, loose} =
             Introspection.metadata(conn, sql, manifest: path, default_nullable: true)

    # The unprovable coalesce column flips with the default.
    assert hd(strict.columns).nullable == false
    assert hd(loose.columns).nullable == true
  end

  test "a cache miss with no connection returns an error", %{manifest: path} do
    assert {:error, :no_connection} =
             Introspection.metadata(nil, "select id from posts", manifest: path)
  end

  test "surfaces a Postgrex error for invalid SQL", %{conn: conn} do
    assert {:error, %Postgrex.Error{}} =
             Introspection.metadata(conn, "select * from no_such_table_here")
  end
end

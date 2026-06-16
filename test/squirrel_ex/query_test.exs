defmodule SquirrelEx.QueryTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Query

  describe "parse_source/1" do
    test "extracts the leading comment block as doc" do
      {_clean, _ann, doc, _dir} = Query.parse_source("-- One\n-- Two\nselect 1")
      assert doc == "One\nTwo"
    end

    test "returns nil doc when there is no leading comment" do
      {_clean, _ann, doc, _dir} = Query.parse_source("select 1")
      assert doc == nil
    end

    test "recognises the @one directive and excludes it from the doc" do
      {_clean, _ann, doc, dir} = Query.parse_source("-- Find a user.\n-- @one\nselect 1")
      assert doc == "Find a user."
      assert dir == %{one: true}
    end

    test "recognises the :one directive form" do
      {_clean, _ann, _doc, dir} = Query.parse_source("-- :one\nselect 1")
      assert dir == %{one: true}
    end

    test "strips `?` and `!` column annotations and records nullability" do
      {clean, ann, _doc, _dir} = Query.parse_source("select id!, body? from posts")
      assert clean == "select id, body from posts"
      assert ann == %{"id" => :not_null, "body" => :nullable}
    end

    test "does not mistake `!=` for an annotation" do
      {clean, ann, _doc, _dir} = Query.parse_source("select id from t where a != $1")
      assert clean == "select id from t where a != $1"
      assert ann == %{}
    end

    test "does not strip annotations glued to `=` (e.g. col!=$1)" do
      {clean, _ann, _doc, _dir} = Query.parse_source("select id from t where a!=$1")
      assert clean == "select id from t where a!=$1"
    end
  end

  test "module_name/2 camelizes the file name under the namespace" do
    assert Query.module_name("MyApp.Sql", "priv/sql/list_posts.sql") == "MyApp.Sql.ListPosts"

    assert Query.module_name("MyApp.Sql", "/a/b/find_user_by_email.sql") ==
             "MyApp.Sql.FindUserByEmail"
  end

  describe "build/1" do
    defp base(opts) do
      defaults = [
        namespace: "App.Sql",
        sql_path: "/x/get.sql",
        rel_path: "x/get.sql",
        clean_sql: "select a, b, c from t",
        param_names: [],
        param_typespecs: []
      ]

      Query.build(Keyword.merge(defaults, opts))
    end

    test "nullability resolution order: annotation > verdict > default" do
      query =
        base(
          columns: [{"a", "integer()"}, {"b", "String.t()"}, {"c", "String.t()"}],
          annotations: %{"c" => :not_null},
          nullability: [:nullable, :unknown, :nullable],
          default_nullable: false
        )

      # a: verdict :nullable wins over default.
      # b: verdict :unknown falls back to default false.
      # c: annotation :not_null beats verdict :nullable.
      assert Enum.map(query.columns, & &1.typespec) ==
               ["integer() | nil", "String.t()", "String.t()"]

      assert Enum.map(query.columns, & &1.nullable) == [true, false, false]
    end

    test "default_nullable: true wraps unannotated columns with unknown verdict" do
      query =
        base(clean_sql: "select a from t", columns: [{"a", "integer()"}], default_nullable: true)

      assert [%{key: "a", typespec: "integer() | nil", nullable: true}] = query.columns
    end

    test "carries the decoder from a SquirrelEx.Type" do
      enum = %SquirrelEx.Type{typespec: ":x | :y", decoder: :enum}
      query = base(clean_sql: "select s from t", columns: [{"s", enum}])
      assert [%{key: "s", decoder: :enum, typespec: ":x | :y"}] = query.columns
    end

    test "derives ex_path next to the sql_path and defaults to the struct row type" do
      query = base(clean_sql: "select 1", columns: [])
      assert query.ex_path == "/x/get.ex"
      assert query.module == "App.Sql.Get"
      assert query.row_type == :struct
    end
  end
end

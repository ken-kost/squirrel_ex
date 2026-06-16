defmodule SquirrelEx.QueryTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Query

  describe "parse_source/1" do
    test "extracts the leading comment block as doc" do
      {_clean, _ann, doc} = Query.parse_source("-- One\n-- Two\nselect 1")
      assert doc == "One\nTwo"
    end

    test "returns nil doc when there is no leading comment" do
      {_clean, _ann, doc} = Query.parse_source("select 1")
      assert doc == nil
    end

    test "strips `?` and `!` column annotations and records nullability" do
      {clean, ann, _doc} = Query.parse_source("select id!, body? from posts")
      assert clean == "select id, body from posts"
      assert ann == %{"id" => :not_null, "body" => :nullable}
    end

    test "does not mistake `!=` for an annotation" do
      {clean, ann, _doc} = Query.parse_source("select id from t where a != $1")
      assert clean == "select id from t where a != $1"
      assert ann == %{}
    end

    test "does not strip annotations glued to `=` (e.g. col!=$1)" do
      {clean, _ann, _doc} = Query.parse_source("select id from t where a!=$1")
      assert clean == "select id from t where a!=$1"
    end
  end

  test "module_name/2 camelizes the file name under the namespace" do
    assert Query.module_name("MyApp.Sql", "priv/sql/list_posts.sql") == "MyApp.Sql.ListPosts"

    assert Query.module_name("MyApp.Sql", "/a/b/find_user_by_email.sql") ==
             "MyApp.Sql.FindUserByEmail"
  end

  describe "build/1" do
    test "applies nullability: annotation wins, else default" do
      query =
        Query.build(
          namespace: "App.Sql",
          sql_path: "/x/get.sql",
          rel_path: "x/get.sql",
          clean_sql: "select a, b, c from t",
          annotations: %{"b" => :nullable, "c" => :not_null},
          param_names: [],
          param_typespecs: [],
          columns: [{"a", "integer()"}, {"b", "String.t()"}, {"c", "String.t()"}],
          default_nullable: false
        )

      assert query.columns == [
               %{key: "a", typespec: "integer()"},
               %{key: "b", typespec: "String.t() | nil"},
               %{key: "c", typespec: "String.t()"}
             ]
    end

    test "default_nullable: true wraps unannotated columns" do
      query =
        Query.build(
          namespace: "App.Sql",
          sql_path: "/x/get.sql",
          rel_path: "x/get.sql",
          clean_sql: "select a from t",
          annotations: %{},
          param_names: [],
          param_typespecs: [],
          columns: [{"a", "integer()"}],
          default_nullable: true
        )

      assert [%{key: "a", typespec: "integer() | nil"}] = query.columns
    end

    test "derives ex_path next to the sql_path" do
      query =
        Query.build(
          namespace: "App.Sql",
          sql_path: "/x/get.sql",
          rel_path: "x/get.sql",
          clean_sql: "select 1",
          param_names: [],
          param_typespecs: [],
          columns: []
        )

      assert query.ex_path == "/x/get.ex"
      assert query.module == "App.Sql.Get"
    end
  end
end

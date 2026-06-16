defmodule SquirrelEx.NullabilityTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias SquirrelEx.Nullability

  @connection Application.compile_env!(:squirrel_ex, :connection)

  setup_all do
    {:ok, conn} = Postgrex.start_link(@connection)

    Postgrex.query!(
      conn,
      "create table if not exists authors (id serial primary key, name text not null, bio text)",
      []
    )

    %{conn: conn}
  end

  defp verdicts(conn, sql, cols), do: Nullability.verdicts(conn, sql, cols)

  test "a base NOT NULL column is :not_null, a nullable column is :nullable", %{conn: conn} do
    assert [:not_null, :not_null, :nullable] =
             verdicts(conn, "select id, title, body from posts", ["id", "title", "body"])
  end

  test "LEFT JOIN makes the inner side's columns nullable, even NOT NULL ones", %{conn: conn} do
    sql = "select p.id, a.name, a.bio from posts p left join authors a on a.id = p.author_id"
    assert [:not_null, :nullable, :nullable] = verdicts(conn, sql, ["id", "name", "bio"])
  end

  test "RIGHT JOIN makes the outer side's columns nullable", %{conn: conn} do
    sql = "select p.title, a.name from posts p right join authors a on a.id = p.author_id"
    assert [:nullable, :not_null] = verdicts(conn, sql, ["title", "name"])
  end

  test "INNER JOIN keeps both sides as their base nullability", %{conn: conn} do
    sql = "select p.title, a.name, a.bio from posts p join authors a on a.id = p.author_id"
    assert [:not_null, :not_null, :nullable] = verdicts(conn, sql, ["title", "name", "bio"])
  end

  test "computed expressions are :unknown", %{conn: conn} do
    sql = "select id, upper(title) as t, coalesce(body, '') as b from posts"
    assert [:not_null, :unknown, :unknown] = verdicts(conn, sql, ["id", "t", "b"])
  end

  test "aligns correctly when ORDER BY adds a non-selected column", %{conn: conn} do
    assert [:not_null, :not_null] =
             verdicts(conn, "select id, title from posts order by author_id", ["id", "title"])
  end

  test "falls back to all-:unknown when the statement cannot be planned", %{conn: conn} do
    # A utility statement cannot be EXPLAINed with generic_plan.
    assert [:unknown] = verdicts(conn, "show timezone", ["TimeZone"])
  end

  test "returns [] for a column-less query and ignores a nil connection" do
    assert [] = Nullability.verdicts(nil, "select 1", [])
    assert [:unknown, :unknown] = Nullability.verdicts(nil, "select a, b", ["a", "b"])
  end
end

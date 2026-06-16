defmodule SquirrelEx.DiagnosticTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Diagnostic

  defp pg_error(fields), do: %Postgrex.Error{postgres: Map.new(fields)}

  test "error/2 builds a squirrel_ex diagnostic" do
    d = Diagnostic.error("a.sql", "boom")
    assert d.compiler_name == "squirrel_ex"
    assert d.severity == :error
    assert d.message == "boom"
    assert d.position == 0
  end

  test "from_postgrex renders a caret pointer at the error position" do
    sql = "select id\nfrom nope"
    # position points into the second line ("from nope"); offset 17 ~ the table name
    error =
      pg_error(%{message: "relation \"nope\" does not exist", position: "16", code: "42P01"})

    d = Diagnostic.from_postgrex("q.sql", sql, error)

    assert d.severity == :error
    assert d.message =~ "does not exist"
    assert d.message =~ "from nope"
    assert d.message =~ "^"
    # second line of SQL
    assert d.position == 2
  end

  test "from_postgrex appends a friendly SQLSTATE hint" do
    error = pg_error(%{message: "column \"x\" does not exist", position: "8", code: "42703"})
    d = Diagnostic.from_postgrex("q.sql", "select x", error)
    assert d.message =~ "hint (SQLSTATE 42703)"
    assert d.message =~ "undefined column"
  end

  test "from_postgrex without a known code omits the hint" do
    error = pg_error(%{message: "some error", code: "99999"})
    d = Diagnostic.from_postgrex("q.sql", "select 1", error)
    refute d.message =~ "hint (SQLSTATE"
  end
end

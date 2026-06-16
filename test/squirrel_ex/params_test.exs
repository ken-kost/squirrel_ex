defmodule SquirrelEx.ParamsTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Params

  test "infers names from `col = $n`" do
    assert Params.names("select * from t where id = $1", 1) == ["id"]
  end

  test "infers names from `$n = col`" do
    assert Params.names("select * from t where $1 = id", 1) == ["id"]
  end

  test "strips the table qualifier in `table.col = $n`" do
    assert Params.names("select * from users u where u.email = $1", 1) == ["email"]
  end

  test "infers names from comparison and LIKE operators" do
    sql = "select * from t where age > $1 and name ilike $2 and score <= $3"
    assert Params.names(sql, 3) == ["age", "name", "score"]
  end

  test "infers names from IN lists" do
    assert Params.names("select * from t where status in ($1)", 1) == ["status"]
  end

  test "falls back to arg<n> when nothing matches" do
    assert Params.names("select $1 + $2", 2) == ["arg1", "arg2"]
  end

  test "de-duplicates colliding names with a numeric suffix" do
    sql = "select * from t where id = $1 or id = $2"
    assert Params.names(sql, 2) == ["id", "id_2"]
  end

  test "honours placeholder ordering regardless of position in SQL" do
    sql = "select * from t where name = $2 and id = $1"
    assert Params.names(sql, 2) == ["id", "name"]
  end

  test "does not infer names from identifiers inside string literals" do
    sql = "select * from t where note = 'set id = something' and status = $1"
    assert Params.names(sql, 1) == ["status"]
  end

  test "does not infer names from inside line comments" do
    sql = "select * from t\n-- old: where id = $1\nwhere email = $1"
    assert Params.names(sql, 1) == ["email"]
  end

  test "does not infer names from inside block comments" do
    sql = "select * /* where id = $9 */ from t where slug = $1"
    assert Params.names(sql, 1) == ["slug"]
  end

  test "masks quoted identifiers but keeps real references intact" do
    sql = ~s|select * from t where "weird = col" is null and id = $1|
    assert Params.names(sql, 1) == ["id"]
  end
end

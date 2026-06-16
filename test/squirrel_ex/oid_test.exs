defmodule SquirrelEx.OidTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Oid

  describe "fetch/1" do
    test "maps well-known builtin OIDs to {ecto_type, typespec}" do
      assert {:ok, {:boolean, "boolean()"}} = Oid.fetch(16)
      assert {:ok, {:integer, "integer()"}} = Oid.fetch(23)
      assert {:ok, {:string, "String.t()"}} = Oid.fetch(25)
      assert {:ok, {Ecto.UUID, "String.t()"}} = Oid.fetch(2950)
      assert {:ok, {:decimal, "Decimal.t()"}} = Oid.fetch(1700)
      assert {:ok, {:utc_datetime, "DateTime.t()"}} = Oid.fetch(1184)
      assert {:ok, {:map, "map()"}} = Oid.fetch(3802)
    end

    test "returns :error for unknown OIDs" do
      assert :error = Oid.fetch(999_999)
    end
  end

  test "name/1 returns the builtin type name" do
    assert Oid.name(23) == "int4"
    assert Oid.name(2950) == "uuid"
    assert Oid.name(999_999) == nil
  end

  test "resolve/2 maps known OIDs without touching the database" do
    # nil connection proves no fallback query is made for builtins.
    assert {:ok, pairs, []} = Oid.resolve([23, 25, 16], nil)
    assert pairs == [{:integer, "integer()"}, {:string, "String.t()"}, {:boolean, "boolean()"}]
  end
end

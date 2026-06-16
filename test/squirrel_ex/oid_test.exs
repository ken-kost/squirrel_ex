defmodule SquirrelEx.OidTest do
  use ExUnit.Case, async: true

  alias SquirrelEx.Oid

  describe "fetch/1" do
    test "maps well-known builtin OIDs to {ecto_type, typespec}" do
      assert {:ok, {:boolean, "boolean()"}} = Oid.fetch(16)
      assert {:ok, {:integer, "integer()"}} = Oid.fetch(23)
      assert {:ok, {:string, "String.t()"}} = Oid.fetch(25)
      assert {:ok, {Ecto.UUID, "Ecto.UUID.raw()"}} = Oid.fetch(2950)
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
    assert {:ok, types, []} = Oid.resolve([23, 25, 16], nil)
    assert Enum.map(types, & &1.typespec) == ["integer()", "String.t()", "boolean()"]
    assert Enum.all?(types, &(&1.decoder == :identity))
  end

  test "resolve/2 wraps builtin array OIDs in a list typespec" do
    assert {:ok, [int_array, text_array], []} = Oid.resolve([1007, 1009], nil)
    assert int_array.typespec == "[integer()]"
    assert text_array.typespec == "[String.t()]"
    assert int_array.decoder == :identity
  end

  test "resolve/3 consults the override map by OID and by type name" do
    assert {:ok, [a, b], []} =
             Oid.resolve([1700, 23], nil,
               overrides: %{"numeric" => "float()", 23 => "pos_integer()"}
             )

    assert a.typespec == "float()"
    assert b.typespec == "pos_integer()"
  end

  test "resolve/2 returns a permissive term() with a warning when conn is nil and OID is unknown" do
    assert {:ok, [type], [warning]} = Oid.resolve([999_999], nil)
    assert type.typespec == "term()"
    assert warning =~ "999999"
  end
end

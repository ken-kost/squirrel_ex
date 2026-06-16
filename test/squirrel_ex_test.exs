defmodule SquirrelExTest do
  use ExUnit.Case
  doctest SquirrelEx

  test "greets the world" do
    assert SquirrelEx.hello() == :world
  end
end

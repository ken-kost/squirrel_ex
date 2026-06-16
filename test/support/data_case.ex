defmodule SquirrelEx.Test.DataCase do
  @moduledoc """
  Test case for `:db`-tagged tests that need the live PostgreSQL repo.

  Checks out a sandboxed connection so each test runs in its own transaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias SquirrelEx.Test.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SquirrelEx.Test.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end

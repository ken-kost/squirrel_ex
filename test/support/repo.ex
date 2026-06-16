defmodule SquirrelEx.Test.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :squirrel_ex, adapter: Ecto.Adapters.Postgres
end

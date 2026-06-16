import Config

# Connection used by the squirrel_ex compiler when introspecting fixtures,
# and by the test support repo. Overridable through standard PG env vars.
config :squirrel_ex,
  connection: [
    hostname: System.get_env("PGHOST", "localhost"),
    port: String.to_integer(System.get_env("PGPORT", "5432")),
    username: System.get_env("PGUSER", "postgres"),
    password: System.get_env("PGPASSWORD", "postgres"),
    database: System.get_env("PGDATABASE", "squirrel_ex_test")
  ]

config :squirrel_ex, SquirrelEx.Test.Repo,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: System.get_env("PGDATABASE", "squirrel_ex_test"),
  pool: Ecto.Adapters.SQL.Sandbox

config :squirrel_ex, ecto_repos: [SquirrelEx.Test.Repo]

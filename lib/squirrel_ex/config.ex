defmodule SquirrelEx.Config do
  @moduledoc """
  Resolves squirrel_ex's compile-time configuration from application env, with
  sensible fallbacks to standard PostgreSQL environment variables.

  Read from `config :squirrel_ex, ...`:

    * `:connection` — a keyword list passed to `Postgrex.start_link/1`
      (`hostname`, `port`, `username`, `password`, `database`). Highest priority.
    * `:otp_app` — when `:connection` is absent, derive the connection from this
      app's configured Ecto `:repo`.
    * `:repo` — the `Ecto.Repo` the generated `run/N` calls at runtime. Defaults
      to `<CamelizedOtpApp>.Repo`.
    * `:namespace` — output module namespace. Defaults to `<CamelizedOtpApp>.Sql`.
    * `:sql_paths` — globs to search. Defaults to `["priv/sql/**/*.sql"]`.
    * `:default_nullable` — whether unannotated result columns are nullable.
      Defaults to `false`.

  When no `:connection` and no usable repo config are found, falls back to
  `DATABASE_URL` or the `PG*` environment variables.
  """

  @doc "Returns the keyword list of options for `Postgrex.start_link/1`."
  @spec connection_opts() :: keyword()
  def connection_opts do
    cond do
      conn = get(:connection) -> conn
      repo_conn = repo_connection() -> repo_conn
      true -> env_connection()
    end
  end

  @doc "Globs to search for `.sql` files."
  @spec sql_paths() :: [String.t()]
  def sql_paths, do: get(:sql_paths, ["priv/sql/**/*.sql"])

  @doc "The output module namespace, e.g. `\"MyApp.Sql\"`."
  @spec namespace() :: String.t()
  def namespace do
    case get(:namespace) do
      nil -> camelized_app() <> ".Sql"
      ns when is_binary(ns) -> ns
      ns when is_atom(ns) -> ns |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    end
  end

  @doc "Whether unannotated result columns default to nullable."
  @spec default_nullable?() :: boolean()
  def default_nullable?, do: get(:default_nullable, false)

  defp get(key, default \\ nil), do: Application.get_env(:squirrel_ex, key, default)

  defp otp_app, do: get(:otp_app)

  defp camelized_app do
    case otp_app() do
      nil -> "Sql"
      app -> app |> Atom.to_string() |> Macro.camelize()
    end
  end

  defp repo_connection do
    with app when not is_nil(app) <- otp_app(),
         repo when not is_nil(repo) <- get(:repo) || default_repo(),
         opts when is_list(opts) <- Application.get_env(app, repo) do
      Keyword.take(opts, [:hostname, :port, :username, :password, :database, :socket_dir, :url])
    else
      _ -> nil
    end
  end

  defp default_repo do
    case otp_app() do
      nil -> nil
      _ -> Module.concat([camelized_app(), "Repo"])
    end
  end

  defp env_connection do
    case System.get_env("DATABASE_URL") do
      url when is_binary(url) and url != "" ->
        [url: url]

      _ ->
        [
          hostname: System.get_env("PGHOST", "localhost"),
          port: System.get_env("PGPORT", "5432") |> String.to_integer(),
          username: System.get_env("PGUSER", "postgres"),
          password: System.get_env("PGPASSWORD", "postgres"),
          database: System.get_env("PGDATABASE", "postgres")
        ]
    end
  end
end

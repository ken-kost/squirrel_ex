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
    * `:row_type` — `:struct` (default) generates a `<Query>.Row` struct;
      `:map` returns plain maps with atom keys.
    * `:mode` — `:full` (default) emits a runtime `run/N`; `:metadata` emits only
      the types and the `__squirrel__/0` accessor.
    * `:bake_repo` — when `true`, the configured `:repo` is baked into `run/N`
      so callers don't pass it.
    * `:type_overrides` — a map keyed by OID (integer) or PostgreSQL type name
      (string) to a typespec string (or `{ecto, typespec}`), consulted before the
      builtin type table.
    * `:timestamp_type` — convenience override for `timestamptz`: `:naive_datetime`
      maps it to `NaiveDateTime.t()`. (Equivalent to a `:type_overrides` entry.)
    * `:repos` — a keyed list for multi-database projects; each entry is a
      keyword list overriding any of the above for one target. When present, the
      compiler runs once per entry.

  When no `:connection` and no usable repo config are found, falls back to
  `DATABASE_URL` or the `PG*` environment variables.
  """

  @doc """
  Returns the list of compile targets, one per `:repos` entry (or a single
  target derived from the flat top-level config).

  Each target is a map with `:key`, `:sql_paths`, `:namespace`, `:connection`,
  `:default_nullable`, `:row_type`, `:mode`, `:repo`, and `:overrides`.
  """
  @spec targets() :: [map()]
  def targets do
    case get(:repos) do
      nil ->
        [target(:default, [])]

      repos when is_list(repos) ->
        Enum.map(repos, fn {key, opts} -> target(key, opts) end)
    end
  end

  defp target(key, opts) do
    %{
      key: key,
      sql_paths: Keyword.get(opts, :sql_paths, sql_paths()),
      namespace: Keyword.get_lazy(opts, :namespace, fn -> namespace() end) |> to_namespace(),
      connection: Keyword.get_lazy(opts, :connection, fn -> connection_opts(opts) end),
      default_nullable: Keyword.get(opts, :default_nullable, default_nullable?()),
      row_type: Keyword.get(opts, :row_type, row_type()),
      mode: Keyword.get(opts, :mode, mode()),
      repo: target_repo(opts),
      overrides: Keyword.get(opts, :type_overrides, type_overrides())
    }
  end

  defp target_repo(opts) do
    if Keyword.get(opts, :bake_repo, bake_repo?()) do
      Keyword.get(opts, :repo) || repo()
    end
  end

  @doc "Returns the keyword list of options for `Postgrex.start_link/1`."
  @spec connection_opts(keyword()) :: keyword()
  def connection_opts(opts \\ []) do
    cond do
      conn = Keyword.get(opts, :connection) || get(:connection) -> conn
      repo_conn = repo_connection(opts) -> repo_conn
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
      ns -> to_namespace(ns)
    end
  end

  defp to_namespace(ns) when is_binary(ns), do: ns

  defp to_namespace(ns) when is_atom(ns),
    do: ns |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  @doc "Whether unannotated result columns default to nullable."
  @spec default_nullable?() :: boolean()
  def default_nullable?, do: get(:default_nullable, false)

  @doc "Row representation: `:struct` (default) or `:map`."
  @spec row_type() :: :struct | :map
  def row_type, do: get(:row_type, :struct)

  @doc "Generation mode: `:full` (default, with `run/N`) or `:metadata` (types only)."
  @spec mode() :: :full | :metadata
  def mode, do: get(:mode, :full)

  @doc "Whether to bake the configured repo into `run/N`."
  @spec bake_repo?() :: boolean()
  def bake_repo?, do: get(:bake_repo, false)

  @doc "The configured (or derived) runtime repo module, or `nil`."
  @spec repo() :: module() | nil
  def repo, do: get(:repo) || default_repo()

  @doc "The compile-time type override map (keyed by OID or PostgreSQL type name)."
  @spec type_overrides() :: map()
  def type_overrides do
    base = get(:type_overrides, %{})

    case get(:timestamp_type) do
      :naive_datetime -> Map.put_new(base, "timestamptz", "NaiveDateTime.t()")
      _ -> base
    end
  end

  defp get(key, default \\ nil), do: Application.get_env(:squirrel_ex, key, default)

  defp otp_app, do: get(:otp_app)

  defp camelized_app do
    case otp_app() do
      nil -> "Sql"
      app -> app |> Atom.to_string() |> Macro.camelize()
    end
  end

  defp repo_connection(opts) do
    with app when not is_nil(app) <- Keyword.get(opts, :otp_app) || otp_app(),
         repo when not is_nil(repo) <- Keyword.get(opts, :repo) || get(:repo) || default_repo(),
         conf when is_list(conf) <- Application.get_env(app, repo) do
      Keyword.take(conf, [:hostname, :port, :username, :password, :database, :socket_dir, :url])
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

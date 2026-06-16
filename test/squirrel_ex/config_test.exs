defmodule SquirrelEx.ConfigTest do
  use ExUnit.Case, async: false

  alias SquirrelEx.Config

  setup do
    saved = Application.get_all_env(:squirrel_ex)

    on_exit(fn ->
      for {k, _} <- Application.get_all_env(:squirrel_ex),
          do: Application.delete_env(:squirrel_ex, k)

      for {k, v} <- saved, do: Application.put_env(:squirrel_ex, k, v)
    end)

    for {k, _} <- Application.get_all_env(:squirrel_ex),
        do: Application.delete_env(:squirrel_ex, k)

    :ok
  end

  test "sql_paths defaults to priv/sql glob" do
    assert Config.sql_paths() == ["priv/sql/**/*.sql"]
  end

  test "namespace derives from otp_app when unset" do
    Application.put_env(:squirrel_ex, :otp_app, :my_app)
    assert Config.namespace() == "MyApp.Sql"
  end

  test "explicit namespace wins" do
    Application.put_env(:squirrel_ex, :namespace, "Custom.Queries")
    assert Config.namespace() == "Custom.Queries"
  end

  test "default_nullable? defaults to false" do
    refute Config.default_nullable?()
    Application.put_env(:squirrel_ex, :default_nullable, true)
    assert Config.default_nullable?()
  end

  test "explicit :connection takes priority" do
    Application.put_env(:squirrel_ex, :connection, hostname: "db.example", database: "x")
    assert Config.connection_opts() == [hostname: "db.example", database: "x"]
  end

  test "falls back to PG env vars when nothing is configured" do
    opts = Config.connection_opts()
    assert opts[:username] == "postgres"
    assert opts[:hostname] == "localhost"
  end
end

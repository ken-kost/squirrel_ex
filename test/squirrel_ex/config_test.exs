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

  test "row_type defaults to :struct" do
    assert Config.row_type() == :struct
    Application.put_env(:squirrel_ex, :row_type, :map)
    assert Config.row_type() == :map
  end

  test "mode defaults to :full" do
    assert Config.mode() == :full
    Application.put_env(:squirrel_ex, :mode, :metadata)
    assert Config.mode() == :metadata
  end

  test "type_overrides merges the timestamp_type shortcut" do
    assert Config.type_overrides() == %{}
    Application.put_env(:squirrel_ex, :timestamp_type, :naive_datetime)
    assert Config.type_overrides() == %{"timestamptz" => "NaiveDateTime.t()"}
  end

  test "targets/0 returns a single default target from flat config" do
    Application.put_env(:squirrel_ex, :namespace, "Flat.Sql")
    assert [target] = Config.targets()
    assert target.key == :default
    assert target.namespace == "Flat.Sql"
    assert target.row_type == :struct
    assert target.mode == :full
    assert target.repo == nil
  end

  test "targets/0 fans out over :repos, inheriting top-level defaults" do
    Application.put_env(:squirrel_ex, :default_nullable, true)

    Application.put_env(:squirrel_ex, :repos,
      primary: [namespace: "App.Primary", sql_paths: ["a/*.sql"], connection: [database: "p"]],
      analytics: [
        namespace: "App.Analytics",
        sql_paths: ["b/*.sql"],
        connection: [database: "a"],
        row_type: :map
      ]
    )

    assert [primary, analytics] = Config.targets()
    assert primary.key == :primary
    assert primary.namespace == "App.Primary"
    assert primary.default_nullable == true
    assert primary.row_type == :struct
    assert analytics.key == :analytics
    assert analytics.row_type == :map
    assert analytics.connection == [database: "a"]
  end

  test "bake_repo bakes the configured repo into the target" do
    Application.put_env(:squirrel_ex, :repo, MyApp.Repo)
    Application.put_env(:squirrel_ex, :bake_repo, true)
    assert [%{repo: MyApp.Repo}] = Config.targets()
  end
end

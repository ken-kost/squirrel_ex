defmodule SquirrelEx.GeneratedModuleTest do
  @moduledoc """
  Exercises the committed fixture module `SquirrelEx.Test.Sql.AllPosts`
  (generated from `test/fixtures/sql/all_posts.sql` and compiled via
  `elixirc_paths(:test)`) against the live database.
  """

  use SquirrelEx.Test.DataCase, async: false

  @moduletag :db

  test "the committed generated module runs and returns typed maps" do
    Repo.query!("insert into posts (title, body, author_id) values ($1, $2, $3)", [
      "Bravo",
      "b",
      1
    ])

    Repo.query!("insert into posts (title, body, author_id) values ($1, $2, $3)", [
      "Alpha",
      nil,
      1
    ])

    assert {:ok, rows} = SquirrelEx.Test.Sql.AllPosts.run(Repo)
    assert [%{title: "Alpha", body: nil} = first, %{title: "Bravo", body: "b"}] = rows
    assert Map.keys(first) |> Enum.sort() == [:body, :id, :title]
    assert is_binary(first.id)
  end
end

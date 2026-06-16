# Decide whether the live-database suite can run. If PostgreSQL is unreachable
# we still run the pure unit tests but exclude everything tagged `:db`.
repo_config = Application.fetch_env!(:squirrel_ex, SquirrelEx.Test.Repo)

db_available? =
  case Postgrex.start_link(Keyword.delete(repo_config, :pool)) do
    {:ok, conn} ->
      result = match?({:ok, _}, Postgrex.query(conn, "select 1", []))
      GenServer.stop(conn)
      result

    _ ->
      false
  end

if db_available? do
  # Ensure the schema the fixtures/integration tests expect exists.
  {:ok, conn} = Postgrex.start_link(Keyword.delete(repo_config, :pool))

  Postgrex.query!(
    conn,
    """
    create table if not exists posts (
      id uuid primary key default gen_random_uuid(),
      title text not null,
      body text,
      author_id int not null,
      published_at timestamptz
    )
    """,
    []
  )

  GenServer.stop(conn)

  {:ok, _} = SquirrelEx.Test.Repo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(SquirrelEx.Test.Repo, :manual)
else
  IO.puts(:stderr, "\n[squirrel_ex] PostgreSQL unavailable — excluding :db tests.\n")
end

ExUnit.start(exclude: if(db_available?, do: [], else: [:db]))

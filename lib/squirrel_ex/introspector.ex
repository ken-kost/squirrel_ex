defmodule SquirrelEx.Introspector do
  @moduledoc """
  Introspects a query against a live PostgreSQL connection to learn its
  parameter types and result column names + types.

  Uses `Postgrex.prepare/4` with an unnamed statement — the same extended-query
  Parse/Describe protocol the Gleam squirrel implements by hand. A single round
  trip yields result column **names** (which `pg_prepared_statements` does not
  expose) alongside the parameter and result OIDs.
  """

  @doc """
  Starts a throwaway Postgrex connection from `opts` (a `Postgrex.start_link/1`
  keyword list). The caller is responsible for stopping it with `disconnect/1`.
  """
  @spec connect(keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(opts) do
    Postgrex.start_link(opts)
  end

  @doc "Stops a connection started with `connect/1`."
  @spec disconnect(pid()) :: :ok
  def disconnect(conn) do
    GenServer.stop(conn)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Introspects `sql` on `conn`.

  Returns `{:ok, %{params: [oid], columns: [{name, oid}]}}` or
  `{:error, %Postgrex.Error{}}`.
  """
  @spec introspect(pid(), String.t()) ::
          {:ok, %{params: [non_neg_integer()], columns: [{String.t(), non_neg_integer()}]}}
          | {:error, Postgrex.Error.t() | term()}
  def introspect(conn, sql) do
    case Postgrex.prepare(conn, "", sql) do
      {:ok, %Postgrex.Query{} = query} ->
        _ = Postgrex.close(conn, query)

        columns =
          Enum.zip(query.columns || [], query.result_oids || [])

        {:ok, %{params: query.param_oids || [], columns: columns}}

      {:error, error} ->
        {:error, error}
    end
  end
end

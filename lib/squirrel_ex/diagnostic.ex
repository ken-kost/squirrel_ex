defmodule SquirrelEx.Diagnostic do
  @moduledoc """
  Builds `Mix.Task.Compiler.Diagnostic` structs so squirrel_ex errors and
  warnings surface in `mix compile` output and editors.
  """

  @compiler_name "squirrel_ex"

  @doc "An error diagnostic for `file` with `message` at optional `position`."
  @spec error(Path.t(), String.t(), Mix.Task.Compiler.Diagnostic.position()) ::
          Mix.Task.Compiler.Diagnostic.t()
  def error(file, message, position \\ nil) do
    build(file, :error, message, position)
  end

  @doc "A warning diagnostic for `file` with `message` at optional `position`."
  @spec warning(Path.t(), String.t(), Mix.Task.Compiler.Diagnostic.position()) ::
          Mix.Task.Compiler.Diagnostic.t()
  def warning(file, message, position \\ nil) do
    build(file, :warning, message, position)
  end

  @doc """
  Turns a `%Postgrex.Error{}` raised while introspecting `file` (whose SQL is
  `sql`) into an error diagnostic, mapping the Postgres byte position to a line
  number when available.
  """
  @spec from_postgrex(Path.t(), String.t(), Postgrex.Error.t()) ::
          Mix.Task.Compiler.Diagnostic.t()
  def from_postgrex(file, sql, %Postgrex.Error{postgres: pg}) when is_map(pg) do
    message = Map.get(pg, :message, "could not prepare query")
    line = pg |> Map.get(:position) |> position_to_line(sql)
    error(file, message, line)
  end

  def from_postgrex(file, _sql, %Postgrex.Error{} = error) do
    error(file, Exception.message(error))
  end

  defp build(file, severity, message, position) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: @compiler_name,
      file: file,
      severity: severity,
      message: message,
      position: position || 0,
      stacktrace: []
    }
  end

  # Postgres `position` is a 1-based character offset into the query string.
  defp position_to_line(nil, _sql), do: nil

  defp position_to_line(position, sql) when is_binary(position) do
    case Integer.parse(position) do
      {offset, _} -> position_to_line(offset, sql)
      :error -> nil
    end
  end

  defp position_to_line(offset, sql) when is_integer(offset) do
    sql
    |> binary_part(0, min(offset, byte_size(sql)))
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end
end

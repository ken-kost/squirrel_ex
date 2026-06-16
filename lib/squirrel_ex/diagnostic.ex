defmodule SquirrelEx.Diagnostic do
  @moduledoc """
  Builds `Mix.Task.Compiler.Diagnostic` structs so squirrel_ex errors and
  warnings surface in `mix compile` output and editors.

  For PostgreSQL errors we enrich the message with a source pointer (the
  offending line plus a caret under the token, derived from the error
  `position`) and a friendly hint mapped from the `SQLSTATE` code.
  """

  @compiler_name "squirrel_ex"

  # SQLSTATE -> friendly hint.
  @hints %{
    "42P01" => "undefined table — check the name and that the table exists in this database.",
    "42703" => "undefined column — check the column name (and any table alias).",
    "42601" => "syntax error in the SQL.",
    "42501" => "permission denied — the introspection role lacks access to this object.",
    "42883" => "undefined function or operator — check argument types and casts.",
    "42P18" => "indeterminate parameter type — add an explicit cast, e.g. `$1::int`.",
    "42P02" => "the placeholder has no corresponding parameter.",
    "42804" => "datatype mismatch — a value's type does not match what the column expects."
  }

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
  `sql`) into an error diagnostic. Renders a caret pointer at the error position
  and appends a `SQLSTATE`-derived hint when one is known.
  """
  @spec from_postgrex(Path.t(), String.t(), Postgrex.Error.t()) ::
          Mix.Task.Compiler.Diagnostic.t()
  def from_postgrex(file, sql, %Postgrex.Error{postgres: pg}) when is_map(pg) do
    base = Map.get(pg, :message, "could not prepare query")
    offset = pg |> Map.get(:position) |> to_offset()
    pointer = pointer(sql, offset)
    hint = hint(Map.get(pg, :code))

    message =
      [base, pointer, hint]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    error(file, message, line_of(sql, offset))
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

  defp hint(code) when is_binary(code) do
    case Map.fetch(@hints, code) do
      {:ok, text} -> "hint (SQLSTATE #{code}): #{text}"
      :error -> nil
    end
  end

  defp hint(_), do: nil

  # Renders the offending line with a caret under the error column.
  defp pointer(_sql, nil), do: nil

  defp pointer(sql, offset) do
    {line_text, col} = locate(sql, offset)
    "  " <> line_text <> "\n  " <> String.duplicate(" ", max(col - 1, 0)) <> "^"
  end

  # Postgres `position` is a 1-based character offset into the query string.
  defp to_offset(nil), do: nil
  defp to_offset(n) when is_integer(n), do: n

  defp to_offset(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp line_of(_sql, nil), do: nil

  defp line_of(sql, offset) do
    sql
    |> binary_part(0, min(offset, byte_size(sql)))
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end

  # Returns `{offending_line_text, column}` (column is 1-based within the line).
  defp locate(sql, offset) do
    before = binary_part(sql, 0, min(offset, byte_size(sql)) |> max(0))
    lines_before = String.split(before, "\n")
    col = lines_before |> List.last() |> String.length() |> Kernel.+(1)
    line_index = length(lines_before) - 1
    line_text = sql |> String.split("\n") |> Enum.at(line_index, "")
    {line_text, col}
  end
end

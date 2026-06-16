defmodule SquirrelEx.Params do
  @moduledoc """
  Infers human-friendly parameter names from the SQL surrounding each `$n`
  placeholder.

  This is a pragmatic, regex-based heuristic (the Gleam original does no
  inference at all and leaves parameters positional). It recognises the common
  comparison shapes and falls back to `arg<n>` when nothing matches. Names are
  de-duplicated with a numeric suffix and sanitised to valid Elixir variable
  names.

  Recognised shapes (case-insensitive):

    * `col = $n`, `$n = col`
    * `table.col = $n`
    * `col <op> $n` where `<op>` is one of `>` `<` `>=` `<=` `<>` `!=` `LIKE` `ILIKE`
    * `col IN ($n)`
  """

  @ident "[a-zA-Z_][a-zA-Z0-9_]*"

  @doc """
  Returns an ordered list of parameter names for `count` placeholders found in
  `sql`. Index 0 corresponds to `$1`.

  String literals, quoted identifiers, and `--` / `/* */` comments are masked
  out before inference, so identifiers inside them are never mistaken for column
  references.
  """
  @spec names(String.t(), non_neg_integer()) :: [String.t()]
  def names(sql, count) do
    inferred = sql |> mask() |> scan()

    {names, _used} =
      Enum.map_reduce(1..count//1, %{}, fn n, used ->
        base = Map.get(inferred, n) || "arg#{n}"
        {unique, used} = dedupe(base, used)
        {unique, used}
      end)

    names
  end

  @doc false
  # Replaces the contents of string literals, quoted identifiers, and comments
  # with spaces (preserving length and `$n` positions outside them), so the
  # inference regexes only see real SQL tokens.
  @spec mask(String.t()) :: String.t()
  def mask(sql), do: mask(sql, :normal, [])

  defp mask(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Enter states.
  defp mask(<<"--", rest::binary>>, :normal, acc), do: mask(rest, :line_comment, ["  " | acc])
  defp mask(<<"/*", rest::binary>>, :normal, acc), do: mask(rest, :block_comment, ["  " | acc])
  defp mask(<<"'", rest::binary>>, :normal, acc), do: mask(rest, :string, [" " | acc])
  defp mask(<<"\"", rest::binary>>, :normal, acc), do: mask(rest, :quoted, [" " | acc])
  defp mask(<<c::utf8, rest::binary>>, :normal, acc), do: mask(rest, :normal, [<<c::utf8>> | acc])

  # Line comment: until newline.
  defp mask(<<"\n", rest::binary>>, :line_comment, acc), do: mask(rest, :normal, ["\n" | acc])

  defp mask(<<_::utf8, rest::binary>>, :line_comment, acc),
    do: mask(rest, :line_comment, [" " | acc])

  # Block comment: until */.
  defp mask(<<"*/", rest::binary>>, :block_comment, acc), do: mask(rest, :normal, ["  " | acc])

  defp mask(<<"\n", rest::binary>>, :block_comment, acc),
    do: mask(rest, :block_comment, ["\n" | acc])

  defp mask(<<_::utf8, rest::binary>>, :block_comment, acc),
    do: mask(rest, :block_comment, [" " | acc])

  # Single-quoted string (doubled '' escapes a quote).
  defp mask(<<"''", rest::binary>>, :string, acc), do: mask(rest, :string, ["  " | acc])
  defp mask(<<"'", rest::binary>>, :string, acc), do: mask(rest, :normal, [" " | acc])
  defp mask(<<"\n", rest::binary>>, :string, acc), do: mask(rest, :string, ["\n" | acc])
  defp mask(<<_::utf8, rest::binary>>, :string, acc), do: mask(rest, :string, [" " | acc])

  # Double-quoted identifier ("" escapes a quote).
  defp mask(<<"\"\"", rest::binary>>, :quoted, acc), do: mask(rest, :quoted, ["  " | acc])
  defp mask(<<"\"", rest::binary>>, :quoted, acc), do: mask(rest, :normal, [" " | acc])
  defp mask(<<"\n", rest::binary>>, :quoted, acc), do: mask(rest, :quoted, ["\n" | acc])
  defp mask(<<_::utf8, rest::binary>>, :quoted, acc), do: mask(rest, :quoted, [" " | acc])

  # Returns a map of placeholder-number => inferred-name (first match wins).
  defp scan(sql) do
    patterns()
    |> Enum.flat_map(fn {regex, capture} ->
      Regex.scan(regex, sql, capture: :all_but_first)
      |> Enum.map(fn groups -> extract(groups, capture) end)
    end)
    |> Enum.reduce(%{}, fn {n, name}, acc ->
      Map.put_new(acc, n, name)
    end)
  end

  # Each pattern captures the placeholder number and the identifier(s). The
  # `capture` atom tells `extract/2` how to read the groups.
  defp patterns do
    [
      # table.col = $n   (col on the left, placeholder on the right)
      {~r/(#{@ident})\.(#{@ident})\s*=\s*\$(\d+)/, :dotted_left},
      # col <op> $n
      {~r/(#{@ident})\s*(?:>=|<=|<>|!=|=|>|<)\s*\$(\d+)/, :ident_left},
      {~r/(#{@ident})\s+(?:i?like)\s+\$(\d+)/i, :ident_left},
      # col IN ($n)
      {~r/(#{@ident})\s+in\s*\(\s*\$(\d+)/i, :ident_left},
      # $n = col   (placeholder on the left)
      {~r/\$(\d+)\s*=\s*(?:#{@ident}\.)?(#{@ident})/, :ident_right}
    ]
  end

  defp extract([table_or_col, col, num], :dotted_left),
    do: {String.to_integer(num), sanitize(col || table_or_col)}

  defp extract([col, num], :ident_left), do: {String.to_integer(num), sanitize(col)}
  defp extract([num, col], :ident_right), do: {String.to_integer(num), sanitize(col)}

  defp sanitize(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  defp dedupe(base, used) do
    case Map.get(used, base, 0) do
      0 -> {base, Map.put(used, base, 1)}
      n -> {"#{base}_#{n + 1}", Map.put(used, base, n + 1)}
    end
  end
end

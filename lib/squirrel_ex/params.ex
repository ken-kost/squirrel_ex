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
  """
  @spec names(String.t(), non_neg_integer()) :: [String.t()]
  def names(sql, count) do
    inferred = scan(sql)

    {names, _used} =
      Enum.map_reduce(1..count//1, %{}, fn n, used ->
        base = Map.get(inferred, n) || "arg#{n}"
        {unique, used} = dedupe(base, used)
        {unique, used}
      end)

    names
  end

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

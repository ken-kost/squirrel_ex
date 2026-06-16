defmodule SquirrelEx.Manifest do
  @moduledoc """
  Tracks which `.sql` files have already been generated, so the compiler only
  re-introspects files whose content changed.

  The manifest is a map of `sql_path => %{hash: binary, generated: ex_path}`
  serialised with `:erlang.term_to_binary/1`.
  """

  @vsn 1

  @type entry :: %{hash: binary(), generated: String.t()}
  @type t :: %{optional(String.t()) => entry()}

  @doc "Reads the manifest at `path`, returning an empty map if absent or stale."
  @spec read(Path.t()) :: t()
  def read(path) do
    with {:ok, binary} <- File.read(path),
         {@vsn, map} when is_map(map) <- safe_binary_to_term(binary) do
      map
    else
      _ -> %{}
    end
  end

  @doc "Writes `manifest` to `path`, creating parent directories as needed."
  @spec write(Path.t(), t()) :: :ok
  def write(path, manifest) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary({@vsn, manifest}))
  end

  @doc "The SHA-256 hex digest of `content`."
  @spec hash(binary()) :: binary()
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @doc """
  Given the current set of `sql_paths` and the previous `manifest`, returns
  `{stale, orphans}`:

    * `stale` — `.sql` paths needing (re)generation because their content hash
      changed or the generated `.ex` is missing.
    * `orphans` — generated `.ex` paths whose `.sql` source no longer exists.
  """
  @spec diff([String.t()], t()) :: {[String.t()], [String.t()]}
  def diff(sql_paths, manifest) do
    current = MapSet.new(sql_paths)

    stale =
      Enum.filter(sql_paths, fn sql_path ->
        case Map.get(manifest, sql_path) do
          %{hash: hash, generated: ex_path} ->
            hash != current_hash(sql_path) or not File.exists?(ex_path)

          _ ->
            true
        end
      end)

    orphans =
      for {sql_path, %{generated: ex_path}} <- manifest,
          not MapSet.member?(current, sql_path),
          do: ex_path

    {stale, orphans}
  end

  defp current_hash(sql_path) do
    case File.read(sql_path) do
      {:ok, content} -> hash(content)
      _ -> nil
    end
  end

  defp safe_binary_to_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    _ -> :error
  end
end

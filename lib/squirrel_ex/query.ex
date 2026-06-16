defmodule SquirrelEx.Query do
  @moduledoc """
  The parsed, typed model of a single `.sql` file, ready to be handed to
  `SquirrelEx.Codegen`.

  Responsibilities:

    * derive the output module name from the file name and namespace
    * extract leading `-- ` comments into a module doc, and recognise leading
      directives such as `-- @one`
    * parse and strip `!` / `?` nullability annotations from result columns
    * assemble parameters (name + typespec) and columns (key + typespec +
      decoder + nullability), resolving the final nullability of each column
      from, in order: the explicit annotation, the `EXPLAIN`-derived verdict,
      then the `:default_nullable` setting.
  """

  alias SquirrelEx.{Query, Type}

  @enforce_keys [:module, :sql_path, :ex_path, :rel_path, :sql, :params, :columns]
  defstruct [
    :module,
    :sql_path,
    :ex_path,
    :rel_path,
    :sql,
    :doc,
    :params,
    :columns,
    row_type: :struct,
    one: false,
    repo: nil,
    mode: :full
  ]

  @type column :: %{
          key: String.t(),
          typespec: String.t(),
          nullable: boolean(),
          decoder: Type.decoder(),
          enum: [String.t()] | nil,
          ecto: term()
        }
  @type param :: %{name: String.t(), typespec: String.t(), ecto: term()}
  @type directives :: %{optional(:one) => boolean()}

  @type t :: %__MODULE__{
          module: String.t(),
          sql_path: String.t(),
          ex_path: String.t(),
          rel_path: String.t(),
          sql: String.t(),
          doc: String.t() | nil,
          params: [param()],
          columns: [column()],
          row_type: :map | :struct,
          one: boolean(),
          repo: module() | nil,
          mode: :full | :metadata
        }

  @annotation ~r/([a-zA-Z_][a-zA-Z0-9_]*)([!?])(?=\s|,|\)|$)/

  @doc """
  Parses the raw SQL source into `{clean_sql, annotations, doc, directives}`.

    * `clean_sql` — the SQL with `!`/`?` column annotations removed, safe to send
      to PostgreSQL and embed verbatim in the generated module.
    * `annotations` — a map of `downcased_column_name => :nullable | :not_null`.
    * `doc` — the leading `-- ` comment block (trimmed, directives removed), or `nil`.
    * `directives` — recognised leading directives, e.g. `%{one: true}` for
      `-- @one` / `-- :one`.
  """
  @spec parse_source(String.t()) ::
          {String.t(), %{optional(String.t()) => :nullable | :not_null}, String.t() | nil,
           directives()}
  def parse_source(raw) do
    comments = leading_comments(raw)
    directives = parse_directives(comments)
    doc = doc_from_comments(comments)
    annotations = extract_annotations(raw)
    clean = Regex.replace(@annotation, raw, "\\1")
    {clean, annotations, doc, directives}
  end

  @doc """
  Derives the output module name, e.g. `("MyApp.Sql", ".../list_posts.sql")`
  becomes `"MyApp.Sql.ListPosts"`.
  """
  @spec module_name(String.t(), Path.t()) :: String.t()
  def module_name(namespace, sql_path) do
    base = sql_path |> Path.basename(".sql") |> Macro.camelize()
    namespace <> "." <> base
  end

  @doc """
  Assembles a `%SquirrelEx.Query{}` from introspection results.

  ## Options

    * `:namespace` — output module namespace (required)
    * `:sql_path` — absolute path to the `.sql` file (required)
    * `:rel_path` — path shown in docs/headers (required)
    * `:clean_sql` — annotation-stripped SQL (required)
    * `:doc` — module doc string or `nil`
    * `:annotations` — `%{column => :nullable | :not_null}`
    * `:directives` — `%{one: boolean}` parsed from leading directives
    * `:param_names` — list of parameter names, in order
    * `:param_types` — list of `SquirrelEx.Type` for the parameters, in order.
      (`:param_typespecs`, a list of plain typespec strings, is still accepted.)
    * `:columns` — list of `{name, SquirrelEx.Type | typespec_string}` from
      introspection, in order
    * `:nullability` — list of `:nullable | :not_null | :unknown` verdicts, one
      per column, in order (default all `:unknown`)
    * `:default_nullable` — whether unannotated columns are nullable (default `false`)
    * `:row_type` — `:struct` (default) or `:map`
    * `:repo` — when set, bakes the repo into `run/N` (callers omit it)
    * `:mode` — `:full` (default, emit `run/N`) or `:metadata` (types + the
      `__squirrel__/0` accessor only, no runtime `run/N`)
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    sql_path = Keyword.fetch!(opts, :sql_path)
    rel_path = Keyword.fetch!(opts, :rel_path)
    clean_sql = Keyword.fetch!(opts, :clean_sql)
    annotations = Keyword.get(opts, :annotations, %{})
    directives = Keyword.get(opts, :directives, %{})
    default_nullable = Keyword.get(opts, :default_nullable, false)

    params = build_params(opts)
    columns = build_columns(opts, annotations, default_nullable)

    %Query{
      module: module_name(namespace, sql_path),
      sql_path: sql_path,
      ex_path: Path.rootname(sql_path) <> ".ex",
      rel_path: rel_path,
      sql: String.trim(clean_sql),
      doc: Keyword.get(opts, :doc),
      params: params,
      columns: columns,
      row_type: Keyword.get(opts, :row_type, :struct),
      one: Map.get(directives, :one, false),
      repo: Keyword.get(opts, :repo),
      mode: Keyword.get(opts, :mode, :full)
    }
  end

  defp build_params(opts) do
    names = Keyword.fetch!(opts, :param_names)

    specs =
      case Keyword.fetch(opts, :param_types) do
        {:ok, types} -> Enum.map(types, &{Type.input_typespec(&1), &1.ecto})
        :error -> Enum.map(Keyword.fetch!(opts, :param_typespecs), &{&1, nil})
      end

    Enum.zip_with(names, specs, fn name, {spec, ecto} ->
      %{name: name, typespec: spec, ecto: ecto}
    end)
  end

  defp build_columns(opts, annotations, default_nullable) do
    columns = Keyword.fetch!(opts, :columns)
    verdicts = Keyword.get(opts, :nullability, []) |> pad(length(columns))

    [columns, verdicts]
    |> Enum.zip()
    |> Enum.map(fn {{name, type}, verdict} ->
      {base, decoder, enum, ecto} = base_and_decoder(type)
      nullable? = nullable?(name, annotations, verdict, default_nullable)

      %{
        key: name,
        typespec: if(nullable?, do: base <> " | nil", else: base),
        nullable: nullable?,
        decoder: decoder,
        enum: enum,
        ecto: ecto
      }
    end)
  end

  defp base_and_decoder(%Type{typespec: spec, decoder: decoder, enum: enum, ecto: ecto}),
    do: {spec, decoder, enum, ecto}

  defp base_and_decoder(spec) when is_binary(spec), do: {spec, :identity, nil, nil}

  # Resolution order: explicit annotation > EXPLAIN verdict > default.
  defp nullable?(name, annotations, verdict, default_nullable) do
    case Map.get(annotations, String.downcase(name)) do
      :nullable ->
        true

      :not_null ->
        false

      nil ->
        case verdict do
          :nullable -> true
          :not_null -> false
          _ -> default_nullable
        end
    end
  end

  defp pad(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad(list, n), do: list ++ List.duplicate(:unknown, n - length(list))

  # Leading run of comment lines (the doc/directive block at the top of the file).
  defp leading_comments(raw) do
    raw
    |> String.split("\n")
    |> Enum.take_while(&String.starts_with?(String.trim_leading(&1), "--"))
    |> Enum.map(fn line ->
      line
      |> String.trim_leading()
      |> String.replace_prefix("--", "")
      |> String.trim()
    end)
  end

  @directive ~r/\A[@:]([a-z_]+)\b/i

  defp parse_directives(comments) do
    Enum.reduce(comments, %{}, fn comment, acc ->
      case Regex.run(@directive, comment, capture: :all_but_first) do
        ["one"] -> Map.put(acc, :one, true)
        _ -> acc
      end
    end)
  end

  defp doc_from_comments(comments) do
    case Enum.reject(comments, &Regex.match?(@directive, &1)) do
      [] -> nil
      lines -> lines |> Enum.join("\n") |> String.trim()
    end
  end

  defp extract_annotations(raw) do
    @annotation
    |> Regex.scan(raw, capture: :all_but_first)
    |> Map.new(fn [name, marker] ->
      {String.downcase(name), if(marker == "?", do: :nullable, else: :not_null)}
    end)
  end
end

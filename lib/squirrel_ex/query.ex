defmodule SquirrelEx.Query do
  @moduledoc """
  The parsed, typed model of a single `.sql` file, ready to be handed to
  `SquirrelEx.Codegen`.

  Responsibilities:

    * derive the output module name from the file name and namespace
    * extract leading `-- ` comments into a module doc
    * parse and strip `!` / `?` nullability annotations from result columns
    * assemble parameters (name + typespec) and columns (key + typespec)
  """

  alias SquirrelEx.Query

  @enforce_keys [:module, :sql_path, :ex_path, :rel_path, :sql, :params, :columns]
  defstruct [:module, :sql_path, :ex_path, :rel_path, :sql, :doc, :params, :columns]

  @type column :: %{key: String.t(), typespec: String.t()}
  @type param :: %{name: String.t(), typespec: String.t()}

  @type t :: %__MODULE__{
          module: String.t(),
          sql_path: String.t(),
          ex_path: String.t(),
          rel_path: String.t(),
          sql: String.t(),
          doc: String.t() | nil,
          params: [param()],
          columns: [column()]
        }

  @annotation ~r/([a-zA-Z_][a-zA-Z0-9_]*)([!?])(?=\s|,|\)|$)/

  @doc """
  Parses the raw SQL source into `{clean_sql, annotations, doc}`.

    * `clean_sql` — the SQL with `!`/`?` column annotations removed, safe to send
      to PostgreSQL and embed verbatim in the generated module.
    * `annotations` — a map of `downcased_column_name => :nullable | :not_null`.
    * `doc` — the leading `-- ` comment block (trimmed), or `nil`.
  """
  @spec parse_source(String.t()) ::
          {String.t(), %{optional(String.t()) => :nullable | :not_null}, String.t() | nil}
  def parse_source(raw) do
    doc = extract_doc(raw)
    annotations = extract_annotations(raw)
    clean = Regex.replace(@annotation, raw, "\\1")
    {clean, annotations, doc}
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
    * `:param_names` — list of parameter names, in order
    * `:param_typespecs` — list of parameter typespecs, in order
    * `:columns` — list of `{name, base_typespec}` from introspection, in order
    * `:default_nullable` — whether unannotated columns are nullable (default `false`)
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    namespace = Keyword.fetch!(opts, :namespace)
    sql_path = Keyword.fetch!(opts, :sql_path)
    rel_path = Keyword.fetch!(opts, :rel_path)
    clean_sql = Keyword.fetch!(opts, :clean_sql)
    annotations = Keyword.get(opts, :annotations, %{})
    default_nullable = Keyword.get(opts, :default_nullable, false)

    params =
      Enum.zip(Keyword.fetch!(opts, :param_names), Keyword.fetch!(opts, :param_typespecs))
      |> Enum.map(fn {name, spec} -> %{name: name, typespec: spec} end)

    columns =
      Enum.map(Keyword.fetch!(opts, :columns), fn {name, base} ->
        %{key: name, typespec: apply_nullability(base, name, annotations, default_nullable)}
      end)

    %Query{
      module: module_name(namespace, sql_path),
      sql_path: sql_path,
      ex_path: Path.rootname(sql_path) <> ".ex",
      rel_path: rel_path,
      sql: String.trim(clean_sql),
      doc: Keyword.get(opts, :doc),
      params: params,
      columns: columns
    }
  end

  defp apply_nullability(base, name, annotations, default_nullable) do
    nullable? =
      case Map.get(annotations, String.downcase(name)) do
        :nullable -> true
        :not_null -> false
        nil -> default_nullable
      end

    if nullable?, do: base <> " | nil", else: base
  end

  defp extract_doc(raw) do
    lines =
      raw
      |> String.split("\n")
      |> Enum.take_while(&String.starts_with?(String.trim_leading(&1), "--"))
      |> Enum.map(fn line ->
        line
        |> String.trim_leading()
        |> String.replace_prefix("--", "")
        |> String.trim()
      end)

    case lines do
      [] -> nil
      _ -> lines |> Enum.join("\n") |> String.trim()
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

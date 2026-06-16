defmodule SquirrelEx.Type do
  @moduledoc """
  The resolved type of a single PostgreSQL value — the shared currency between
  `SquirrelEx.Oid` (which produces it) and `SquirrelEx.Codegen` (which renders
  it into typespecs and runtime decoders).

  Fields:

    * `:typespec` — the Elixir typespec for a **result** value, e.g.
      `"integer()"`, `":draft | :published"`, `"[String.t()]"`.
    * `:input` — the typespec for a **parameter** value. Usually equal to
      `:typespec`, but differs for enums (a parameter is sent to PostgreSQL as a
      `String.t()`, never an atom).
    * `:decoder` — how the generated `run/N` must transform the raw Postgrex
      value before handing it back: `:identity` (the common case), `:enum`
      (`String.to_existing_atom/1`), or `:enum_array` (per-element).
    * `:ecto` — the closest Ecto type, kept for documentation and downstream
      tools. Not used by the Ecto runtime (the generated wrapper does not cast
      through Ecto types).
    * `:enum` — for enum types, the ordered list of variant strings.
  """

  @type decoder :: :identity | :enum | :enum_array

  @type t :: %__MODULE__{
          typespec: String.t(),
          input: String.t() | nil,
          decoder: decoder(),
          ecto: term(),
          enum: [String.t()] | nil
        }

  defstruct typespec: "term()", input: nil, decoder: :identity, ecto: nil, enum: nil

  @doc "Builds a plain (identity-decoded) type from a typespec, with an optional Ecto type."
  @spec simple(String.t(), term()) :: t()
  def simple(typespec, ecto \\ nil), do: %__MODULE__{typespec: typespec, ecto: ecto}

  @doc "The typespec to use for a parameter of this type (`:input` if set, else `:typespec`)."
  @spec input_typespec(t()) :: String.t()
  def input_typespec(%__MODULE__{input: nil, typespec: typespec}), do: typespec
  def input_typespec(%__MODULE__{input: input}), do: input
end

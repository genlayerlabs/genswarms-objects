defmodule Genswarms.Tips.Core do
  @moduledoc """
  Pure pool / rotation / assembly logic for `Genswarms.Tips`. No store, no side
  effects — every function takes plain data and returns plain data.

  ## Data shapes
      fragment: %{id: String.t, kind: String.t, category: String.t | nil,
                  text: String.t, weight: non_neg_integer,
                  status: "pending" | "live" | "retired", source: String.t}
      seen_list: [fragment_id]                    # one recipient, oldest first
      template:  [%{kind: String.t, rotate: boolean}]

  Fragment ids are content-addressed (sha256 of kind + text, 16 hex chars):
  re-adding identical content is a natural no-op upsert.
  """

  @doc "Build a fragment map with a deterministic content-addressed id."
  def fragment(kind, text, opts \\ []) when is_binary(kind) and is_binary(text) do
    %{
      id: fragment_id(kind, text),
      kind: kind,
      category: Keyword.get(opts, :category),
      text: text,
      weight: Keyword.get(opts, :weight, 1),
      status: Keyword.get(opts, :status, "pending"),
      source: Keyword.get(opts, :source, "generated")
    }
  end

  @doc "Deterministic 16-hex-char id over (kind, text)."
  def fragment_id(kind, text) do
    :crypto.hash(:sha256, kind <> "\n" <> text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

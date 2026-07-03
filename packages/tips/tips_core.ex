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

  @doc """
  Deterministic draw. Seeded by `(recipient_id, date, salt)` — same inputs,
  same message (a crash between draw and send retries identically). Pure:
  never mutates `seen`.

  Per template slot, over `status == "live"` fragments of that kind:
    - `rotate: true`  — uniform pick over fragments UNSEEN by this recipient.
      All seen but pool non-empty (live set shrank under a retire race) —
      fall back to avoiding only the most recent `guard` seen ids; commit/5
      does the durable reshuffle. Zero live fragments — `{:error, :empty_pool}`.
    - `rotate: false` — weighted pick (weight 0 = never, unless EVERY live
      fragment of that kind is weight ≤ 0 — then falls back to uniform;
      picking something beats silence). Empty pool or empty text contributes
      nothing.
  """
  def draw(fragments, seen, template, recipient_id, date, salt, guard) do
    live = Enum.filter(fragments, &(&1.status == "live"))
    seen_list = Map.get(seen, recipient_id, [])
    rng = seed(recipient_id, date, salt)

    template
    |> Enum.reduce_while({:ok, [], [], rng}, fn slot, {:ok, parts, rot_ids, rng} ->
      # sort_by id: the draw must not depend on store return order
      pool = live |> Enum.filter(&(&1.kind == slot.kind)) |> Enum.sort_by(& &1.id)

      case pick(slot, pool, seen_list, guard, rng) do
        {:error, :empty_pool} ->
          {:halt, {:error, :empty_pool}}

        {frag, rng} ->
          rot_ids = if slot.rotate and frag != nil, do: [frag.id | rot_ids], else: rot_ids
          parts = if frag != nil and frag.text != "", do: [frag.text | parts], else: parts
          {:cont, {:ok, parts, rot_ids, rng}}
      end
    end)
    |> case do
      {:error, :empty_pool} ->
        {:error, :empty_pool}

      {:ok, parts, rot_ids, _rng} ->
        {:ok,
         %{
           text: parts |> Enum.reverse() |> Enum.join(" "),
           rotating_ids: Enum.reverse(rot_ids)
         }}
    end
  end

  # ── selection internals ──────────────────────────────────────────────────

  defp pick(%{rotate: false}, [], _seen, _guard, rng), do: {nil, rng}
  defp pick(%{rotate: false}, pool, _seen, _guard, rng), do: weighted(pool, rng)
  defp pick(%{rotate: true}, [], _seen, _guard, _rng), do: {:error, :empty_pool}

  defp pick(%{rotate: true}, pool, seen_list, guard, rng) do
    seen_set = MapSet.new(seen_list)

    candidates =
      case Enum.reject(pool, &MapSet.member?(seen_set, &1.id)) do
        [] ->
          recent = MapSet.new(Enum.take(seen_list, -guard))
          case Enum.reject(pool, &MapSet.member?(recent, &1.id)) do
            [] -> pool
            rest -> rest
          end

        unseen ->
          unseen
      end

    uniform(candidates, rng)
  end

  defp uniform(list, rng) do
    {i, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, i - 1), rng}
  end

  defp weighted(pool, rng) do
    total = pool |> Enum.map(&max(&1.weight, 0)) |> Enum.sum()

    if total <= 0 do
      uniform(pool, rng)
    else
      {r, rng} = :rand.uniform_s(total, rng)
      {weighted_walk(pool, r), rng}
    end
  end

  defp weighted_walk([f | rest], r) do
    w = max(f.weight, 0)
    if r <= w, do: f, else: weighted_walk(rest, r - w)
  end

  defp seed(recipient_id, date, salt) do
    :rand.seed_s(
      :exsss,
      {:erlang.phash2({salt, recipient_id}), :erlang.phash2({recipient_id, date}),
       :erlang.phash2({date, salt})}
    )
  end

  @doc """
  Record delivered rotating fragment ids for one recipient — call only after a
  delivery ATTEMPT (mirror of roster's mark-after-attempt discipline). Returns
  `{seen_list', reshuffled?}`.

  Exhaustion reshuffle: once every live rotating fragment is in `seen_list`,
  keep only the most recent `min(guard, pool_size - 1)` ids so the next cycle
  never opens with a recent repeat (pool of 1 keeps none — repeats beat
  starvation). Retired ids already in `seen_list` are preserved: retiring a
  fragment never resurrects it as "fresh".
  """
  def commit(fragments, template, seen_list, rotating_ids, guard) do
    rot_kinds = for %{rotate: true, kind: k} <- template, into: MapSet.new(), do: k

    seen_list = Enum.reject(seen_list, &(&1 in rotating_ids)) ++ rotating_ids

    live_rot =
      for f <- fragments,
          f.status == "live",
          MapSet.member?(rot_kinds, f.kind),
          into: MapSet.new(),
          do: f.id

    if MapSet.size(live_rot) > 0 and MapSet.subset?(live_rot, MapSet.new(seen_list)) do
      keep = min(guard, MapSet.size(live_rot) - 1)
      {if(keep > 0, do: Enum.take(seen_list, -keep), else: []), true}
    else
      {seen_list, false}
    end
  end
end

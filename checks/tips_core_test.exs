# Tips core: pure pool/rotation/assembly logic. Standalone — no store, no network:
#   mix run checks/tips_core_test.exs
ExUnit.start()

defmodule TipsCoreFragmentTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips.Core

  test "fragment/3 builds defaults and a deterministic content-addressed id" do
    f = Core.fragment("body", "Write your last line first.")
    assert f.kind == "body"
    assert f.text == "Write your last line first."
    assert f.status == "pending"
    assert f.source == "generated"
    assert f.weight == 1
    assert f.category == nil
    assert f.id == Core.fragment_id("body", "Write your last line first.")
    assert String.length(f.id) == 16
    # same (kind, text) => same id; different kind => different id
    assert f.id == Core.fragment("body", "Write your last line first.").id
    refute f.id == Core.fragment("opener", "Write your last line first.").id
  end

  test "fragment/3 honors opts" do
    f = Core.fragment("closer", "", category: "signoff", weight: 5, status: "live", source: "seed")
    assert %{category: "signoff", weight: 5, status: "live", source: "seed", text: ""} = f
  end
end

defmodule TipsCoreDrawTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips.Core

  @template [
    %{kind: "opener", rotate: false},
    %{kind: "body", rotate: true},
    %{kind: "closer", rotate: false}
  ]

  defp pool do
    [
      Core.fragment("opener", "Coo coo, creator:", status: "live"),
      Core.fragment("opener", "Real talk from your favorite pigeon:", status: "live"),
      Core.fragment("body", "Write your last line first.", status: "live", category: "hooks"),
      Core.fragment("body", "One idea per sentence.", status: "live", category: "craft"),
      Core.fragment("body", "Front-load the payoff.", status: "live", category: "threads"),
      # empty closer models "often no sign-off"
      Core.fragment("closer", "", status: "live", weight: 10),
      Core.fragment("closer", "Fly high.", status: "live", weight: 1),
      # non-live fragments must never be drawn
      Core.fragment("body", "PENDING body.", status: "pending"),
      Core.fragment("body", "RETIRED body.", status: "retired")
    ]
  end

  test "draw is deterministic on (fragments, seen, recipient, date, salt)" do
    a = Core.draw(pool(), %{}, @template, "tg:1:0", "2026-07-03", "s", 20)
    b = Core.draw(pool(), %{}, @template, "tg:1:0", "2026-07-03", "s", 20)
    assert a == b
    assert {:ok, %{text: text, rotating_ids: [body_id]}} = a
    # the body slot's pick is one of the LIVE bodies, present in the text
    live_bodies = for f <- pool(), f.kind == "body", f.status == "live", do: f
    body = Enum.find(live_bodies, &(&1.id == body_id))
    assert body != nil
    assert String.contains?(text, body.text)
    refute String.contains?(text, "PENDING")
    refute String.contains?(text, "RETIRED")
  end

  test "different date or recipient can change the draw; store order cannot" do
    base = Core.draw(pool(), %{}, @template, "tg:1:0", "2026-07-03", "s", 20)
    # order-independence: reversing the fragment list gives the identical draw
    assert base == Core.draw(Enum.reverse(pool()), %{}, @template, "tg:1:0", "2026-07-03", "s", 20)
    # across 30 dates the recipient must see more than one distinct body
    ids =
      for d <- 1..30, into: MapSet.new() do
        {:ok, %{rotating_ids: [id]}} =
          Core.draw(pool(), %{}, @template, "tg:1:0", "2026-06-#{d}", "s", 20)
        id
      end
    assert MapSet.size(ids) > 1
  end

  test "seen bodies are excluded; empty rotating pool errors; dressing degrades" do
    live_bodies = for f <- pool(), f.kind == "body", f.status == "live", do: f.id
    [keep | seen] = live_bodies
    {:ok, %{rotating_ids: [drawn]}} =
      Core.draw(pool(), %{"tg:1:0" => seen}, @template, "tg:1:0", "2026-07-03", "s", 20)
    assert drawn == keep

    # zero live bodies => empty_pool
    no_bodies = Enum.reject(pool(), &(&1.kind == "body" and &1.status == "live"))
    assert {:error, :empty_pool} =
             Core.draw(no_bodies, %{}, @template, "tg:1:0", "2026-07-03", "s", 20)

    # zero live openers/closers => body-only message, no error
    only_bodies = for f <- pool(), f.kind == "body", do: f
    assert {:ok, %{text: t}} =
             Core.draw(only_bodies, %{}, @template, "tg:1:0", "2026-07-03", "s", 20)
    assert t in Enum.map(only_bodies, & &1.text)
  end

  test "weighted dressing: a zero-weight closer is never picked; empty text joins cleanly" do
    frags = [
      Core.fragment("opener", "Coo:", status: "live"),
      Core.fragment("body", "B.", status: "live"),
      Core.fragment("closer", "", status: "live", weight: 1),
      Core.fragment("closer", "NEVER", status: "live", weight: 0)
    ]
    for d <- 1..40 do
      {:ok, %{text: t}} = Core.draw(frags, %{}, @template, "tg:1:0", "2026-06-#{d}", "s", 20)
      refute String.contains?(t, "NEVER")
      assert t == "Coo: B."   # empty closer never leaves a trailing space
    end
  end
end

defmodule TipsCoreCommitTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips.Core

  @template [%{kind: "body", rotate: true}]

  defp bodies(n), do: for(i <- 1..n, do: Core.fragment("body", "Tip #{i}.", status: "live"))

  test "full cycle: every live body drawn exactly once before any repeat, then reshuffle" do
    pool = bodies(5)
    {seen_ids, seen_list} =
      Enum.reduce(1..5, {[], []}, fn day, {acc, seen_list} ->
        {:ok, %{rotating_ids: [id]}} =
          Core.draw(pool, %{"r" => seen_list}, @template, "r", "2026-07-#{day}", "s", 2)
        {seen_list, reshuffled} = Core.commit(pool, @template, seen_list, [id], 2)
        # reshuffle fires exactly on the 5th (coverage-completing) commit
        assert reshuffled == (day == 5)
        {[id | acc], seen_list}
      end)
    # all 5 distinct — no repeat within the cycle
    assert seen_ids |> Enum.uniq() |> length() == 5
    # after reshuffle only the most recent guard=2 survive, in draw order
    assert length(seen_list) == 2
    assert seen_list == (seen_ids |> Enum.reverse() |> Enum.take(-2))
  end

  test "re-committed id moves to most-recent without duplicating" do
    pool = bodies(4)
    [a, b, c | _] = Enum.map(pool, & &1.id)
    {seen, false} = Core.commit(pool, @template, [a, b, c], [a], 20)
    assert seen == [b, c, a]
  end

  test "pool of 1: guard clamps to 0 — repeats allowed rather than starvation" do
    pool = bodies(1)
    [id] = Enum.map(pool, & &1.id)
    {seen, true} = Core.commit(pool, @template, [], [id], 20)
    assert seen == []
    # and the next draw still works
    assert {:ok, %{rotating_ids: [^id]}} =
             Core.draw(pool, %{"r" => seen}, @template, "r", "2026-07-09", "s", 20)
  end

  test "retired ids remain in seen (retire never resurrects repeats); no rotating kinds => never reshuffles" do
    pool = bodies(3)
    [a | _] = Enum.map(pool, & &1.id)
    retired = Enum.map(pool, fn f -> if f.id == a, do: %{f | status: "retired"}, else: f end)
    # a stays in seen even though retired; coverage counts the 2 LIVE bodies
    {seen, false} = Core.commit(retired, @template, [a], [Enum.at(retired, 1).id], 20)
    assert a in seen
    # dressing-only template: commit is inert
    assert {[], false} = Core.commit(pool, [%{kind: "body", rotate: false}], [], [], 20)
  end

  test "draw falls back when the live set shrank to fully-seen (retire race) — no error, avoids most recent" do
    pool = bodies(3)
    ids = Enum.map(pool, & &1.id)
    {:ok, %{rotating_ids: [picked]}} =
      Core.draw(pool, %{"r" => ids}, @template, "r", "2026-07-08", "s", 1)
    refute picked == List.last(ids)
  end
end

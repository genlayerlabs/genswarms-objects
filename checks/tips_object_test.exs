# Tips object: JSON actions, lifecycle, store write-through seam.
# Standalone — no store, no network:  mix run checks/tips_object_test.exs
ExUnit.start()

defmodule TipsObjectLifecycleTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips

  defp send!(state, msg) do
    {:reply, reply, state} = Tips.handle_message(:cron, Jason.encode!(msg), state)
    {Jason.decode!(reply), state}
  end

  test "add_fragments always lands pending; promote gates drawability; retire removes it" do
    {:ok, state} = Tips.init(%{})
    assert state.template == [
             %{kind: "opener", rotate: false},
             %{kind: "body", rotate: true},
             %{kind: "closer", rotate: false}
           ]

    {r, state} =
      send!(state, %{
        "action" => "add_fragments",
        "fragments" => [
          %{"kind" => "body", "text" => "Tip A.", "category" => "hooks", "status" => "live"},
          %{"kind" => "body", "text" => "Tip A.", "weight" => 3},
          %{"kind" => "opener", "text" => "Coo:", "source" => "seed"},
          %{"kind" => "closer", "text" => "", "weight" => 9}
        ]
      })

    # duplicate (kind,text) deduped by content-addressed id; "status":"live" ignored
    assert r["ok"] == true
    assert r["count"] == 3
    assert Enum.all?(state.fragments, &(&1.status == "pending"))

    # nothing live yet: stats shows pending, draw path (Task 5) would empty_pool
    {r, state} = send!(state, %{"action" => "stats"})
    assert r["fragments"]["body/pending"] == 1
    assert r["fragments"]["opener/pending"] == 1
    assert r["recipients"] == 0

    ids = Enum.map(state.fragments, & &1.id)
    {r, state} = send!(state, %{"action" => "promote", "ids" => ids})
    assert r["ok"] == true and r["count"] == 3
    assert Enum.all?(state.fragments, &(&1.status == "live"))
    # promote is pending->live only: promoting again changes nothing
    {r, state} = send!(state, %{"action" => "promote", "ids" => ids})
    assert r["count"] == 0

    [first | _] = ids
    {r, state} = send!(state, %{"action" => "retire", "ids" => [first]})
    assert r["count"] == 1
    assert Enum.find(state.fragments, &(&1.id == first)).status == "retired"

    {r, _state} = send!(state, %{"action" => "stats"})
    assert r["fragments"]["body/retired"] == 1
  end

  test "malformed input replies bad_request; junk fragments are skipped" do
    {:ok, state} = Tips.init(%{})
    {:reply, reply, _} = Tips.handle_message(:x, "not json", state)
    assert %{"ok" => false, "error" => "bad_request"} = Jason.decode!(reply)

    {r, _} =
      send!(state, %{"action" => "add_fragments", "fragments" => [%{"kind" => "body"}, 42]})
    assert r["ok"] == true and r["count"] == 0
  end

  test "config: custom template, salt, guard normalize from string keys" do
    {:ok, state} =
      Tips.init(%{
        template: [%{"kind" => "nudge", "rotate" => true}],
        salt: "abc",
        reshuffle_guard: 3
      })
    assert state.template == [%{kind: "nudge", rotate: true}]
    assert state.salt == "abc"
    assert state.guard == 3
  end
end

defmodule FakeTipsStore do
  @moduledoc "Agent-backed store: exercises every seam callback."
  def start do
    Agent.start_link(fn -> %{fragments: %{}, seen: %{}, calls: []} end, name: __MODULE__)
  end

  def seed(fragments) do
    Agent.update(__MODULE__, fn s ->
      %{s | fragments: Map.new(fragments, &{&1.id, &1})}
    end)
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})

  # ── seam callbacks ──
  def load_fragments do
    record(:load_fragments)
    Agent.get(__MODULE__, &Map.values(&1.fragments))
  end

  def load_seen do
    record(:load_seen)
    Agent.get(__MODULE__, & &1.seen)
  end

  def save_fragment(f) do
    record({:save_fragment, f.id})
    Agent.update(__MODULE__, &put_in(&1, [:fragments, f.id], f))
  end

  def save_fragment_status(id, status) do
    record({:save_fragment_status, id, status})
    Agent.update(__MODULE__, fn s ->
      update_in(s, [:fragments, id], &%{&1 | status: status})
    end)
  end

  def add_seen(r, ids) do
    record({:add_seen, r, ids})
    Agent.update(__MODULE__, fn s ->
      update_in(s, [:seen], fn seen ->
        Map.update(seen, r, ids, fn l ->
          Enum.reject(l, fn id -> id in ids end) ++ ids
        end)
      end)
    end)
  end

  def replace_seen(r, keep) do
    record({:replace_seen, r, keep})
    Agent.update(__MODULE__, &put_in(&1, [:seen, r], keep))
  end
end

defmodule TipsObjectDrawCommitTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips
  alias Genswarms.Tips.Core

  defp send!(state, msg) do
    {:reply, reply, state} = Tips.handle_message(:cron, Jason.encode!(msg), state)
    {Jason.decode!(reply), state}
  end

  defp live_pool do
    [
      Core.fragment("opener", "Coo coo:", status: "live", source: "seed"),
      Core.fragment("body", "Tip 1.", status: "live", source: "seed"),
      Core.fragment("body", "Tip 2.", status: "live", source: "seed"),
      Core.fragment("body", "Tip 3.", status: "live", source: "seed"),
      Core.fragment("closer", "", status: "live", weight: 5, source: "seed")
    ]
  end

  test "draw is a pure read (state unchanged, repeatable); commit records and persists" do
    {:ok, _} = FakeTipsStore.start()
    FakeTipsStore.seed(live_pool())
    {:ok, state} = Tips.init(%{store: FakeTipsStore, reshuffle_guard: 1})
    assert length(state.fragments) == 5

    msg = %{"action" => "draw", "recipient_id" => "tg:9:0", "date" => "2026-07-03"}
    {r1, state} = send!(state, msg)
    {r2, state} = send!(state, msg)
    assert r1 == r2
    assert r1["ok"] == true
    assert [body_id] = r1["fragment_ids"]
    assert String.contains?(r1["text"], "Tip ")
    # pure read: nothing persisted yet
    refute Enum.any?(FakeTipsStore.calls(), &match?({:add_seen, _, _}, &1))

    {rc, state} = send!(state, %{
      "action" => "commit", "recipient_id" => "tg:9:0", "fragment_ids" => [body_id]
    })
    assert rc == %{"ok" => true, "reshuffled" => false}
    assert {:add_seen, "tg:9:0", [^body_id]} =
             Enum.find(FakeTipsStore.calls(), &match?({:add_seen, _, _}, &1))

    # next draw excludes the committed body
    {r3, _state} = send!(state, %{
      "action" => "draw", "recipient_id" => "tg:9:0", "date" => "2026-07-04"
    })
    refute r3["fragment_ids"] == [body_id]
  end

  test "cycle completion commits via replace_seen; empty pool replies empty_pool" do
    {:ok, _} = FakeTipsStore.start()
    FakeTipsStore.seed(live_pool())
    {:ok, state} = Tips.init(%{store: FakeTipsStore, reshuffle_guard: 1})

    state =
      Enum.reduce(1..3, state, fn day, state ->
        {r, state} = send!(state, %{
          "action" => "draw", "recipient_id" => "r", "date" => "2026-07-0#{day}"
        })
        {rc, state} = send!(state, %{
          "action" => "commit", "recipient_id" => "r", "fragment_ids" => r["fragment_ids"]
        })
        assert rc["reshuffled"] == (day == 3)
        state
      end)

    assert [{:replace_seen, "r", keep}] =
             Enum.filter(FakeTipsStore.calls(), &match?({:replace_seen, _, _}, &1))
    assert length(keep) == 1
    assert map_size(state.seen) == 1

    # no live bodies at all -> empty_pool error reply
    {:ok, bare} = Tips.init(%{})
    {r, _} = send!(bare, %{"action" => "draw", "recipient_id" => "r", "date" => "2026-07-03"})
    assert r == %{"ok" => false, "error" => "empty_pool"}
  end

  test "init loads seen state from the store — rotation survives a restart" do
    {:ok, _} = FakeTipsStore.start()
    pool = live_pool()
    [_, b1, b2 | _] = pool
    FakeTipsStore.seed(pool)
    FakeTipsStore.add_seen("r", [b1.id, b2.id])
    {:ok, state} = Tips.init(%{store: FakeTipsStore})

    {r, _} = send!(state, %{"action" => "draw", "recipient_id" => "r", "date" => "2026-07-05"})
    b3 = Enum.find(pool, &(&1.kind == "body" and &1.id not in [b1.id, b2.id]))
    assert r["fragment_ids"] == [b3.id]
  end
end

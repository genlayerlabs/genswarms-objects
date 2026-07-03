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

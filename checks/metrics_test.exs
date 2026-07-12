# Metrics object: bump accumulation, flush-to-store seam, memory-only fallback.
# Standalone — no store, no network:  mix run checks/metrics_test.exs
ExUnit.start()

defmodule FakeMetricsStore do
  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
  def add_metrics(pending), do: Agent.update(__MODULE__, &Map.merge(&1, pending, fn _, a, b -> a + b end))
  def today_metrics, do: Agent.get(__MODULE__, & &1)
end

defmodule GenswarmsMetricsTest do
  use ExUnit.Case, async: false
  alias Genswarms.Metrics

  test "bumps accumulate in pending+totals and flush lands on the store" do
    {:ok, _} = FakeMetricsStore.start()
    {:ok, state} = Metrics.init(%{flush_ms: 0, store: FakeMetricsStore})

    {:noreply, state} =
      Metrics.handle_message(:sender, Jason.encode!(%{"action" => "bump", "key" => "reply_sent"}), state)

    {:noreply, state} =
      Metrics.handle_message(
        :sender,
        Jason.encode!(%{"action" => "bump", "key" => "reply_sent", "n" => 2}),
        state
      )

    assert state.totals["reply_sent"] == 3
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert FakeMetricsStore.today_metrics()["reply_sent"] == 3
    assert state.pending == %{}
  end

  test "memory-only: no store configured — bumps survive in totals, flush never crashes" do
    {:ok, state} = Metrics.init(%{flush_ms: 0})
    assert state.store == nil

    {:noreply, state} =
      Metrics.handle_message(:x, Jason.encode!(%{"action" => "bump", "key" => "llm_error"}), state)

    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.totals["llm_error"] == 1
  end

  test "store ref as string resolves without minting; unknown string degrades to memory" do
    {:ok, state} = Metrics.init(%{flush_ms: 0, store: "FakeMetricsStore"})
    assert state.store == FakeMetricsStore
    {:ok, state2} = Metrics.init(%{flush_ms: 0, store: "No.Such.Store"})
    assert state2.store == nil
  end
end



defmodule GenswarmsMetricsExtraKeysTest do
  use ExUnit.Case, async: false
  alias Genswarms.Metrics

  test "extra_keys extends the closed set; unknown keys still rejected" do
    {:ok, state} = Metrics.init(%{flush_ms: 0, extra_keys: ["my_app_event"]})

    {:noreply, state} =
      Metrics.handle_message(:x, Jason.encode!(%{"action" => "bump", "key" => "my_app_event"}), state)

    assert state.totals["my_app_event"] == 1

    {:noreply, state} =
      Metrics.handle_message(:x, Jason.encode!(%{"action" => "bump", "key" => "minted_by_agent"}), state)

    refute Map.has_key?(state.totals, "minted_by_agent")
  end

  test "the enumerated LLM proxy compaction counters are admitted" do
    {:ok, state} = Metrics.init(%{flush_ms: 0})

    {:noreply, state} =
      Metrics.handle_message(
        :x,
        Jason.encode!(%{"action" => "bump", "key" => "llm_proxy_compact"}),
        state
      )

    {:noreply, state} =
      Metrics.handle_message(
        :x,
        Jason.encode!(%{"action" => "bump", "key" => "llm_proxy_compact_block"}),
        state
      )

    assert state.totals["llm_proxy_compact"] == 1
    assert state.totals["llm_proxy_compact_block"] == 1
    refute Map.has_key?(state.totals, "metrics_rejected")
  end
end

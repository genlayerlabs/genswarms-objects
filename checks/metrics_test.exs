# Metrics object: bump accumulation, flush-to-store seam, memory-only fallback.
# Standalone — no store, no network:  mix run checks/metrics_test.exs
ExUnit.start()

defmodule FakeMetricsStore do
  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def add_metrics(pending),
    do: Agent.update(__MODULE__, &Map.merge(&1, pending, fn _, a, b -> a + b end))

  def today_metrics, do: Agent.get(__MODULE__, & &1)
end

defmodule GenswarmsMetricsTest do
  use ExUnit.Case, async: false
  alias Genswarms.Metrics

  test "bumps accumulate in pending+totals and flush lands on the store" do
    {:ok, _} = FakeMetricsStore.start()
    {:ok, state} = Metrics.init(%{flush_ms: 0, store: FakeMetricsStore})

    {:noreply, state} =
      Metrics.handle_message(
        :sender,
        Jason.encode!(%{"action" => "bump", "key" => "reply_sent"}),
        state
      )

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
      Metrics.handle_message(
        :x,
        Jason.encode!(%{"action" => "bump", "key" => "llm_error"}),
        state
      )

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
      Metrics.handle_message(
        :x,
        Jason.encode!(%{"action" => "bump", "key" => "my_app_event"}),
        state
      )

    assert state.totals["my_app_event"] == 1

    {:noreply, state} =
      Metrics.handle_message(
        :x,
        Jason.encode!(%{"action" => "bump", "key" => "minted_by_agent"}),
        state
      )

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

defmodule RetryMetricsStore do
  def start,
    do: Agent.start_link(fn -> %{days: %{}, batches: %{}, mode: :ok} end, name: __MODULE__)

  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
  def read, do: Agent.get(__MODULE__, & &1)
  def today_metrics, do: Map.get(read().days, Date.utc_today(), %{})

  def add_metrics_batch(id, %Date{} = day, deltas) when is_binary(id) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        state.mode == :down ->
          {{:error, :offline}, state}

        Map.has_key?(state.batches, id) ->
          if state.batches[id] != {day, deltas}, do: raise("retry changed payload")
          {:ok, state}

        true ->
          counts = Map.merge(Map.get(state.days, day, %{}), deltas, fn _, a, b -> a + b end)

          state = %{
            state
            | days: Map.put(state.days, day, counts),
              batches: Map.put(state.batches, id, {day, deltas})
          }

          result = if state.mode == :ambiguous, do: {:error, :timeout}, else: :ok
          {result, state}
      end
    end)
  end
end

defmodule GenswarmsMetricsDurabilityTest do
  use ExUnit.Case, async: false
  alias Genswarms.Metrics

  setup do
    {:ok, _} = RetryMetricsStore.start()
    :ok
  end

  defp init(opts \\ %{}),
    do: Metrics.init(Map.merge(%{flush_ms: 0, store: RetryMetricsStore}, opts))

  defp bump(state, n \\ 1) do
    {:noreply, state} =
      Metrics.handle_message(
        :sender,
        Jason.encode!(%{action: "bump", key: "reply_sent", n: n}),
        state
      )

    state
  end

  defp snapshot(state) do
    {:reply, reply, _} = Metrics.handle_message(:test, ~s({"action":"snapshot"}), state)
    Jason.decode!(reply)
  end

  test "a successful bump survives object restart without a timer flush" do
    {:ok, state} = init()
    state = bump(state, 2)
    assert state.pending == %{}
    {:ok, restarted} = init()
    assert snapshot(restarted)["today"]["reply_sent"] == 2
    assert snapshot(state)["persistence"]["status"] == "persisted"
  end

  test "failed writes remain pending and recover on flush" do
    RetryMetricsStore.mode(:down)
    {:ok, state} = init()
    state = bump(state, 2)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{"reply_sent" => 2}
    assert snapshot(state)["persistence"]["status"] == "pending"
    assert snapshot(state)["persistence"]["last_error"] == "write_failed"
    RetryMetricsStore.mode(:ok)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{}
    assert snapshot(state)["today"]["reply_sent"] == 2
    assert snapshot(state)["persistence"]["last_error"] == nil
  end

  test "ambiguous commit retries the original batch once and new bumps stay separate" do
    RetryMetricsStore.mode(:ambiguous)
    {:ok, state} = init()
    state = bump(state, 2)
    RetryMetricsStore.mode(:down)
    state = bump(state, 3)
    assert state.pending == %{"reply_sent" => 5}
    RetryMetricsStore.mode(:ok)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{}
    assert snapshot(state)["today"]["reply_sent"] == 5
    assert map_size(RetryMetricsStore.read().batches) == 2
  end

  test "midnight retries retain the UTC event day including coalesced bumps" do
    Process.put(:metrics_now, ~U[2026-09-24 23:59:59Z])
    RetryMetricsStore.mode(:down)
    {:ok, state} = init(%{now_fn: fn -> Process.get(:metrics_now) end})
    state = state |> bump(2) |> bump(3)
    Process.put(:metrics_now, ~U[2026-09-25 00:00:01Z])
    state = bump(state, 7)
    RetryMetricsStore.mode(:ok)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{}

    assert RetryMetricsStore.read().days == %{
             ~D[2026-09-24] => %{"reply_sent" => 5},
             ~D[2026-09-25] => %{"reply_sent" => 7}
           }
  end

  test "store exceptions cannot crash away pending counters or fake a healthy today" do
    defmodule RaisingStore do
      def add_metrics_batch(_, _, _), do: exit(:offline)
      def today_metrics, do: raise("offline")
    end

    {:ok, state} = init(%{store: RaisingStore})
    state = bump(state)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{"reply_sent" => 1}
    assert snapshot(state)["today"] == nil
    assert snapshot(state)["persistence"]["status"] == "pending"
  end

  test "legacy nil write keeps pending but does not claim durable persistence" do
    defmodule FailedLegacyStore do
      def add_metrics(_), do: nil
      def today_metrics, do: %{}
    end

    {:ok, state} = init(%{store: FailedLegacyStore})
    state = bump(state)
    {:noreply, state} = Metrics.handle_info(:flush, state)
    assert state.pending == %{"reply_sent" => 1}
    assert snapshot(state)["persistence"]["status"] == "best_effort"
  end
end

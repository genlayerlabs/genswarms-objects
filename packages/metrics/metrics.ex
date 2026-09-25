defmodule Genswarms.Metrics do
  @moduledoc """
  Metrics — lightweight operational counters for swarm health.

  Other objects fire-and-forget a bump here:

      {"action":"bump","key":"reply_sent"}      # optional "n" (default 1)

  With `add_metrics_batch/3`, every bump attempts persistence immediately, stamped
  with its UTC event day and a unique batch ID. The store must atomically deduplicate
  that ID and increment the deltas, returning `:ok` only after commit. Failed or
  ambiguous attempts retain their original ID/day/payload for retry on the next
  bump or timer. Successfully committed counts survive an object restart.

  Pending writes are MEMORY ONLY: a process crash during an outage can lose them.
  One attempted batch is immutable; later bumps coalesce by UTC day and closed key.
  Memory therefore grows with outage days, not event volume. Fire-and-forget messages
  can also be lost before handling. Legacy `add_metrics/1` stores retain periodic,
  best-effort writes without atomic retry or event-day guarantees.

  ## Known keys (v1)
    - `reply_sent`       — sender delivered a conversational reply
    - `reply_failed`     — a conversational reply was empty or failed to deliver
    - `eligible_pending` — `policy.eligible?` returned `pending` (M2 not wired)
    - `connect`          — a Telegram link was confirmed (funnel success)
    - `inbox_full`       — ingress: agent inbox rejected a user message (#56; user notified)
    - `inbox_dropped`    — engine telemetry: backend died with N queued tasks stranded (#56)
    - `llm_error`        — a conversation turn ended with an LLM API error / step-budget exhaustion
                           (no reply produced); the user got a graceful notice (LlmErrorNotifier).
                           Split into two class counters bumped alongside it:
    - `llm_error_max_turns` — the `error: max turns` step-budget exit (the empty/malformed
                           tool-call spiral signature; SHOULD fall when a reliable tool-caller is pinned)
    - `llm_error_api`    — a provider `API error:` / exhaustion / 5xx (capacity failure,
                           orthogonal to model choice; should NOT move with a model swap)
    - `llm_proxy_compact` — the LLM proxy compacted an oversized request before sending it
    - `llm_proxy_compact_block` — compaction still could not make a request admissible
    - `orchestrator_boot`— the orchestrator BEAM started (bumped once per boot in run_live.exs);
                           a spike = a launchd relaunch storm (the load-test two-poller incident)
    - `spawn_shed`       — ingress shed a NEW-conversation spawn because the global spawn
                           token-bucket was exhausted (public-launch flood guard); a nonzero
                           count is a Sybil-flood / spawn-storm signal, NOT normal traffic
    - `metrics_rejected` — a `bump` for a key NOT on the allowlist was dropped (an untrusted
                           sandbox agent abusing the always-routable :metrics, or a new legit
                           key that must be added to `@known_keys` above)

  The key set is CLOSED to a fully-enumerated `@known_keys` allowlist (NO open-ended prefix
  match — a prefix family like `llm_proxy_*` would reopen the amplification): a bump for an
  unknown key is dropped and counted under `metrics_rejected`. This bounds the durable
  metrics_daily rows + the in-memory maps to a fixed key space — `:metrics` is always
  routable (Router @system_objects), so an untrusted sandbox agent could otherwise mint
  unbounded random keys. Add new LEGIT keys to the allowlist above.

  ## Why it's safe to leave always-on
  A bump is a fire-and-forget cast off the caller's hot path; totals are bounded by
  the fixed key set (outage buffers additionally grow per UTC day); with persistence disabled the
  flush is a no-op (counts still accumulate + log since boot). If this object is
  down, callers' bumps just drop — nothing else breaks.

  ## Config
    - `flush_ms` — flush + log period in ms (default 300_000 = 5 min). `nil`/0 to
      disable the retry/log timer (drive `:flush` manually, e.g. in tests).
    - `now_fn` — UTC DateTime clock (default `DateTime.utc_now/0`).
  """

  require Logger

  @default_flush_ms 300_000
  # The keys shown in the periodic log line (in this order). Others still persist.
  # Only keys that are actually bumped somewhere — reply_reprompt/reply_fallback were
  # never instrumented, so printing them as a permanent "=0" was misleading.
  @summary_keys ~w(reply_sent reply_failed reply_suppressed card_sent eligible_pending connect new_conversation returning_user notes_written llm_error_max_turns llm_error_api spawn_shed llm_proxy_request_quota_block llm_proxy_global_block metrics_rejected)

  # Bump-key allowlist — a CLOSED, fully-enumerated set. `:metrics` is ALWAYS routable
  # (Router @system_objects), so a prompt-injected/jailbroken sandbox agent can deliver
  # `bump` directly. Without this, bump accepted ANY string key → each distinct key mints a
  # durable metrics_daily row (INSERT…ON CONFLICT(day,key)) AND grows the in-memory
  # pending/totals maps, so a loop over random keys = unbounded PG rows + orchestrator BEAM
  # OOM (shared-fate). NB: this used to ALSO allow the open-ended prefix families
  # `llm_proxy_*` / `llm_error_*`, which REOPENED that exact amplification — an agent loops
  # bumps of `llm_proxy_<i>` for unbounded i, every one allowed AND invisible to
  # metrics_rejected. The legit proxy/error keys are a FIXED enumerable set, so they are
  # listed here explicitly and the prefix match is gone. An unknown key is dropped + counted
  # under `metrics_rejected` so drift (a new legit key to add) or an attack is visible. Add
  # new LEGIT keys here (and keep them in sync with the bumps in objects/llm/proxy.ex +
  # objects/llm_error_notifier.ex).
  @known_keys ~w(
    reply_sent reply_failed reply_suppressed reply_reprompt reply_fallback card_sent
    eligible_pending
    connect new_conversation returning_user notes_written inbox_full inbox_dropped ask
    compaction browse_ok browse_total orchestrator_boot reengage agent_spawn_failed
    proactive_sent progress_sent progress_edit llm_error spawn_shed metrics_rejected
    llm_error_max_turns llm_error_api
    llm_proxy_requests llm_proxy_stream llm_proxy_budget_degraded llm_proxy_budget_block
    llm_proxy_budget_block_notified llm_proxy_request_quota_block llm_proxy_global_block llm_proxy_cost_invalid
    llm_proxy_upstream_error llm_proxy_upstream_retry llm_proxy_internal_error
    llm_proxy_compact llm_proxy_compact_block
    llm_proxy_stream_status_mismatch llm_proxy_stream_unmetered llm_proxy_stream_disconnected
    llm_proxy_stream_truncated
  )
  @max_bump 1_000_000

  @doc false
  # Host-declared keys extend the baseline — STILL a closed set (pure data in the
  # swarm config), never an open prefix: the anti-amplification posture holds.
  def allowed_key?(key, extra \\ MapSet.new())

  def allowed_key?(key, extra) when is_binary(key),
    do: key in @known_keys or MapSet.member?(extra, key)

  def allowed_key?(_, _), do: false

  def init(config) do
    flush_ms = Map.get(config, :flush_ms, @default_flush_ms)
    if is_integer(flush_ms) and flush_ms > 0, do: Process.send_after(self(), :flush, flush_ms)
    # pending: all unacknowledged deltas, including the immutable retry batch.
    # totals:  cumulative since boot (for the snapshot / ad-hoc introspection).
    {:ok,
     %{
       pending: %{},
       totals: %{},
       queued_days: %{},
       batch: nil,
       last_error: nil,
       now_fn: Map.get(config, :now_fn, &DateTime.utc_now/0),
       flush_ms: flush_ms,
       store: module_ref(Map.get(config, :store)),
       extra_keys: MapSet.new(Map.get(config, :extra_keys, []) |> Enum.map(&to_string/1))
     }}
  end

  def interface do
    %{
      bump: %{
        input: ~s({"action":"bump","key":"reply_sent"}),
        output: "(none — fire and forget)"
      },
      snapshot: %{
        input: ~s({"action":"snapshot"}),
        output: ~s({"totals":{...},"pending":{...},"today":{...}})
      }
    }
  end

  def handle_message(from, content, state) do
    # display chatter: bookkeeping bumps (sender/ingress → metrics) for the canvas;
    # consumers without a node for the sender simply drop the packet
    :telemetry.execute(
      Application.get_env(:genswarms_objects, :display_wire, [:genswarms, :display]),
      %{},
      %{kind: :chatter, from: to_string(from), to: "metrics"}
    )

    case Jason.decode(content) do
      # is_binary(key) guard: bumps are fire-and-forget casts — a MAP key would crash
      # the object via to_string's Protocol.UndefinedError (a charlist-ish list merely
      # mints a junk key, e.g. ["a","b"] → "ab"). Either way: non-binary is dropped.
      {:ok, %{"action" => "bump", "key" => key} = msg} when is_binary(key) ->
        # Allowlist + clamp: unknown keys are dropped (counted under metrics_rejected so
        # the gate is observable); n is bounded so one call can't inject a 10^18 value.
        if allowed_key?(key, Map.get(state, :extra_keys, MapSet.new())) do
          amount =
            case Map.get(msg, "n", 1) do
              n when is_integer(n) and n > 0 -> min(n, @max_bump)
              _ -> 1
            end

          {:noreply, bump(state, key, amount)}
        else
          {:noreply, bump(state, "metrics_rejected", 1)}
        end

      # Ad-hoc introspection (tests + manual): in-memory tallies + today's durable row.
      {:ok, %{"action" => "snapshot"}} ->
        reply =
          Jason.encode!(%{
            totals: state.totals,
            pending: state.pending,
            today: store_today(state.store, state.totals),
            persistence: %{status: persistence_status(state), last_error: state.last_error}
          })

        {:reply, reply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    if is_integer(state.flush_ms) and state.flush_ms > 0,
      do: Process.send_after(self(), :flush, state.flush_ms)

    {:noreply, flush(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ────────────────────────────────────────────────────────────────

  defp bump(state, key, amount) do
    state = %{
      state
      | pending: Map.update(state.pending, key, amount, &(&1 + amount)),
        totals: Map.update(state.totals, key, amount, &(&1 + amount))
    }

    if store?(state.store, :add_metrics_batch, 3) do
      day = state.now_fn.() |> DateTime.to_date()

      queued =
        Map.update(state.queued_days, day, %{key => amount}, fn deltas ->
          Map.update(deltas, key, amount, &(&1 + amount))
        end)

      persist_batches(%{state | queued_days: queued})
    else
      state
    end
  end

  defp flush(state) do
    state =
      cond do
        store?(state.store, :add_metrics_batch, 3) ->
          persist_batches(state)

        map_size(state.pending) == 0 ->
          state

        store?(state.store, :add_metrics, 1) ->
          case safe_write(state.store, :add_metrics, [state.pending]) do
            :ok -> %{state | pending: %{}, last_error: nil}
            _ -> %{state | last_error: "write_failed"}
          end

        true ->
          %{state | pending: %{}}
      end

    log_summary(state.store)
    state
  end

  defp persist_batches(%{batch: nil, queued_days: days} = state) when map_size(days) == 0,
    do: state

  defp persist_batches(%{batch: nil} = state) do
    # ponytail: one map per outage day; use a durable outbox if outage crash recovery is required.
    {day, deltas} = Enum.min_by(state.queued_days, fn {day, _} -> Date.to_gregorian_days(day) end)
    id = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    persist_batches(%{
      state
      | batch: {id, day, deltas},
        queued_days: Map.delete(state.queued_days, day)
    })
  end

  defp persist_batches(%{batch: {id, day, deltas}} = state) do
    case safe_write(state.store, :add_metrics_batch, [id, day, deltas]) do
      :ok ->
        pending =
          Enum.reduce(deltas, state.pending, fn {key, amount}, pending ->
            case pending[key] - amount do
              0 -> Map.delete(pending, key)
              remaining -> Map.put(pending, key, remaining)
            end
          end)

        persist_batches(%{state | batch: nil, pending: pending, last_error: nil})

      _ ->
        %{state | last_error: "write_failed"}
    end
  end

  defp safe_write(store, callback, args) do
    apply(store, callback, args)
  rescue
    _ -> {:error, :write_failed}
  catch
    _, _ -> {:error, :write_failed}
  end

  defp persistence_status(state) do
    cond do
      store?(state.store, :add_metrics_batch, 3) ->
        if map_size(state.pending) == 0, do: "persisted", else: "pending"

      store?(state.store, :add_metrics, 1) ->
        "best_effort"

      true ->
        "memory_only"
    end
  end

  defp log_summary(store) do
    today = store_today(store, %{})

    if is_map(today) do
      summary =
        @summary_keys
        |> Enum.map(fn k -> "#{k}=#{Map.get(today, k, 0)}" end)
        |> Enum.join(" ")

      Logger.info("[metrics] #{summary}")
    else
      Logger.warning("[metrics] today's counters unavailable")
    end
  end

  # ── package seams ────────────────────────────────────────────────────────────
  # Durable store is optional: without one (or without the callback) counters
  # live in `totals` for the boot session only — fail-open, never crash a bump.
  defp store?(store, fun, arity) do
    is_atom(store) and not is_nil(store) and Code.ensure_loaded?(store) and
      function_exported?(store, fun, arity)
  end

  defp store_today(store, fallback) do
    result = if store?(store, :today_metrics, 0), do: store.today_metrics(), else: fallback
    if is_map(result), do: result, else: nil
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Module refs arrive as atoms (Elixir swarm defs) or strings (JSON IR).
  # Strings resolve via to_existing_atom — no atom minting; unknown -> nil.
  defp module_ref(nil), do: nil
  defp module_ref(mod) when is_atom(mod), do: mod

  defp module_ref(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp module_ref(_), do: nil
end

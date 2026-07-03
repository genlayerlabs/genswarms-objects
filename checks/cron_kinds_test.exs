# Cron object semantics for schedule kinds: create-time floor + past-guard,
# claimed-due stashing, and recurring re-arm on the grid after a successful run.
#
#   mix run checks/cron_kinds_test.exs

alias Genswarms.Cron

{:ok, fails} = Agent.start_link(fn -> [] end)

check = fn name, cond ->
  if cond do
    IO.puts("  \e[32m✓\e[0m #{name}")
  else
    IO.puts("  \e[31m✗ #{name}\e[0m")
    Agent.update(fails, &[name | &1])
  end
end

IO.puts("\n══ Cron object: schedule kinds (create validation, claimed due, recurring re-arm) ══\n")

ms = fn iso ->
  {:ok, dt, _} = DateTime.from_iso8601(iso)
  DateTime.to_unix(dt, :millisecond)
end

base_now = ms.("2026-07-06T14:00:00Z")

new_state = fn now ->
  {:ok, clock} = Agent.start_link(fn -> now end)
  {:ok, sink} = Agent.start_link(fn -> [] end)

  config = %{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(clock, & &1) end,
    deliver_fn: fn target, from, json ->
      Agent.update(sink, &[{target, from, json} | &1])
      :ok
    end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000
  }

  {:ok, state} = Cron.init(config)
  {state, clock, sink}
end

set_clock = fn clock, t -> Agent.update(clock, fn _ -> t end) end
sink_messages = fn sink -> Agent.get(sink, &Enum.reverse/1) end

# Same harness as new_state, but deliver_fn consults a toggle Agent: {:error, "boom"}
# while true, a real sink-recording success while false — lets vectors flip a job's
# delivery outcome mid-flight (fail-then-succeed retry vectors).
new_state_toggle = fn now, fail_agent ->
  {:ok, clock} = Agent.start_link(fn -> now end)
  {:ok, sink} = Agent.start_link(fn -> [] end)

  config = %{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(clock, & &1) end,
    deliver_fn: fn target, from, json ->
      if Agent.get(fail_agent, & &1) do
        {:error, "boom"}
      else
        Agent.update(sink, &[{target, from, json} | &1])
        :ok
      end
    end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000
  }

  {:ok, state} = Cron.init(config)
  {state, clock, sink}
end

create = fn state, from, extra ->
  msg = Map.merge(%{action: "create_job", target: "proactive", message: %{"action" => "run"}}, extra)
  Cron.handle_message(from, Jason.encode!(msg), state)
end

tick = fn state, from ->
  Cron.handle_message(from, Jason.encode!(%{action: "tick"}), state)
end

# ── Vector 1: every_ms create — first-fire rule (next_run_at == now + period) ──

{state1, _clock1, _sink1} = new_state.(base_now)

{:reply, reply1, state1} = create.(state1, :ops, %{schedule: %{every_ms: 300_000}})
decoded1 = Jason.decode!(reply1)

check.(
  "create_job every_ms=300000 → ok, next_run_at == now + period (first-fire rule)",
  decoded1["ok"] == true and decoded1["next_run_at"] == base_now + 300_000 and
    map_size(state1.jobs) == 1
)

# ── Vector 2: cron kinds — satisfiable ok, unsatisfiable rejected ──

{state2, _clock2, _sink2} = new_state.(base_now)

{:reply, reply2a, state2} = create.(state2, :ops, %{schedule: %{cron: "0 * * * *"}})
decoded2a = Jason.decode!(reply2a)

{:reply, reply2b, _state2} = create.(state2, :ops, %{schedule: %{cron: "0 0 30 2 *"}})
decoded2b = Jason.decode!(reply2b)

check.(
  "create_job cron=\"0 * * * *\" → ok; cron=\"0 0 30 2 *\" (Feb 30) → rejected, error mentions unsatisfiable",
  decoded2a["ok"] == true and
    decoded2b["ok"] == false and
    String.contains?(decoded2b["error"] || "", "unsatisfiable")
)

# ── Vector 3: floor is every_ms-only ──

{state3, _clock3, _sink3} = new_state.(base_now)

{:reply, reply3a, state3} = create.(state3, :ops, %{schedule: %{every_ms: 30_000}})
decoded3a = Jason.decode!(reply3a)

{:reply, reply3b, _state3} =
  create.(state3, :ops, %{run_at: base_now + 30_000})

decoded3b = Jason.decode!(reply3b)

check.(
  "floor rejects every_ms below min_period_ms; a one-shot run_at 30s out is unaffected by the floor",
  decoded3a["ok"] == false and String.contains?(decoded3a["error"] || "", "min_period_ms") and
    decoded3b["ok"] == true
)

# ── Vector 4: past-guard, one-tick grace ──

{state4, _clock4, _sink4} = new_state.(base_now)

{:reply, reply4a, state4} =
  create.(state4, :ops, %{run_at: base_now - 2 * 60_000})

decoded4a = Jason.decode!(reply4a)

{:reply, reply4b, _state4} =
  create.(state4, :ops, %{run_at: base_now - 10_000})

decoded4b = Jason.decode!(reply4b)

check.(
  "past-guard rejects run_at older than one tick_ms; run_at within one tick_ms grace is accepted",
  decoded4a["ok"] == false and decoded4a["error"] == "run_at_past" and
    decoded4b["ok"] == true
)

# ── Vector 5: recurring fire + re-arm on the grid ──

{state5, clock5, sink5} = new_state.(base_now)

{:reply, reply5, state5} = create.(state5, :ops, %{schedule: %{every_ms: 300_000}})
job5_id = Jason.decode!(reply5)["job_id"]

set_clock.(clock5, base_now + 300_000)

{:reply, tick5_reply, state5} = tick.(state5, :ops)
decoded_tick5 = Jason.decode!(tick5_reply)
job5_after = Map.fetch!(state5.jobs, job5_id)

check.(
  "recurring fire + re-arm: one delivery, job stays active, next_run_at advances one grid period, attempts reset to 0",
  decoded_tick5["launched"] == 1 and
    sink_messages.(sink5) == [{:proactive, :cron, Jason.encode!(%{"action" => "run"})}] and
    job5_after.state == "active" and
    job5_after.next_run_at == base_now + 600_000 and
    job5_after.attempts == 0
)

# ── Vector 6: downtime catch-up — exactly one delivery, next is the strictly-future grid point ──

set_clock.(clock5, base_now + 1_650_000)
Agent.update(sink5, fn _ -> [] end)

{:reply, tick6_reply, state6} = tick.(state5, :ops)
decoded_tick6 = Jason.decode!(tick6_reply)
job6_after = Map.fetch!(state6.jobs, job5_id)

check.(
  "downtime catch-up (3.5 periods late): exactly one delivery, next_run_at is the strictly-future grid point",
  decoded_tick6["launched"] == 1 and
    length(sink_messages.(sink5)) == 1 and
    job6_after.next_run_at == base_now + 1_800_000 and
    job6_after.next_run_at > base_now + 1_650_000
)

# ── Vector 7: one-shot completes to done exactly as 0.1.1 ──

{state7, clock7, _sink7} = new_state.(base_now)

{:reply, reply7, state7} = create.(state7, :ops, %{run_at: base_now + 60_000})
job7_id = Jason.decode!(reply7)["job_id"]

set_clock.(clock7, base_now + 60_000)

{:reply, _tick7_reply, state7} = tick.(state7, :ops)

{:reply, list7_reply, _state7} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "list"}), state7)

list7 = Jason.decode!(list7_reply)["jobs"]

check.(
  "one-shot completes to done exactly as 0.1.1: job removed from active set, list shows no non-terminal job",
  not Map.has_key?(state7.jobs, job7_id) and list7 == []
)

# ── Vector 8: recurring occurrence exhaustion → active, consecutive_failures 1, grid next ──

{:ok, fail8} = Agent.start_link(fn -> true end)
{state8, clock8, _sink8} = new_state_toggle.(base_now, fail8)

{:reply, reply8, state8} =
  create.(state8, :ops, %{
    schedule: %{every_ms: 300_000},
    max_attempts: 2,
    retry_backoff_ms: 60_000
  })

job8_id = Jason.decode!(reply8)["job_id"]

set_clock.(clock8, base_now + 300_000)
{:reply, _tick8a, state8} = tick.(state8, :ops)

set_clock.(clock8, base_now + 360_000)
{:reply, _tick8b, state8} = tick.(state8, :ops)

job8_after = Map.fetch!(state8.jobs, job8_id)

check.(
  "recurring occurrence exhaustion (max_attempts 2): job stays active, consecutive_failures 1, next_run_at on the grid, attempts reset, last_status error",
  job8_after.state == "active" and
    job8_after.consecutive_failures == 1 and
    job8_after.next_run_at == base_now + 600_000 and
    job8_after.attempts == 0 and
    job8_after.last_status == "error"
)

# ── Vector 9: breaker_threshold 2 — a second exhausted occurrence pauses the job ──

{:ok, fail9} = Agent.start_link(fn -> true end)
{state9, clock9, _sink9} = new_state_toggle.(base_now, fail9)

{:reply, reply9, state9} =
  create.(state9, :ops, %{
    schedule: %{every_ms: 300_000},
    max_attempts: 2,
    retry_backoff_ms: 60_000,
    breaker_threshold: 2
  })

job9_id = Jason.decode!(reply9)["job_id"]

set_clock.(clock9, base_now + 300_000)
{:reply, _tick9a, state9} = tick.(state9, :ops)
set_clock.(clock9, base_now + 360_000)
{:reply, _tick9b, state9} = tick.(state9, :ops)

job9_mid = Map.fetch!(state9.jobs, job9_id)

set_clock.(clock9, base_now + 600_000)
{:reply, _tick9c, state9} = tick.(state9, :ops)
set_clock.(clock9, base_now + 660_000)
{:reply, _tick9d, state9} = tick.(state9, :ops)

job9_after = Map.fetch!(state9.jobs, job9_id)

check.(
  "breaker_threshold 2: first exhausted occurrence stays active (consecutive_failures 1); second exhausted occurrence pauses the job (breaker)",
  job9_mid.state == "active" and job9_mid.consecutive_failures == 1 and
    job9_after.state == "paused" and job9_after.paused_by == "breaker" and
    job9_after.consecutive_failures == 2 and job9_after.next_run_at == nil
)

# ── Vector 10: resume on a breaker-paused job clears the breaker and coalesce-arms now ──

set_clock.(clock9, base_now + 700_000)

{:reply, reply10, state10} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: job9_id}), state9)

decoded10 = Jason.decode!(reply10)
job10_after = Map.fetch!(state10.jobs, job9_id)

check.(
  "resume on a breaker-paused job: active, paused_by cleared, consecutive_failures reset, coalesce arms next_run_at to now",
  decoded10["ok"] == true and
    job10_after.state == "active" and
    job10_after.paused_by == nil and
    job10_after.consecutive_failures == 0 and
    job10_after.next_run_at == base_now + 700_000
)

# ── Vector 11: misfire "skip" paused across missed occurrences resumes onto the next FUTURE grid point ──

{:ok, fail11} = Agent.start_link(fn -> false end)
{state11, clock11, sink11} = new_state_toggle.(base_now, fail11)

{:reply, reply11, state11} =
  create.(state11, :ops, %{schedule: %{every_ms: 300_000}, misfire: "skip"})

job11_id = Jason.decode!(reply11)["job_id"]

{:reply, _pause11, state11} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: job11_id}), state11)

set_clock.(clock11, base_now + 1_000_000)

{:reply, reply11r, state11} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: job11_id}), state11)

decoded11r = Jason.decode!(reply11r)
job11_resumed = Map.fetch!(state11.jobs, job11_id)

{:reply, tick11_reply, _state11} = tick.(state11, :ops)
decoded_tick11 = Jason.decode!(tick11_reply)

check.(
  "misfire skip resumed after 3+ missed periods: next_run_at is the next FUTURE grid point, no catch-up delivery on the following tick",
  decoded11r["ok"] == true and
    job11_resumed.next_run_at == base_now + 1_200_000 and
    job11_resumed.next_run_at > base_now + 1_000_000 and
    decoded_tick11["launched"] == 0 and
    sink_messages.(sink11) == []
)

# ── Vector 12: one-shot exhaustion is still terminal "failed" (0.1.1 semantics preserved) ──

{:ok, fail12} = Agent.start_link(fn -> true end)
{state12, clock12, _sink12} = new_state_toggle.(base_now, fail12)

{:reply, reply12, state12} =
  create.(state12, :ops, %{run_at: base_now + 60_000, max_attempts: 1})

job12_id = Jason.decode!(reply12)["job_id"]

set_clock.(clock12, base_now + 60_000)
{:reply, _tick12, state12} = tick.(state12, :ops)

{:reply, list12_reply, _state12} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "list"}), state12)

list12 = Jason.decode!(list12_reply)["jobs"]

check.(
  # deliver_fn is rigged to always fail here, so the only reachable terminal state
  # is "failed" (never "done") — removal from the active set is sufficient proof.
  "one-shot exhaustion (deliver always fails) is terminal failed: job removed from active set, list shows no non-terminal job",
  not Map.has_key?(state12.jobs, job12_id) and list12 == []
)

# ── Vector 13: success after a failed occurrence resets consecutive_failures to 0 ──

{:ok, fail13} = Agent.start_link(fn -> true end)
{state13, clock13, sink13} = new_state_toggle.(base_now, fail13)

{:reply, reply13, state13} =
  create.(state13, :ops, %{schedule: %{every_ms: 300_000}, max_attempts: 1})

job13_id = Jason.decode!(reply13)["job_id"]

set_clock.(clock13, base_now + 300_000)
{:reply, _tick13a, state13} = tick.(state13, :ops)

job13_mid = Map.fetch!(state13.jobs, job13_id)

Agent.update(fail13, fn _ -> false end)
set_clock.(clock13, base_now + 600_000)
{:reply, _tick13b, state13} = tick.(state13, :ops)

job13_after = Map.fetch!(state13.jobs, job13_id)

check.(
  "success after a failed occurrence resets consecutive_failures to 0",
  job13_mid.consecutive_failures == 1 and
    job13_after.consecutive_failures == 0 and
    job13_after.last_status == "ok" and
    length(sink_messages.(sink13)) == 1
)

# ── Vector 14: retry-grid integrity — fail once then succeed on retry; next_run_at is the ORIGINAL grid point + period ──

{:ok, fail14} = Agent.start_link(fn -> true end)
{state14, clock14, sink14} = new_state_toggle.(base_now, fail14)

{:reply, reply14, state14} =
  create.(state14, :ops, %{
    schedule: %{every_ms: 300_000},
    max_attempts: 2,
    retry_backoff_ms: 60_000
  })

job14_id = Jason.decode!(reply14)["job_id"]

set_clock.(clock14, base_now + 300_000)
{:reply, _tick14a, state14} = tick.(state14, :ops)

job14_mid = Map.fetch!(state14.jobs, job14_id)

Agent.update(fail14, fn _ -> false end)
set_clock.(clock14, base_now + 360_000)
{:reply, _tick14b, state14} = tick.(state14, :ops)

job14_after = Map.fetch!(state14.jobs, job14_id)

check.(
  "retry then success does not drift the grid: next_run_at is the ORIGINAL due + period, not computed from the retry timestamp",
  job14_mid.state == "active" and job14_mid.next_run_at == base_now + 360_000 and
    job14_after.state == "active" and
    job14_after.next_run_at == base_now + 600_000 and
    length(sink_messages.(sink14)) == 1
)

# ── Async harness: like new_state but async?: true with a slow deliver_fn, so a
# vector can act on the object WHILE an occurrence is in flight, then hand the
# task result back via handle_info (the engine's real delivery path).

new_state_async = fn now ->
  {:ok, clock} = Agent.start_link(fn -> now end)
  {:ok, sink} = Agent.start_link(fn -> [] end)

  config = %{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: true,
    now_fn: fn -> Agent.get(clock, & &1) end,
    deliver_fn: fn target, from, json ->
      Process.sleep(50)
      Agent.update(sink, &[{target, from, json} | &1])
      :ok
    end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000
  }

  {:ok, state} = Cron.init(config)
  {state, clock, sink}
end

drain_task = fn state ->
  receive do
    {ref, {:cron_run_result, _, _} = res} ->
      {:noreply, s} = Cron.handle_info({ref, res}, state)
      s
  after
    2_000 -> raise "async vector: no task result arrived"
  end
end

# ── Vector 15 (I1): pause issued while an occurrence is in flight survives the task result ──

{state15, clock15, _sink15} = new_state_async.(base_now)

{:reply, reply15, state15} = create.(state15, :ops, %{schedule: %{every_ms: 300_000}})
job15_id = Jason.decode!(reply15)["job_id"]

set_clock.(clock15, base_now + 300_000)
{:reply, _tick15, state15} = tick.(state15, :ops)

{:reply, pause15, state15} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: job15_id}), state15)

state15 = drain_task.(state15)
job15 = Map.fetch!(state15.jobs, job15_id)

check.(
  "pause during an in-flight occurrence survives the task result: state stays paused, no re-arm, claimed_due/attempts cleared, last_status recorded",
  Jason.decode!(pause15)["ok"] == true and
    job15.state == "paused" and
    job15.next_run_at == nil and
    job15.claimed_due == nil and
    job15.attempts == 0 and
    job15.last_status == "ok"
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON_KINDS: ALL PASS")
else
  IO.puts("\nCRON_KINDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

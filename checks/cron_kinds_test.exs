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

IO.puts(
  "\n══ Cron object: schedule kinds (create validation, claimed due, recurring re-arm) ══\n"
)

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
  msg =
    Map.merge(%{action: "create_job", target: "proactive", message: %{"action" => "run"}}, extra)

  Cron.handle_message(from, Jason.encode!(msg), state)
end

tick = fn state, from ->
  Cron.handle_message(from, Jason.encode!(%{action: "tick"}), state)
end

run_now = fn state, from, id ->
  Cron.handle_message(from, Jason.encode!(%{action: "run_now", job_id: id}), state)
end

defmodule CronKindsEventSink do
  def start do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn _ -> [] end)
    else
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end
  end

  def object(object, type, message, opts) do
    Agent.update(__MODULE__, &[{object, type, message, opts} | &1])
  end

  def events, do: Agent.get(__MODULE__, &Enum.reverse/1)
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

# ── Vector 5b: run_now fires an active recurring job immediately and re-arms
# from that occurrence — advancing the clock before run_now (rather than
# firing at the creation instant) is load-bearing: with the clock unmoved,
# a "re-arm from now" implementation and a regressed "re-arm from the old
# scheduled next_run_at" implementation could land on values close enough
# to mask a regression. Advancing first makes the two diverge so the
# assertion actually pins the anchor. ──

{state5b, clock5b, sink5b} = new_state.(base_now)

{:reply, reply5b, state5b} = create.(state5b, :ops, %{schedule: %{every_ms: 300_000}})
job5b_id = Jason.decode!(reply5b)["job_id"]

set_clock.(clock5b, base_now + 120_000)

{:reply, run5b_reply, state5b} = run_now.(state5b, :ops, "#{job5b_id}")
decoded_run5b = Jason.decode!(run5b_reply)
job5b_after = Map.fetch!(state5b.jobs, job5b_id)

check.(
  "run_now on an ACTIVE every_ms job: trusted call delivers once now and permanently re-phases next_run_at from the run_now occurrence (now + period), not the old scheduled grid point",
  decoded_run5b["ok"] == true and
    decoded_run5b["launched"] == 1 and
    sink_messages.(sink5b) == [{:proactive, :cron, Jason.encode!(%{"action" => "run"})}] and
    job5b_after.state == "active" and
    job5b_after.next_run_at == base_now + 120_000 + 300_000
)

# ── Vector 5b-cron: run_now on a cron-kind job stays on the absolute grid —
# contrast with 5b: every_ms permanently re-phases from the run_now
# occurrence, but a cron expression is anchored to calendar points, so
# firing early doesn't move next_run_at off the grid it already had. ──

{state5bc, clock5bc, sink5bc} = new_state.(base_now)

{:reply, reply5bc, state5bc} = create.(state5bc, :ops, %{schedule: %{cron: "0 * * * *"}})
job5bc_id = Jason.decode!(reply5bc)["job_id"]
job5bc_before = Map.fetch!(state5bc.jobs, job5bc_id)

set_clock.(clock5bc, base_now + 1_800_000)

{:reply, run5bc_reply, state5bc} = run_now.(state5bc, :ops, "#{job5bc_id}")
decoded_run5bc = Jason.decode!(run5bc_reply)
job5bc_after = Map.fetch!(state5bc.jobs, job5bc_id)

check.(
  "run_now on a cron-kind job: firing early delivers once now but leaves next_run_at on the same absolute grid point it already had (no re-phasing)",
  decoded_run5bc["ok"] == true and
    decoded_run5bc["launched"] == 1 and
    sink_messages.(sink5bc) == [{:proactive, :cron, Jason.encode!(%{"action" => "run"})}] and
    job5bc_after.state == "active" and
    job5bc_before.next_run_at == base_now + 3_600_000 and
    job5bc_after.next_run_at == job5bc_before.next_run_at
)

# ── Vector 5c: run_now rejects paused/terminal jobs and silently drops untrusted senders ──

{state5c, clock5c, sink5c} = new_state.(base_now)

{:reply, reply5c, state5c} = create.(state5c, :ops, %{schedule: %{every_ms: 300_000}})
job5c_id = Jason.decode!(reply5c)["job_id"]

{:reply, _pause5c, state5c} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: job5c_id}), state5c)

{:reply, paused5c_reply, state5c} = run_now.(state5c, :ops, job5c_id)

{:reply, _delete5c, state5c} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "delete", job_id: job5c_id}), state5c)

{:reply, terminal5c_reply, state5c} = run_now.(state5c, :ops, job5c_id)

{:reply, reply5c2, state5c} = create.(state5c, :ops, %{schedule: %{every_ms: 300_000}})
job5c2_id = Jason.decode!(reply5c2)["job_id"]

{:noreply, state5c_after_untrusted} = run_now.(state5c, :agent_0, job5c2_id)
set_clock.(clock5c, base_now + 1_000)

check.(
  "run_now rejects paused/terminal jobs and untrusted run_now is a silent no-op",
  Jason.decode!(paused5c_reply)["ok"] == false and
    Jason.decode!(paused5c_reply)["state"] == "paused" and
    Jason.decode!(terminal5c_reply)["ok"] == false and
    Jason.decode!(terminal5c_reply)["error"] == "job not found" and
    state5c_after_untrusted == state5c and
    sink_messages.(sink5c) == []
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

# ── Vector 7b (W2 M7): timer tick path is noreply while message tick still replies ──

{state7b, clock7b, sink7b} = new_state.(base_now)

{:reply, reply7b, state7b} = create.(state7b, :ops, %{run_at: base_now + 60_000})
job7b_id = Jason.decode!(reply7b)["job_id"]

set_clock.(clock7b, base_now + 60_000)
{:noreply, state7b} = Cron.handle_info(:tick, state7b)

check.(
  "handle_info(:tick) returns noreply and still runs due jobs through the shared tick core",
  not Map.has_key?(state7b.jobs, job7b_id) and
    sink_messages.(sink7b) == [{:proactive, :cron, Jason.encode!(%{"action" => "run"})}]
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

# ── Vector 9b (W2): run failures and breaker pauses emit events through events_mod ──

CronKindsEventSink.start()
{:ok, clock9b} = Agent.start_link(fn -> base_now end)

{:ok, state9b} =
  Cron.init(%{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(clock9b, & &1) end,
    deliver_fn: fn _target, _from, _json -> {:error, "boom"} end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000,
    max_attempts: 1,
    breaker_threshold: 1,
    events_mod: CronKindsEventSink
  })

{:reply, reply9b, state9b} =
  create.(state9b, :ops, %{schedule: %{every_ms: 300_000}, name: "eventful"})

job9b_id = Jason.decode!(reply9b)["job_id"]

set_clock.(clock9b, base_now + 300_000)
{:reply, _tick9b, state9b} = tick.(state9b, :ops)

job9b_after = Map.fetch!(state9b.jobs, job9b_id)
events9b = CronKindsEventSink.events()

failure9b =
  Enum.find(events9b, fn {_object, type, _message, _opts} -> type == :job_run_failed end)

breaker9b =
  Enum.find(events9b, fn {_object, type, _message, _opts} -> type == :job_breaker_paused end)

check.(
  "run failure and breaker pause emit events with job name and consecutive_failures metadata",
  job9b_after.state == "paused" and
    match?({:cron, :job_run_failed, _, _}, failure9b) and
    match?({:cron, :job_breaker_paused, _, _}, breaker9b) and
    get_in(elem(failure9b, 3), [:metadata, :name]) == "eventful" and
    get_in(elem(breaker9b, 3), [:metadata, :consecutive_failures]) == 1
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

# ── Vector 16 (I2): resume on a RUNNING job is rejected — no second concurrent launch ──

{state16, clock16, sink16} = new_state_async.(base_now)

{:reply, reply16, state16} = create.(state16, :ops, %{schedule: %{every_ms: 300_000}})
job16_id = Jason.decode!(reply16)["job_id"]

set_clock.(clock16, base_now + 300_000)
{:reply, _tick16a, state16} = tick.(state16, :ops)
tasks16_in_flight = map_size(state16.tasks)

{:reply, resume16, state16} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: job16_id}), state16)

decoded_resume16 = Jason.decode!(resume16)

{:reply, tick16b, state16} = tick.(state16, :ops)
decoded_tick16b = Jason.decode!(tick16b)

state16 = drain_task.(state16)
job16 = Map.fetch!(state16.jobs, job16_id)

check.(
  "resume on a RUNNING job: rejected ok:false \"job not paused\", still one task in flight, no second launch, job re-arms normally after the result",
  tasks16_in_flight == 1 and
    decoded_resume16["ok"] == false and
    decoded_resume16["error"] == "job not paused" and
    decoded_resume16["state"] == "running" and
    decoded_tick16b["launched"] == 0 and
    length(sink_messages.(sink16)) == 1 and
    job16.state == "active" and
    job16.next_run_at == base_now + 600_000
)

# ── Vector 16b (I2): resume on an ACTIVE (never paused) job is a rejected no-op too ──

{state16b, _clock16b, _sink16b} = new_state.(base_now)

{:reply, reply16b, state16b} = create.(state16b, :ops, %{schedule: %{every_ms: 300_000}})
job16b_id = Jason.decode!(reply16b)["job_id"]

{:reply, resume16b, state16b} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: job16b_id}), state16b)

decoded_resume16b = Jason.decode!(resume16b)
job16b = Map.fetch!(state16b.jobs, job16b_id)

check.(
  "resume on an ACTIVE job: rejected ok:false \"job not paused\", next_run_at untouched",
  decoded_resume16b["ok"] == false and
    decoded_resume16b["error"] == "job not paused" and
    decoded_resume16b["state"] == "active" and
    job16b.next_run_at == base_now + 300_000
)

# ── Vector 16c (W2 Audit M1): saturation re-arms the timer with a floor, not 0ms ──

{:ok, clock16c} = Agent.start_link(fn -> base_now end)
{:ok, sink16c} = Agent.start_link(fn -> [] end)

{:ok, state16c} =
  Cron.init(%{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: true,
    tick_ms: 10_000,
    async?: true,
    max_concurrency: 1,
    now_fn: fn -> Agent.get(clock16c, & &1) end,
    deliver_fn: fn target, from, json ->
      Process.sleep(100)
      Agent.update(sink16c, &[{target, from, json} | &1])
      :ok
    end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000
  })

{:reply, _reply16c_a, state16c} = create.(state16c, :ops, %{run_at: base_now + 60_000})
{:reply, _reply16c_b, state16c} = create.(state16c, :ops, %{run_at: base_now + 60_000})

set_clock.(clock16c, base_now + 60_000)
{:reply, tick16c_a, state16c} = tick.(state16c, :ops)
{:reply, tick16c_b, state16c} = tick.(state16c, :ops)
timer16c_delay = Process.read_timer(state16c.timer_ref)

state16c = drain_task.(state16c)

check.(
  "when all task slots are busy, a deferred due job re-arms at tick_ms instead of busy-spinning at 0ms",
  Jason.decode!(tick16c_a)["launched"] == 1 and
    Jason.decode!(tick16c_b)["launched"] == 0 and
    Jason.decode!(tick16c_b)["deferred"] == 1 and
    is_integer(timer16c_delay) and
    timer16c_delay > 100 and
    map_size(state16c.tasks) == 0
)

# ── Vector 16d (W2 Audit M3): linked task exits are trapped and handled through :DOWN ──

{:ok, clock16d} = Agent.start_link(fn -> base_now end)

{:ok, state16d} =
  Cron.init(%{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: true,
    now_fn: fn -> Agent.get(clock16d, & &1) end,
    deliver_fn: fn _target, _from, _json -> exit(:boom) end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000,
    retry_backoff_ms: 1_000
  })

{:reply, reply16d, state16d} = create.(state16d, :ops, %{run_at: base_now + 60_000})
job16d_id = Jason.decode!(reply16d)["job_id"]

set_clock.(clock16d, base_now + 60_000)
{:reply, _tick16d, state16d} = tick.(state16d, :ops)

down16d =
  receive do
    {:DOWN, _ref, :process, _pid, _reason} = down ->
      down

    {:EXIT, _pid, _reason} ->
      receive do
        {:DOWN, _ref, :process, _pid, _reason} = down -> down
      after
        2_000 -> raise "async down vector: no :DOWN after :EXIT"
      end
  after
    2_000 -> raise "async down vector: no task down arrived"
  end

{:noreply, state16d} = Cron.handle_info(down16d, state16d)
job16d = Map.fetch!(state16d.jobs, job16d_id)

check.(
  "Task.async exits no longer kill the scheduler process; :DOWN records a retryable run failure",
  job16d.state == "active" and
    job16d.last_status == "error" and
    String.contains?(job16d.last_error || "", "task down")
)

# ── Vector 16e (F2): run_now at max_concurrency saturation is rejected, not launched ──
# run_now is an immediate-fire request with no due-queue to defer onto, so at
# saturation it must reject ({ok:false, "at max concurrency"}) with the task
# count unchanged — it may never push concurrency past the configured cap the
# way the pre-fix unconditional launch did.

{:ok, clock16e} = Agent.start_link(fn -> base_now end)
{:ok, sink16e} = Agent.start_link(fn -> [] end)

{:ok, state16e} =
  Cron.init(%{
    swarm_name: "kinds-test",
    name: :cron,
    auto_tick: false,
    async?: true,
    max_concurrency: 1,
    now_fn: fn -> Agent.get(clock16e, & &1) end,
    deliver_fn: fn target, from, json ->
      Process.sleep(100)
      Agent.update(sink16e, &[{target, from, json} | &1])
      :ok
    end,
    trusted_sources: [:ops],
    allowed_targets: %{proactive: ["run"]},
    min_period_ms: 60_000
  })

{:reply, reply16e_a, state16e} = create.(state16e, :ops, %{run_at: base_now + 60_000})
{:reply, reply16e_b, state16e} = create.(state16e, :ops, %{run_at: base_now + 60_000})
job16e_a = Jason.decode!(reply16e_a)["job_id"]
job16e_b = Jason.decode!(reply16e_b)["job_id"]

{:reply, run16e_a, state16e} = run_now.(state16e, :ops, job16e_a)
tasks16e_saturated = map_size(state16e.tasks)

{:reply, run16e_b, state16e} = run_now.(state16e, :ops, job16e_b)
decoded_run16e_b = Jason.decode!(run16e_b)
tasks16e_after = map_size(state16e.tasks)
job16e_b_after = Map.fetch!(state16e.jobs, job16e_b)

state16e = drain_task.(state16e)

check.(
  "run_now at max_concurrency saturation: rejected ok:false \"at max concurrency\", task count unchanged, the second job untouched",
  Jason.decode!(run16e_a)["ok"] == true and
    tasks16e_saturated == 1 and
    decoded_run16e_b["ok"] == false and
    decoded_run16e_b["error"] == "at max concurrency" and
    tasks16e_after == 1 and
    job16e_b_after.state == "active" and
    job16e_b_after.next_run_at == base_now + 60_000 and
    map_size(state16e.tasks) == 0
)

# ── Vector 17 (I3): poisoned stored cron expr must not crash completion — terminal, reason kept ──
# A corrupt persisted row is the real ingress (create validates exprs); poisoning
# the in-memory schedule after create reproduces it without a store harness.

{state17, clock17, _sink17} = new_state.(base_now)

{:reply, reply17, state17} = create.(state17, :ops, %{schedule: %{cron: "0 * * * *"}})
job17_id = Jason.decode!(reply17)["job_id"]

poisoned17 = %{
  Map.fetch!(state17.jobs, job17_id)
  | schedule: %{"kind" => "cron", "expr" => "garbage"}
}

state17 = %{state17 | jobs: Map.put(state17.jobs, job17_id, poisoned17)}
set_clock.(clock17, base_now + 3_600_000)

result17 =
  try do
    {:reply, _r, s} = tick.(state17, :ops)
    {:ok, s}
  rescue
    e -> {:raise, e.__struct__}
  end

check.(
  "poisoned cron expr on a due job: tick completes without raising, job goes terminal (removed from active set)",
  match?({:ok, _}, result17) and
    case result17 do
      {:ok, s} -> not Map.has_key?(s.jobs, job17_id)
      _ -> false
    end
)

# ── Vector 18 (I6): crafted non-scalar string fields are rejected ok:false, never raise ──
# Map/list values in to_string'd fields used to raise Protocol.UndefinedError;
# the engine cast path has no rescue, so that was an ObjectServer crash.

{state18a, _clock18a, _sink18a} = new_state.(base_now)

bad18 = [
  {"map target", %{target: %{"a" => 1}}},
  {"list target", %{target: ["proactive"]}},
  {"map message.action", %{message: %{"action" => %{"a" => 1}}}},
  {"list message (non-object)", %{message: ["run"]}},
  {"map name", %{name: %{"a" => 1}}},
  {"map dedupe_key", %{dedupe_key: %{"a" => 1}}},
  {"list misfire", %{misfire: ["skip"]}}
]

results18 =
  for {label, extra} <- bad18 do
    outcome =
      try do
        case create.(state18a, :ops, Map.merge(%{schedule: %{every_ms: 300_000}}, extra)) do
          {:reply, r, _s} -> Jason.decode!(r)["ok"]
          {:noreply, _s} -> :noreply
        end
      rescue
        e -> {:raise, e.__struct__}
      end

    {label, outcome}
  end

check.(
  "crafted non-scalar create_job fields (target/message.action/name/dedupe_key/misfire) all reject ok:false without raising",
  Enum.all?(results18, fn {_label, outcome} -> outcome == false end)
)

# valid create still works after validation was added (no over-rejection)
{:reply, reply18ok, _state18a} =
  create.(state18a, :ops, %{
    schedule: %{every_ms: 300_000},
    name: "fine",
    dedupe_key: "dk18",
    misfire: "skip"
  })

check.(
  "valid scalar fields still accepted after input validation",
  Jason.decode!(reply18ok)["ok"] == true
)

# ── Vector 18b (F1a): non-boolean once is rejected, never coerced ──
# "once": "true" (string) used to slip past validation and silently degrade
# to the weaker live-only dedupe; once must be nil or a boolean —
# once: false is accepted (treated as absent).

{:reply, reply18b_bad, _state18b} =
  create.(state18a, :ops, %{schedule: %{every_ms: 300_000}, once: "true", dedupe_key: "dk18b"})

decoded18b_bad = Jason.decode!(reply18b_bad)

{:reply, reply18b_false, _state18b} =
  create.(state18a, :ops, %{schedule: %{every_ms: 300_000}, once: false, dedupe_key: "dk18c"})

check.(
  "\"once\": \"true\" (string) rejects ok:false \"once must be a boolean\"; once: false is accepted (treated as absent)",
  decoded18b_bad["ok"] == false and
    decoded18b_bad["error"] == "once must be a boolean" and
    Jason.decode!(reply18b_false)["ok"] == true
)

# ── Vector 19 (W2 M2): origin is free-form scalar provenance and context_from is gone ──

{state19, _clock19, _sink19} = new_state.(base_now)

{:reply, reply19, state19} =
  create.(state19, :ops, %{
    schedule: %{every_ms: 300_000},
    origin: %{
      "campaign_id" => "c1",
      "score" => 7,
      "enabled" => true,
      "nested" => %{"drop" => true}
    },
    context_from: [1, 2, 3]
  })

job19 = Map.fetch!(state19.jobs, Jason.decode!(reply19)["job_id"])

check.(
  "origin keeps arbitrary scalar keys, drops non-scalars, and context_from is no longer persisted",
  job19.origin == %{
    "campaign_id" => "c1",
    "score" => 7,
    "enabled" => true,
    "source" => "ops"
  } and
    not Map.has_key?(job19, :context_from)
)

# ── Vector 20 (W2 Arch M-6): string allowed_targets fail with a descriptive boot abort ──

allowed_target_error20 =
  try do
    Cron.init(%{
      auto_tick: false,
      allowed_targets: %{"cron_unknown_target_for_w2" => ["run"]}
    })

    nil
  rescue
    e in ArgumentError -> Exception.message(e)
  end

check.(
  "unknown string allowed_targets raise a descriptive ArgumentError instead of raw to_existing_atom failure",
  allowed_target_error20 == "cron allowed_targets: unknown object :cron_unknown_target_for_w2"
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON_KINDS: ALL PASS")
else
  IO.puts("\nCRON_KINDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

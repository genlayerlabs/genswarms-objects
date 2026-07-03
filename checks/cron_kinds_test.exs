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

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON_KINDS: ALL PASS")
else
  IO.puts("\nCRON_KINDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

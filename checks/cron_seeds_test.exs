# Cron object: declarative seed_jobs (config-driven upsert at boot, raise-on-
# invalid), the 0.1.1 persisted-job load upgrade (missing kind-era fields
# backfilled so old rows don't KeyError at claim), and list row shape
# (kind/paused_by).
#
#   mix run checks/cron_seeds_test.exs

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

IO.puts("\n══ Cron object: seed_jobs, 0.1.1 load upgrade, list shape ══\n")

ms = fn iso ->
  {:ok, dt, _} = DateTime.from_iso8601(iso)
  DateTime.to_unix(dt, :millisecond)
end

base_now = ms.("2026-07-06T14:00:00Z")

defmodule FakeStore do
  def start(rows) do
    if Process.whereis(__MODULE__),
      do: Agent.update(__MODULE__, fn _ -> rows end),
      else: Agent.start_link(fn -> rows end, name: __MODULE__)
  end

  def load_cron_jobs(_states), do: Agent.get(__MODULE__, & &1)
  def max_cron_job_id, do: Agent.get(__MODULE__, &Enum.reduce(&1, 0, fn r, m -> max(r.id, m) end))

  def save_cron_job(job) do
    Agent.update(__MODULE__, fn rows ->
      [%{id: job.id, state: job.state, data: json_roundtrip(job)} | Enum.reject(rows, &(&1.id == job.id))]
    end)
  end

  def save_cron_run(_job, _result), do: :ok
  defp json_roundtrip(job), do: job |> Jason.encode!() |> Jason.decode!()
end

init_state = fn now, seeds, extra ->
  {:ok, clock} = Agent.start_link(fn -> now end)
  {:ok, sink} = Agent.start_link(fn -> [] end)

  config =
    Map.merge(
      %{
        swarm_name: "seeds-test",
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
        min_period_ms: 60_000,
        seed_jobs: seeds
      },
      extra
    )

  {:ok, state} = Cron.init(config)
  {state, clock, sink}
end

list = fn state, from ->
  {:reply, reply, _state} = Cron.handle_message(from, Jason.encode!(%{action: "list"}), state)
  Jason.decode!(reply)["jobs"]
end

create = fn state, from, extra ->
  msg = Map.merge(%{action: "create_job", target: "proactive", message: %{"action" => "run"}}, extra)
  Cron.handle_message(from, Jason.encode!(msg), state)
end

tick = fn state, from ->
  Cron.handle_message(from, Jason.encode!(%{action: "tick"}), state)
end

# ── Vector 1: init with two seeds (every_ms + cron), targets allowlisted ──

FakeStore.start([])

seeds_a = [
  %{name: "digest", dedupe_key: "seed:digest", schedule: %{every_ms: 300_000}, target: "proactive", message: %{"action" => "run"}},
  %{name: "hourly", dedupe_key: "seed:hourly", schedule: %{cron: "0 * * * *"}, target: "proactive", message: %{"action" => "run"}}
]

{state1, _clock1, _sink1} = init_state.(base_now, seeds_a, %{store_mod: FakeStore})

jobs1 = list.(state1, :ops)
job1_digest = Enum.find(Map.values(state1.jobs), &(&1.dedupe_key == "seed:digest"))
job1_hourly = Enum.find(Map.values(state1.jobs), &(&1.dedupe_key == "seed:hourly"))

check.(
  "init with two seeds: both active, correct next_run_at, created_by == seed",
  length(jobs1) == 2 and
    Enum.all?(jobs1, &(&1["state"] == "active")) and
    job1_digest != nil and job1_hourly != nil and
    job1_digest.next_run_at == base_now + 300_000 and
    job1_hourly.next_run_at == base_now + 3_600_000 and
    job1_digest.created_by == "seed" and job1_hourly.created_by == "seed"
)

# ── Vector 2: re-init with identical seeds against the persisted store → no dupes, next_run_at preserved ──

now2 = base_now + 120_000
{state2, _clock2, _sink2} = init_state.(now2, seeds_a, %{store_mod: FakeStore})

jobs2 = list.(state2, :ops)
job2_digest = Enum.find(Map.values(state2.jobs), &(&1.dedupe_key == "seed:digest"))
job2_hourly = Enum.find(Map.values(state2.jobs), &(&1.dedupe_key == "seed:hourly"))

check.(
  "re-init with identical seeds: no duplicates, next_run_at PRESERVED (not reset to now2 + period)",
  length(jobs2) == 2 and
    job2_digest.next_run_at == base_now + 300_000 and
    job2_hourly.next_run_at == base_now + 3_600_000 and
    job2_digest.id == job1_digest.id and job2_hourly.id == job1_hourly.id
)

# ── Vector 3: re-init with one seed's every_ms changed → that job's schedule + next_run_at update; the other untouched ──

now3 = base_now + 200_000

seeds_b = [
  %{name: "digest", dedupe_key: "seed:digest", schedule: %{every_ms: 600_000}, target: "proactive", message: %{"action" => "run"}},
  %{name: "hourly", dedupe_key: "seed:hourly", schedule: %{cron: "0 * * * *"}, target: "proactive", message: %{"action" => "run"}}
]

{state3, _clock3, _sink3} = init_state.(now3, seeds_b, %{store_mod: FakeStore})

job3_digest = Enum.find(Map.values(state3.jobs), &(&1.dedupe_key == "seed:digest"))
job3_hourly = Enum.find(Map.values(state3.jobs), &(&1.dedupe_key == "seed:hourly"))

check.(
  "re-init with one seed's every_ms changed: schedule + next_run_at recomputed for that job; the other job's next_run_at untouched",
  job3_digest.schedule == %{"kind" => "every_ms", "every_ms" => 600_000} and
    job3_digest.next_run_at == now3 + 600_000 and
    job3_hourly.next_run_at == base_now + 3_600_000
)

# ── Vector 4: invalid seeds raise, message contains the seed name ──

FakeStore.start([])

bad_target_seeds = [
  %{name: "bad-target-seed", dedupe_key: "seed:bad-target", schedule: %{every_ms: 300_000}, target: "nope", message: %{"action" => "run"}}
]

bad_target_error =
  try do
    init_state.(base_now, bad_target_seeds, %{store_mod: FakeStore})
    nil
  rescue
    e in ArgumentError -> Exception.message(e)
  end

FakeStore.start([])

missing_dedupe_seeds = [
  %{name: "missing-dedupe-seed", schedule: %{every_ms: 300_000}, target: "proactive", message: %{"action" => "run"}}
]

missing_dedupe_error =
  try do
    init_state.(base_now, missing_dedupe_seeds, %{store_mod: FakeStore})
    nil
  rescue
    e in ArgumentError -> Exception.message(e)
  end

FakeStore.start([])

unsatisfiable_seeds = [
  %{name: "unsatisfiable-seed", dedupe_key: "seed:unsatisfiable", schedule: %{cron: "0 0 30 2 *"}, target: "proactive", message: %{"action" => "run"}}
]

unsatisfiable_error =
  try do
    init_state.(base_now, unsatisfiable_seeds, %{store_mod: FakeStore})
    nil
  rescue
    e in ArgumentError -> Exception.message(e)
  end

check.(
  "invalid seeds raise ArgumentError naming the seed: bad target, missing dedupe_key, unsatisfiable cron",
  is_binary(bad_target_error) and String.contains?(bad_target_error, "bad-target-seed") and
    is_binary(missing_dedupe_error) and String.contains?(missing_dedupe_error, "missing-dedupe-seed") and
    is_binary(unsatisfiable_error) and String.contains?(unsatisfiable_error, "unsatisfiable-seed")
)

# ── Vector 5: runtime create_job with a seed's dedupe_key → deduped, no second job ──

FakeStore.start([])

seeds_c = [
  %{name: "digest", dedupe_key: "seed:digest", schedule: %{every_ms: 300_000}, target: "proactive", message: %{"action" => "run"}}
]

{state5, _clock5, _sink5} = init_state.(base_now, seeds_c, %{store_mod: FakeStore})
seed5_job = Enum.find(Map.values(state5.jobs), &(&1.dedupe_key == "seed:digest"))

{:reply, reply5, state5} = create.(state5, :ops, %{dedupe_key: "seed:digest", schedule: %{every_ms: 300_000}})
decoded5 = Jason.decode!(reply5)

check.(
  "runtime create_job with a seed's dedupe_key: deduped true, no second job created",
  decoded5["ok"] == true and decoded5["deduped"] == true and
    decoded5["job_id"] == seed5_job.id and
    map_size(state5.jobs) == 1
)

# ── Vector 6: 0.1.1-shaped persisted row (no misfire/consecutive_failures/etc) loads, upgrades, fires once, done ──

legacy_future = base_now + 60_000

legacy_row = %{
  id: 99,
  state: "active",
  data: %{
    "id" => 99,
    "name" => "legacy job",
    "schedule" => %{"run_at_ms" => legacy_future},
    "next_run_at" => legacy_future,
    "last_run_at" => nil,
    "last_status" => nil,
    "last_error" => nil,
    "state" => "active",
    "attempts" => 0,
    "max_attempts" => 3,
    "retry_backoff_ms" => 60_000,
    "origin" => %{"source" => "legacy"},
    "payload" => %{"target" => "proactive", "message" => %{"action" => "run"}},
    "context_from" => [],
    "dedupe_key" => nil,
    "created_by" => "legacy",
    "created_at" => base_now - 1_000,
    "updated_at" => base_now - 1_000
  }
}

FakeStore.start([legacy_row])

{state6, clock6, sink6} = init_state.(base_now, [], %{store_mod: FakeStore})
legacy_job_loaded = Map.get(state6.jobs, 99)

Agent.update(clock6, fn _ -> legacy_future end)
{:reply, _tick6, state6} = tick.(state6, :ops)

check.(
  "0.1.1-shaped row loads as kind run_at, misfire coalesce, fires once, goes done",
  legacy_job_loaded.schedule == %{"kind" => "run_at", "run_at_ms" => legacy_future} and
    legacy_job_loaded.misfire == "coalesce" and
    legacy_job_loaded.consecutive_failures == 0 and
    legacy_job_loaded.paused_by == nil and
    legacy_job_loaded.breaker_threshold == 5 and
    legacy_job_loaded.claimed_due == nil and
    not Map.has_key?(state6.jobs, 99) and
    length(Agent.get(sink6, & &1)) == 1
)

# ── Vector 7: list rows carry "kind" and "paused_by" keys ──

FakeStore.start([])

{state7, _clock7, _sink7} = init_state.(base_now, [], %{store_mod: FakeStore})
{:reply, _create7, state7} = create.(state7, :ops, %{run_at: base_now + 60_000})
jobs7 = list.(state7, :ops)

check.(
  "list rows carry kind and paused_by keys",
  match?([%{"kind" => "run_at", "paused_by" => nil}], jobs7)
)

# ── Vector 8 (I3): poisoned store row (running + bad cron expr + misfire skip) must not crash boot ──
# recover_running_job's skip branch hits Schedule.next_after on the corrupt expr;
# a {:error, _} there used to CaseClauseError straight out of init (boot crash-loop).

bad_expr_row = %{
  id: 50,
  state: "running",
  data: %{
    "id" => 50,
    "name" => "poisoned",
    "state" => "running",
    "schedule" => %{"kind" => "cron", "expr" => "garbage"},
    "misfire" => "skip",
    "next_run_at" => nil,
    "last_run_at" => base_now - 1_000,
    "payload" => %{"target" => "proactive", "message" => %{"action" => "run"}},
    "created_at" => base_now - 10_000,
    "updated_at" => base_now - 1_000
  }
}

FakeStore.start([bad_expr_row])

boot8 =
  try do
    {s, _c, _snk} = init_state.(base_now, [], %{store_mod: FakeStore})
    {:ok, s}
  rescue
    e -> {:raise, e.__struct__}
  end

tick8 =
  case boot8 do
    {:ok, s} ->
      try do
        {:reply, _r, s2} = tick.(s, :ops)
        {:ok, s2}
      rescue
        e -> {:raise, e.__struct__}
      end

    other ->
      other
  end

row8 = Enum.find(FakeStore.load_cron_jobs(["done", "failed"]), &(&1.id == 50))

check.(
  "poisoned running+skip row: boot recovers without raising, tick completes, job lands terminal with last_error carrying the schedule reason",
  match?({:ok, _}, boot8) and
    match?({:ok, _}, tick8) and
    (case tick8 do
       {:ok, s2} -> not Map.has_key?(s2.jobs, 50)
       _ -> false
     end) and
    row8 != nil and
    String.contains?(row8.data["last_error"] || "", "cron")
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON_SEEDS: ALL PASS")
else
  IO.puts("\nCRON_SEEDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

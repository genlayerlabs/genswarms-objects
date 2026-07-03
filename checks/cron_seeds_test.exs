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

  # Honors the states filter like the real store seam: load_cron_jobs(states)
  # returns only rows whose state is in the list.
  def load_cron_jobs(states),
    do: Agent.get(__MODULE__, & &1) |> Enum.filter(&(&1.state in states))

  def max_cron_job_id, do: Agent.get(__MODULE__, &Enum.reduce(&1, 0, fn r, m -> max(r.id, m) end))

  def save_cron_job(job) do
    Agent.update(__MODULE__, fn rows ->
      [
        %{id: job.id, state: job.state, data: json_roundtrip(job)}
        | Enum.reject(rows, &(&1.id == job.id))
      ]
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
  msg =
    Map.merge(%{action: "create_job", target: "proactive", message: %{"action" => "run"}}, extra)

  Cron.handle_message(from, Jason.encode!(msg), state)
end

tick = fn state, from ->
  Cron.handle_message(from, Jason.encode!(%{action: "tick"}), state)
end

# ── Vector 1: init with two seeds (every_ms + cron), targets allowlisted ──

FakeStore.start([])

seeds_a = [
  %{
    name: "digest",
    dedupe_key: "seed:digest",
    schedule: %{every_ms: 300_000},
    target: "proactive",
    message: %{"action" => "run"}
  },
  %{
    name: "hourly",
    dedupe_key: "seed:hourly",
    schedule: %{cron: "0 * * * *"},
    target: "proactive",
    message: %{"action" => "run"}
  }
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
  %{
    name: "digest",
    dedupe_key: "seed:digest",
    schedule: %{every_ms: 600_000},
    target: "proactive",
    message: %{"action" => "run"}
  },
  %{
    name: "hourly",
    dedupe_key: "seed:hourly",
    schedule: %{cron: "0 * * * *"},
    target: "proactive",
    message: %{"action" => "run"}
  }
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
  %{
    name: "bad-target-seed",
    dedupe_key: "seed:bad-target",
    schedule: %{every_ms: 300_000},
    target: "nope",
    message: %{"action" => "run"}
  }
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
  %{
    name: "missing-dedupe-seed",
    schedule: %{every_ms: 300_000},
    target: "proactive",
    message: %{"action" => "run"}
  }
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
  %{
    name: "unsatisfiable-seed",
    dedupe_key: "seed:unsatisfiable",
    schedule: %{cron: "0 0 30 2 *"},
    target: "proactive",
    message: %{"action" => "run"}
  }
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
    is_binary(missing_dedupe_error) and
    String.contains?(missing_dedupe_error, "missing-dedupe-seed") and
    is_binary(unsatisfiable_error) and String.contains?(unsatisfiable_error, "unsatisfiable-seed")
)

# ── Vector 5: runtime create_job with a seed's dedupe_key → deduped, no second job ──

FakeStore.start([])

seeds_c = [
  %{
    name: "digest",
    dedupe_key: "seed:digest",
    schedule: %{every_ms: 300_000},
    target: "proactive",
    message: %{"action" => "run"}
  }
]

{state5, _clock5, _sink5} = init_state.(base_now, seeds_c, %{store_mod: FakeStore})
seed5_job = Enum.find(Map.values(state5.jobs), &(&1.dedupe_key == "seed:digest"))

{:reply, reply5, state5} =
  create.(state5, :ops, %{dedupe_key: "seed:digest", schedule: %{every_ms: 300_000}})

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

{:reply, _create7, state7} =
  create.(state7, :ops, %{run_at: base_now + 60_000, dedupe_key: "list:shape"})

jobs7 = list.(state7, :ops)

check.(
  "list rows carry kind, paused_by, schedule, and dedupe_key keys",
  match?(
    [
      %{
        "kind" => "run_at",
        "paused_by" => nil,
        "schedule" => %{"kind" => "run_at", "run_at_ms" => _},
        "dedupe_key" => "list:shape"
      }
    ],
    jobs7
  )
)

# ── Vector 8 (I3): poisoned store row (running + bad cron expr + misfire skip) must not crash boot ──
# Job.recover's skip branch hits Schedule.next_after on the corrupt expr;
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
    case tick8 do
      {:ok, s2} -> not Map.has_key?(s2.jobs, 50)
      _ -> false
    end and
    row8 != nil and
    String.contains?(row8.data["last_error"] || "", "cron")
)

# ── Vector 9 (I4): a one-shot seed that already ran to a terminal row is a no-op on reboot ──
# The terminal row isn't loaded (@load_states), so the in-memory dedupe can't see
# it — the seed upsert must consult the STORE for terminal rows by dedupe_key.

FakeStore.start([])

oneshot_seeds = [
  %{
    name: "once",
    dedupe_key: "seed:once",
    schedule: %{"run_at" => base_now - 3_600_000},
    target: "proactive",
    message: %{"action" => "run"}
  }
]

{state9a, _clock9a, sink9a} = init_state.(base_now, oneshot_seeds, %{store_mod: FakeStore})
{:reply, _tick9a, _state9a} = tick.(state9a, :ops)
deliveries9_boot1 = length(Agent.get(sink9a, & &1))
rows9_boot1 = Agent.get(FakeStore, & &1)

{state9b, _clock9b, sink9b} =
  init_state.(base_now + 60_000, oneshot_seeds, %{store_mod: FakeStore})

{:reply, _tick9b, _state9b} = tick.(state9b, :ops)
deliveries9_boot2 = length(Agent.get(sink9b, & &1))
rows9_boot2 = Agent.get(FakeStore, & &1)

check.(
  "one-shot past seed fires exactly once across reboots: boot1 delivers 1 and lands one done row; boot2 delivers 0, creates no job and no duplicate row",
  deliveries9_boot1 == 1 and
    length(rows9_boot1) == 1 and hd(rows9_boot1).state == "done" and
    deliveries9_boot2 == 0 and
    map_size(state9b.jobs) == 0 and
    length(rows9_boot2) == 1
)

# ── Vector 9b (W2 I4): runtime create_job once=true consults terminal rows by dedupe_key ──

FakeStore.start([])

{state9c, _clock9c, sink9c} = init_state.(base_now, [], %{store_mod: FakeStore})

{:reply, reply9c_create, state9c} =
  create.(state9c, :ops, %{
    run_at: base_now,
    dedupe_key: "runtime:once",
    once: true
  })

job9c_id = Jason.decode!(reply9c_create)["job_id"]
{:reply, _tick9c, state9c} = tick.(state9c, :ops)

{:reply, reply9c_once, state9c} =
  create.(state9c, :ops, %{
    run_at: base_now - 120_000,
    dedupe_key: "runtime:once",
    once: true
  })

decoded9c_once = Jason.decode!(reply9c_once)

{:reply, reply9c_default, state9c_default} =
  create.(state9c, :ops, %{
    run_at: base_now + 60_000,
    dedupe_key: "runtime:once"
  })

decoded9c_default = Jason.decode!(reply9c_default)

check.(
  "runtime once=true dedupes against terminal rows; once absent keeps the existing live-only behavior",
  length(Agent.get(sink9c, & &1)) == 1 and
    decoded9c_once["ok"] == true and
    decoded9c_once["deduped"] == true and
    decoded9c_once["job_id"] == job9c_id and
    decoded9c_once["state"] == "done" and
    map_size(state9c.jobs) == 0 and
    decoded9c_default["ok"] == true and
    decoded9c_default["deduped"] != true and
    map_size(state9c_default.jobs) == 1
)

# ── Vector 9c (F3): a once-dedupe hit no longer skips create validation ──
# Schedule normalization/floor and target/payload validation run BEFORE the
# terminal-dedupe lookup — a garbage schedule with a terminal dedupe_key must
# reject ok:false, never short-circuit to {ok:true, deduped:true}. Only the
# past-guard stays skipped on a dedupe hit: a once:true re-create with a
# now-past run_at still no-ops deduped (load-bearing for callers that re-arm
# the same one-shot on every poll).

FakeStore.start([])

{state9d, _clock9d, _sink9d} = init_state.(base_now, [], %{store_mod: FakeStore})

{:reply, reply9d_create, state9d} =
  create.(state9d, :ops, %{run_at: base_now, dedupe_key: "runtime:once-f3", once: true})

job9d_id = Jason.decode!(reply9d_create)["job_id"]
{:reply, _tick9d, state9d} = tick.(state9d, :ops)

{:reply, reply9d_bad, state9d} =
  create.(state9d, :ops, %{
    schedule: %{cron: "garbage"},
    dedupe_key: "runtime:once-f3",
    once: true
  })

decoded9d_bad = Jason.decode!(reply9d_bad)

{:reply, reply9d_past, state9d} =
  create.(state9d, :ops, %{
    run_at: base_now - 10 * 60_000,
    dedupe_key: "runtime:once-f3",
    once: true
  })

decoded9d_past = Jason.decode!(reply9d_past)

check.(
  "once:true + terminal dedupe_key: an INVALID schedule is rejected ok:false (not deduped); a valid-but-past run_at still no-ops {ok:true, deduped:true}",
  decoded9d_bad["ok"] == false and
    decoded9d_bad["deduped"] != true and
    decoded9d_past["ok"] == true and
    decoded9d_past["deduped"] == true and
    decoded9d_past["job_id"] == job9d_id and
    map_size(state9d.jobs) == 0
)

# ── Vector 10 (I5): misfire "skip" honored on ORDINARY downtime (active row loaded overdue) ──
# Two identical active every_ms jobs missed 5 occurrences while the box was down
# (not crashed mid-run): the skip one must advance to the next FUTURE grid point
# with no catch-up delivery; the coalesce one keeps the single catch-up.

hour = 3_600_000

downtime_row = fn id, misfire ->
  %{
    id: id,
    state: "active",
    data: %{
      "id" => id,
      "name" => "downtime-#{misfire}",
      "state" => "active",
      "schedule" => %{"kind" => "every_ms", "every_ms" => hour},
      "misfire" => misfire,
      "next_run_at" => base_now - 5 * hour,
      "last_run_at" => base_now - 6 * hour,
      "payload" => %{"target" => "proactive", "message" => %{"action" => "run"}},
      "created_at" => base_now - 100 * hour,
      "updated_at" => base_now - 6 * hour
    }
  }
end

FakeStore.start([downtime_row.(60, "skip"), downtime_row.(61, "coalesce")])

{state10, _clock10, sink10} = init_state.(base_now, [], %{store_mod: FakeStore})

job10_skip = Map.fetch!(state10.jobs, 60)
job10_coal = Map.fetch!(state10.jobs, 61)

{:reply, tick10, state10} = tick.(state10, :ops)
decoded_tick10 = Jason.decode!(tick10)
job10_skip_after = Map.fetch!(state10.jobs, 60)

check.(
  "active skip job loaded 5 periods overdue: next_run_at advanced to the next FUTURE grid point at load, no catch-up delivery; coalesce twin keeps its past due and fires exactly one catch-up",
  job10_skip.next_run_at == base_now + hour and
    job10_coal.next_run_at == base_now - 5 * hour and
    decoded_tick10["launched"] == 1 and
    length(Agent.get(sink10, & &1)) == 1 and
    job10_skip_after.next_run_at == base_now + hour
)

# ── Vector 11 (I6): active skip job with poisoned cron expr at load records last_error (no silent-park) ──
# When load_misfire finds no next occurrence (poisoned expr) for an overdue
# skip-misfire job, it must record last_error to prevent silent parking.

poisoned_skip_row = %{
  id: 70,
  state: "active",
  data: %{
    "id" => 70,
    "name" => "poisoned skip",
    "state" => "active",
    "schedule" => %{"kind" => "cron", "expr" => "garbage"},
    "misfire" => "skip",
    "next_run_at" => base_now - 60_000,
    "last_run_at" => base_now - 120_000,
    "last_error" => nil,
    "payload" => %{"target" => "proactive", "message" => %{"action" => "run"}},
    "created_at" => base_now - 10_000,
    "updated_at" => base_now - 120_000
  }
}

FakeStore.start([poisoned_skip_row])

{state11, _clock11, _sink11} = init_state.(base_now, [], %{store_mod: FakeStore})
job11_loaded = Map.get(state11.jobs, 70)

check.(
  "active skip job with poisoned expr loaded overdue: next_run_at == nil AND last_error contains 'schedule'",
  job11_loaded != nil and
    job11_loaded.next_run_at == nil and
    is_binary(job11_loaded.last_error) and
    String.contains?(job11_loaded.last_error, "schedule")
)

# ── Vector 12 (W2 M6/Audit M6): string persisted ids and message job_ids are coerced strictly ──

string_id_row = %{
  id: "9",
  state: "active",
  data: %{
    "id" => "9",
    "name" => "string id",
    "state" => "active",
    "schedule" => %{"kind" => "every_ms", "every_ms" => 300_000},
    "next_run_at" => base_now + 300_000,
    "payload" => %{"target" => "proactive", "message" => %{"action" => "run"}},
    "created_at" => base_now,
    "updated_at" => base_now
  }
}

FakeStore.start([string_id_row])

{state12, _clock12, _sink12} = init_state.(base_now, [], %{store_mod: FakeStore})
job12_loaded = Map.get(state12.jobs, 9)

{:reply, pause12_reply, state12} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: "9"}), state12)

{:reply, invalid12_reply, _state12} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: "9x"}), state12)

check.(
  "string ids from store rows and protocol messages are coerced strictly without ArithmeticError",
  job12_loaded != nil and
    state12.next_id == 10 and
    Jason.decode!(pause12_reply)["ok"] == true and
    Jason.decode!(pause12_reply)["job_id"] == 9 and
    Jason.decode!(invalid12_reply)["ok"] == false and
    Jason.decode!(invalid12_reply)["error"] == "invalid job_id"
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON_SEEDS: ALL PASS")
else
  IO.puts("\nCRON_SEEDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

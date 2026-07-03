---
name: genswarms-cron-use
description: >-
  Wire the Genswarms.Cron scheduler object into a swarm: jobs as datetime +
  stamped message to an allowlisted target, trusted-source gating, injectable
  persistence, retry/backoff. Use when adding scheduled/proactive behavior to a
  swarm or debugging "job not created" (untrusted source), "job not delivered"
  (target not allowlisted), or jobs lost on restart (no store_mod).
---

# Genswarms.Cron — using the scheduler

A job is ONE due datetime + ONE stamped message to ONE allowlisted target.
Cron owns timing/concurrency/persistence/audit; target objects keep domain
authority (they validate the message they receive).

## Schedule kinds

- **One-shot**: `{"run_at": timestamp_or_iso_string}` — fires once at the specified UTC time.
- **Fixed-rate**: `{"every_ms": 5000}` — repeats every 5000ms; after an occurrence, the next due time is the smallest multiple of the period that exceeds now.
- **Cron expression**: `{"cron": "15,45 * * * *"}` — UTC, numeric-only fields; example runs at 15 and 45 minutes past every hour.

## Wiring

```elixir
%{name: :cron, handler: Genswarms.Cron, config: %{
  swarm_name: "my-swarm",
  trusted_sources: [:tg_ingress, :conversation_runtime],   # who may create jobs
  allowed_targets: %{conversation_runtime: ["scheduled_turn"]}, # target => action allowlist
  store_mod: MyApp.CronStore,   # optional; absent = memory-only (lost on restart)
  events_mod: MyApp.Events,     # optional; object/4 audit sink, absent -> Logger
  tick_ms: 60_000, max_concurrency: 16, max_attempts: 3,
  breaker_threshold: 5,         # optional; consecutive failures before pause
  seed_jobs: [                  # optional; upsert-by-dedupe_key at init
    %{name: "daily-report", dedupe_key: "loop:daily-report",
      schedule: %{"cron" => "0 8 * * *"},
      target: "reporter", message: %{"action" => "run", "loop" => "daily"}}
  ]
}}
```

**Fail-closed defaults**: empty `trusted_sources` (nobody can create jobs) and
empty `allowed_targets` (nothing deliverable). Both are the package's security
posture — declare them, don't patch the module.

Object protocol: `create_job` / `list` / `pause` / `resume` / `delete` / `tick` / `status`

`resume` only acts on **paused** jobs. Resuming a job in any other state
(running, active) is rejected with `{ok:false, error:"job not paused",
state:<current>}` and changes nothing — in particular it can never launch a
second concurrent run of a job that is already in flight. String fields on
`create_job` (`target`, `message.action`, `name`, `dedupe_key`, `misfire`)
must be scalar strings; non-scalar values are rejected `ok:false`, never
coerced.

## Declarative seeding

The `seed_jobs` config upserts jobs by `dedupe_key` at init — same key, same
job. If a live (non-terminal) job with the dedupe_key exists, it is updated in
place: schedule/payload/knob changes apply, and `next_run_at` is preserved
unless the schedule changed. If none exists, the seed is created — with ONE
exception: a **one-shot** seed whose dedupe_key already has a **terminal**
store row (`done`/`failed`/`deleted`) is a no-op, so a completed one-shot seed
fires exactly once across restarts instead of re-firing every boot. Recurring
seeds are declarative — if their job was deleted, the next boot re-creates it.
Any invalid seed raises at boot.

## Misfire policy

After unscheduled downtime, a missed occurrence can be **coalesced** (default)
— skip intermediate misfires and run once for the latest due time — or
**skipped** — treat the job as caught up without running it. The policy is
applied to recurring jobs everywhere a missed due point is discovered: at boot
load for an active job whose `next_run_at` is already past (ordinary
downtime), on crash-recovery of a job found `running`, and on manual `resume`.
`skip` advances to the next FUTURE grid point with no delivery; `coalesce`
fires exactly one catch-up. One-shot jobs are unaffected — a past-due one-shot
still fires its single catch-up.

## Consecutive-failure breaker

Jobs pause automatically when consecutive failures reach `breaker_threshold`;
the job row shows `paused_by: "breaker"`. Resume manually resets the counter.
A recurring job terminal-fails only when no next occurrence exists (an
unsatisfiable or corrupt schedule); a merely failing recurring job
breaker-pauses instead of failing terminally.

## Minimum period floor

`min_period_ms` (default 60_000) is enforced at CREATION for `every_ms` jobs
only. One-shot and cron-expression jobs are exempt (cron is inherently
minute-resolution). It is NEVER applied to retry attempts — those are governed
solely by `retry_backoff_ms`, which may legitimately be shorter than the floor.

## Grid rule

Recurring jobs re-arm on their original grid: after an occurrence with due time D,
the next due time is the smallest D+k·period strictly greater than now. This
guarantees exactly one catch-up after downtime and no duplicate runs.

## List rows

The `list` response rows include `kind` — the schedule kind string, one of
`"run_at"`, `"every_ms"`, `"cron"` — and `paused_by` (`nil` normally, or
`"breaker"` when the consecutive-failure breaker parked the job).

## Store seam (optional)

`load_cron_jobs(states)`, `max_cron_job_id()`, `save_cron_job(job)`,
`save_cron_run(job, result)` — any subset; guarded calls, memory fallback.

## Gotchas

- "Job silently not created" → sender not in `trusted_sources` (check exact
  object name; matching is by string).
- "create_job rejected" → target/action not in `allowed_targets`; creation is
  rejected immediately (`ok:false`), no job is stored. Only jobs LOADED from
  the store whose persisted target/action is no longer in the host's
  `allowed_targets` (stale config) attempt runs with backoff up to
  `max_attempts` — one-shots then fail, recurring jobs breaker-pause.
- Recovery: jobs in state `running` at boot are recovered against `now` (a
  crashed run re-arms). Without `store_mod` there is nothing to recover.

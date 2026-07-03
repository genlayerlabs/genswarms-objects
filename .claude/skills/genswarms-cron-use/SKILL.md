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
    {%{"run_at" => "2026-07-15T10:00:00Z"}, :daily_report, %{"user_id" => 42}}
  ]
}}
```

**Fail-closed defaults**: empty `trusted_sources` (nobody can create jobs) and
empty `allowed_targets` (nothing deliverable). Both are the package's security
posture — declare them, don't patch the module.

Object protocol: `create_job` / `list` / `pause` / `resume` / `delete` / `tick` / `status`

## Declarative seeding

The `seed_jobs` config upserts jobs by `dedupe_key` at init — same key, same job.
If the job already exists with the same dedupe_key and the schedule unchanged,
`next_run_at` is preserved. Any invalid seed raises at boot.

## Misfire policy

After unscheduled downtime, a missed occurrence can be **coalesced** (default) —
skip intermediate misfires and run once for the latest due time — or **skipped** —
treat the job as caught up without running it.

## Consecutive-failure breaker

Jobs pause automatically when consecutive failures reach `breaker_threshold`;
the job row shows `paused_by: "breaker"`. Resume manually resets the counter —
recurring jobs never reach a terminal-failed state.

## Minimum period floor

One-shot and cron jobs are not subject to a `min_period_ms` floor. Fixed-rate jobs
(every_ms) enforce it: the engine will never attempt a retry or re-arm sooner.

## Grid rule

Recurring jobs re-arm on their original grid: after an occurrence with due time D,
the next due time is the smallest D+k·period strictly greater than now. This
guarantees exactly one catch-up after downtime and no duplicate runs.

## List rows

The `list` response rows now include `kind` (one of `"one_shot"`, `"fixed_rate"`,
`"cron_expr"`) and `paused_by` (absent if running, or `"breaker"` if paused by
the consecutive-failure breaker).

## Store seam (optional)

`load_cron_jobs(states)`, `max_cron_job_id()`, `save_cron_job(job)`,
`save_cron_run(job, result)` — any subset; guarded calls, memory fallback.

## Gotchas

- "Job silently not created" → sender not in `trusted_sources` (check exact
  object name; matching is by string).
- "Job stuck" → target/action not in `allowed_targets`; runs are attempted with
  backoff up to `max_attempts` then failed.
- Recovery: jobs in state `running` at boot are recovered against `now` (a
  crashed run re-arms). Without `store_mod` there is nothing to recover.

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

## Wiring

```elixir
%{name: :cron, handler: Genswarms.Cron, config: %{
  swarm_name: "my-swarm",
  trusted_sources: [:tg_ingress, :conversation_runtime],   # who may create jobs
  allowed_targets: %{conversation_runtime: ["scheduled_turn"]}, # target => action allowlist
  store_mod: MyApp.CronStore,   # optional; absent = memory-only (lost on restart)
  events_mod: MyApp.Events,     # optional; object/4 audit sink, absent -> Logger
  tick_ms: 60_000, max_concurrency: 16, max_attempts: 3
}}
```

**Fail-closed defaults**: empty `trusted_sources` (nobody can create jobs) and
empty `allowed_targets` (nothing deliverable). Both are the package's security
posture — declare them, don't patch the module.

Object protocol: `create_job` / `list` / `pause` / `resume` / `delete` / `tick` / `status`

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

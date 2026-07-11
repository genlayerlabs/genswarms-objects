---
name: genswarms-cron-use
description: >-
  Wire the Genswarms.Cron scheduler object into a swarm: jobs as datetime +
  stamped message to an allowlisted target, trusted-source gating, injectable
  persistence, occurrence-scoped retry + a consecutive-failure breaker. Use
  when adding scheduled/proactive behavior to a swarm or debugging "job not
  created" (untrusted source), "job not delivered" (target not allowlisted),
  or jobs lost on restart (no store_mod).
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

Object protocol: `create_job` / `list` / `pause` / `resume` / `delete` / `tick`
/ `status` / `run_now`. A trusted sender's decoded JSON with an unrecognized
`"action"` gets `{ok:false, error:"unknown_action"}` (typo/version-skew
guard); malformed JSON or an untrusted sender is always a silent drop —
`interface/0` enumerates the full action set with neutral examples.

`resume` only acts on **paused** jobs. Resuming a job in any other state
(running, active) is rejected with `{ok:false, error:"job not paused",
state:<current>}` and changes nothing — in particular it can never launch a
second concurrent run of a job that is already in flight. String fields on
`create_job` (`target`, `message.action`, `name`, `dedupe_key`, `misfire`)
must be scalar strings; non-scalar values are rejected `ok:false`, never
coerced. Inbound messages over `max_message_bytes` (default 65536) are
rejected `{ok:false, error:"message_too_large"}` for a trusted sender and
silently dropped for an untrusted one.

## Create envelope

`run_at` (top-level, one-shot convenience) and `schedule` (nested map, all
three kinds) are the contract:

```json
{"action":"create_job","run_at":"2026-07-10T08:00:00Z","target":"reporter","message":{"action":"run"}}
```

```json
{"action":"create_job","schedule":{"cron":"0 8 * * *"},"target":"reporter","message":{"action":"run"},"dedupe_key":"reporter:daily-08"}
```

Recurring jobs (`every_ms`/`cron`) can ONLY be created via the nested
`"schedule"` key — a top-level `"every_ms"` is not a due-value alias and
fails `"schedule is required"`. `at` and `next_run_at` are accepted as
one-shot due-value aliases for `run_at` (schedule resolution order:
`run_at` → `at` → `next_run_at` → `schedule`) but are **deprecated** — new
callers should use `run_at`; the aliases exist only for callers already
depending on them and may be removed.

`"origin"` (optional) is a free-form scalar-valued provenance map —
`{"campaign_id": "c1", "score": 7}` — persisted on the job for audit; any
non-scalar value is dropped, and `"source"` defaults to the creating
sender if not supplied.

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

## `dedupe_key` idempotency: two different semantics

`dedupe_key` means different things on the seed path and the runtime
`create_job` path — pick the one the caller actually needs:

- **Seeds, and runtime `create_job` with `"once": true`**: "at most once
  EVER." A one-shot whose `dedupe_key` already has a **terminal** store row
  (`done`/`failed`/`deleted`) is a no-op — it will never re-fire, even
  across restarts or repeated identical calls. Reply on the no-op path is
  `{"ok":true,"job_id":<id>,"state":<terminal-state>,"deduped":true}` (no
  `next_run_at` — there is no live job).
- **Runtime `create_job` WITHOUT `"once": true` (the default)**: "at most
  one LIVE." Only non-terminal (active/paused/running) in-memory jobs are
  checked; a `dedupe_key` that already fired to `done` is invisible to this
  check and a repeat `create_job` call re-creates and re-fires it.

If a caller creates one-shot jobs repeatedly with the same `dedupe_key`
(e.g. a reminder re-armed on every poll of some upstream fact), it MUST set
`"once": true` — the default dedupe is the weaker of the two and will
silently duplicate a fired one-shot.

`"once": true`'s terminal-row lookup goes through `store_mod`
(`load_cron_jobs(@terminal_states)`); without a `store_mod` wired, that
lookup always sees no rows, so `once: true` silently degrades to the
weaker live-only dedupe (a fired one-shot is forgotten and can duplicate on
the next call) — `once: true` needs `store_mod` to actually deliver its
"at most once EVER" guarantee.

## `run_now`

`{"action":"run_now","job_id":1}` fires an **active** job immediately
through the normal claim → deliver → finish path (same breaker accounting,
same `save_cron_run` audit row as a grid-triggered run) — it does not
invent separate delivery logic. The fired occurrence is `now`, not the
job's scheduled `next_run_at`; on success a recurring job re-arms from that
`now`, not from the old future due time. Paused jobs get
`{"ok":false,"error":"job not active","job_id":<id>,"state":"paused"}`;
terminal/removed jobs get `{"ok":false,"error":"job terminal",...}` or
`{"ok":false,"error":"job not found",...}`. Trusted-source-gated like every
other action. At `max_concurrency` capacity, `run_now` is rejected
(`{"ok":false,"error":"at max concurrency",...}`) rather than deferred —
there is no due-queue to defer an immediate-fire request onto.

Re-arming after `run_now` differs by kind: `every_ms` re-phases
**permanently** — the new `next_run_at` is anchored to the `run_now`
occurrence itself (`now + period`), so every future occurrence shifts to
that phase. A `cron`-kind job stays on its **absolute grid** — firing it
early via `run_now` doesn't move `next_run_at` off the calendar points the
expression matches.

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

Every run outcome emits a `:job_run` event via `events_mod` (absent →
Logger); a non-`ok` outcome additionally emits `:job_run_failed`
(job name, error, state, attempts, consecutive_failures); the specific run
that trips the breaker additionally emits `:job_breaker_paused` (job name,
consecutive_failures). These are the only failure-observability signal
under the default `deliver_fn` — see "Delivery is at-most-once" below for
why `max_attempts`/breaker tuning otherwise has nothing to react to.

## Delivery is at-most-once by default — retry/breaker governs a narrower case than it sounds

The **default** `deliver_fn` casts the message to the target object and
unconditionally returns `:ok` — it does not wait for, or see, how the
target handles the message. Under default wiring, `max_attempts`,
`retry_backoff_ms`, `last_error`, and the consecutive-failure breaker can
only ever be triggered by two things: (1) the target/action was removed
from `allowed_targets` after the job was created (a stale-config error at
dispatch), or (2) a **custom** `deliver_fn` that returns `{:error, reason}`
or raises. A flaky target that silently fails its own handling of the
delivered message is invisible to cron — tuning `max_attempts` for that
target's reliability buys nothing unless `deliver_fn` is replaced with one
that can actually observe the outcome (`deliver_fn :: (target, from, json)
-> :ok | {:error, reason}`).

## Delivery bypasses the engine's message-observability plane

The default `deliver_fn` casts directly to `ObjectServer.deliver_message/4`
from inside a `Task`, not through the handler-return `{:send, to, msg,
state}` idiom other objects use. That means cron-fired messages skip Router
topology validation and the engine's LogStore `:message_sent` record — they
are invisible in the engine's message log/dashboard, and `allowed_targets`
is the only authorization check they get (there is no topology gate behind
it). `Genswarms.Cron`'s own `:job_run`/`:job_run_failed` events (via
`events_mod`) are the audit trail for outcomes, but they record status, not
message content. This is a deliberate, written-down tradeoff, not an
oversight — it exists because a `Task` context can't return a handler
`{:send, ...}` shape, and because delivery above is already at-most-once
regardless.

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

The `list` response rows include `kind` (the schedule kind string, one of
`"run_at"`, `"every_ms"`, `"cron"`), the full `schedule` map (the same
JSON-pure kind map that was normalized at create time — cron expr / every_ms
/ run_at_ms, whatever an operator needs to answer "why did this fire at
:15"), `dedupe_key`, and `paused_by` (`nil` normally, or `"breaker"` when the
consecutive-failure breaker parked the job). There is no separate `get_job`
or per-id filter — `list` (`include_paused` is the only query flag; the
caller filters client-side by `id`) is the whole read path.

## Store seam contract (optional)

`load_cron_jobs(states)`, `max_cron_job_id()`, `save_cron_job(job)`,
`save_cron_run(job, result)` — implement any subset; every call is guarded
(`function_exported?/3`), so a nil `store_mod` or a partial module both
degrade that call to memory-only (jobs still run, they just don't survive a
restart). `Genswarms.Cron.Store` (packages/cron/store.ex) carries the same
contract as `@callback`/`@typedoc` for adopters who want compiler drift
warnings — it is documentation only, nothing checks `@behaviour` against it.

The load-bearing parts that are easy to get wrong:

- **`load_cron_jobs(states)`** — `states` is a list of STRING state names
  (`["active","paused","running"]` at boot, `["done","deleted","failed"]`
  for terminal dedupe lookups). MUST return rows shaped
  `%{id: id, state: state, data: data}` with **atom** keys at the top
  level — a string-keyed row (`%{"id" => ...}`) crashes `init/1` with a
  `FunctionClauseError`, there is no fallback clause. `id` may be an
  integer or a numeric string (coerced). `data` MUST be the string-keyed
  JSON round-trip of the job map `save_cron_job/1` was handed — i.e.
  `job |> Jason.encode!() |> Jason.decode!()`, not the raw atom-keyed job.
- **`max_cron_job_id()`** — an integer or numeric string ≥ 0; anything else
  is treated as absent and defaults to `0`.
- **`save_cron_job(job)` failures are contained and observable.** Return
  `{:error, reason}` to report a durability failure; every other return value
  counts as success for backward compatibility. A raise, throw, or exit also
  counts as failure. The job stays live in memory, while `events_mod` receives
  one `:job_persistence_failed` transition and a later
  `:job_persistence_recovered` after saving succeeds again. Missing Store/save
  callbacks remain silent memory-only mode.
- **The other callbacks must not raise.** `load_cron_jobs/1`,
  `max_cron_job_id/0`, and `save_cron_run/2` are not rescued. From `init/1`, a
  raising load/max callback causes an `ObjectServer` boot crash (see "Boot
  behavior" below); a raising run-audit callback crashes message handling.
  Wrap that Store I/O in your own guard.
- **`claimed_due` is deliberately discarded on reload.** Whatever was
  persisted for `claimed_due` is dropped and reset to `nil` when a row is
  loaded — the in-flight claim marker is meaningless across a restart;
  `recover/2` (job.ex) re-derives the right recovery point from `state` and
  `next_run_at` instead.

## Boot behavior: invalid config aborts boot by design

Both an invalid `seed_jobs` entry and an `allowed_targets` key that doesn't
resolve to an already-loaded atom (`String.to_existing_atom/1` failure)
`raise ArgumentError` during `init/1` — "cron seed ... needs dedupe_key",
"invalid cron seed ...", "cron allowed_targets: unknown object :x". This is
intentional: a bad seed or a typo'd target name is a deploy-time config bug,
not a runtime no-op that would silently kill all timing for that job.
The engine has no rescue around `handler.init/1`, so the practical failure
mode is an `ObjectServer` crash (not a clean `{:error, reason}` the engine
parks gracefully) — if `allowed_targets` names a JSON-IR-configured object
whose atom hasn't been minted yet by config load order, fix the ordering,
not the target name.

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
- "Reminder fired twice across restarts/polls" → the caller used the
  default `create_job` dedupe (live-only) for a one-shot instead of
  `"once": true` (once-ever) — see the `dedupe_key` idempotency section.
- "`run_now` did nothing" (`ok:true` but the target never got the message) →
  check `deliver_fn`; the default is fire-and-forget and doesn't report
  target-side failures (see "Delivery is at-most-once" above).

# genswarms-cron — Design Spec

**Date:** 2026-07-02
**Status:** Draft v2 — adversarial design review applied (same date)
**Package:** `:genswarms_cron` (`Genswarms.Cron.*`) — swarmidx kind `handler`, scope `acastellana`
**Repo:** `genlayerlabs/genswarms-cron` (this repo)

## 1. Overview

A reusable, deterministic scheduler object for GenSwarms swarms. A job is a
schedule plus one stamped message to one allowlisted target object. The package
owns *when* and the delivery guarantees; host applications own *what happens*
when the message lands.

Extracted from the third reimplementation of the same skeleton:
`MicroMarkets.Cron` (the seed — one-shot durable jobs, allowlisted dispatch,
retries, audit), `Wingston.Objects.Cron` (clock-aligned periodic loops), and
the upcoming GenLayer Observer (agent-created jobs with approval).

### Goals

- Any swarm on the stack schedules work with **zero scheduler code**: jobs are
  data, targets are objects the host was going to write anyway.
- Safe to expose to LLM agents (subzeroclaw) under deterministic guardrails.
- Observable by construction: LogStore events, audit trail, dashboard page.

### Non-goals (v0.1)

Timezones (UTC only), seconds-resolution schedules, multi-node BEAM
distribution, exactly-once delivery, job chains/dependencies, priorities,
fan-out (one job = one target), multi-tenancy, calendar rules (holidays).

## 2. Ecosystem position and purity rule

```
subzeroclaw + genswarms (core, untouched)
    ├── genswarms_telegram   (transport)
    ├── genswarms_cron       (scheduling)      ← this package
    └── host app / swarm packages (observer, micromarkets, wingston, …)
```

The package speaks ONLY the framework vocabulary: **objects (stable names),
agents (slots), messages with a framework-set `from`, time, its own Store, and
LogStore/PubSub**. It never interprets transport or product concepts —
principals, conversations, budgets are opaque data or host hooks.

**Purity gate (CI):** `scripts/purity_check.sh` greps `lib/` for forbidden
transport vocabulary (`telegram`, `tg:`, `chat_id`, `group_id`, `dm_`,
`conversation`) and fails the build on any hit. Same discipline as
genswarms-telegram's "no host names in package source" release gate.

Dependencies: `jason` only. The cron-expression parser is written in-package,
pure Elixir (~200 lines) — no hex `crontab`, no NIFs, in the ecosystem spirit.

## 3. Architecture

| Module | Kind | Responsibility |
|---|---|---|
| `Genswarms.Cron.Objects.Scheduler` | `ObjectHandler` | The object: actions, timers, dispatch, quotas, state machine |
| `Genswarms.Cron.Schedule` | pure | Parse `schedule` maps; compute next occurrence; misfire math |
| `Genswarms.Cron.CronExpr` | pure | 5-field cron expression parser/matcher (UTC) |
| `Genswarms.Cron.Policy` | pure | Source-class/name policy resolution; quota checks; scoping rules |
| `Genswarms.Cron.Envelope` | pure | Build/validate the JSON-pure delivery envelope |
| `Genswarms.Cron.Store` | behaviour | Durable persistence contract; `Store.Memory` default |
| `Genswarms.Cron.DashboardPage` | pure | Declarative extension-page builder from Store data |
| `priv/agent-guide/cron.md` | doc | Transport-neutral skill file for LLM agents |

Multiple Scheduler instances may run in one swarm (e.g. `:cron`,
`:cron_billing`) with independent config; every Store row is keyed by
`(swarm, instance)` so two swarms sharing one database never collide.

## 4. Job model

```
job = {
  id,                    # integer, monotonically increasing per (swarm, instance)
  ref,                   # optional creator-supplied idempotency key (≤ 128 bytes)
  schedule,              # see §5
  target,                # object name (atom) — allowlisted; never a Scheduler instance
  message,               # host-defined JSON map (its "action" is allowlisted per target);
                         #   ≤ max_message_bytes; MUST NOT contain the reserved "cron" key
  state,                 # pending_approval | active | paused | done | failed | deleted
  created_by,            # %{source: from, class: :object | :agent}  (framework-trusted)
  principal,             # opaque binary | nil — set ONLY by attribution_fn
  context,               # opaque JSON blob | nil — host-bound routing context, set ONLY
                         #   by attribution_fn; stamped verbatim into the envelope
  ttl_ms,                # anchored at CREATION; enforced in every non-terminal state
                         #   (including pending_approval and paused); policy default for
                         #   agent-class jobs
  misfire,               # :coalesce (default) | :skip
  overlap,               # :skip (default; singleton per job) | :allow
  run_timeout_ms, max_attempts, retry_backoff_ms, jitter_ms,   # per-job overrides
  breaker_threshold,     # consecutive failed OCCURRENCES before auto-pause (default 5)
  next_run_at, last_run_at, last_error,
  counters (occurrences, failures, consecutive_failures, overlap_skips, missed)
}
```

State machine: `pending_approval → active` (approve) or `→ deleted` (reject);
`active ↔ paused`; `active → done` (one-shot completed, TTL expiry) `| deleted`.
**`failed` is terminal only for one-shots** whose attempts are exhausted; a
recurring job whose occurrence exhausts its attempts records the failure,
notifies, and schedules the next occurrence — it dies only via the breaker:
`consecutive_failures ≥ breaker_threshold → paused` (which IS resumable).
`running` is a per-fire transient recovered on boot (a job found mid-run at
boot is marked `last_error: "scheduler restarted while job was running"` and
rescheduled, as in the MicroMarkets seed).

"Live" for quota purposes = every non-terminal state
(`pending_approval`, `active`, `paused`).

Attribution fields (`created_by`, `principal`, `context`) are **immutable**
after creation. Redirecting billing, routing, or reporting is creating a new
job. Every mutation (pause/resume/delete/approve/reject) records the acting
`from` in the audit trail.

## 5. Schedules

`schedule` is exactly one of:

| Kind | Shape | Semantics |
|---|---|---|
| one-shot | `{"run_at": "2026-07-02T10:00:00Z"}` (ISO8601 or epoch ms) | fire once |
| interval | `{"every_ms": 300000}` | **fixed-rate**: next = scheduled + period (no drift accumulation) |
| cron | `{"cron": "15,45 * * * *"}` | 5-field, evaluated in **UTC** |

`CronExpr` implements standard vixie-cron semantics: fields
`minute hour day-of-month month day-of-week`; `*`, lists, ranges, `*/step`;
DOW 0 and 7 both Sunday; **when both DOM and DOW are restricted the match is
OR** (the POSIX quirk — pinned by test vectors). Minute resolution.
**Numeric fields only in v0.1** — month/day names (`JAN`, `MON`) are rejected.
`tz` is a reserved future field, rejected in v0.1.

### Pinned edges (each carries a named test vector)

- **First fire of `every_ms`** = `created_at + period` (never immediate).
- **`run_at` in the past at creation** → rejected (`{"ok":false,"error":"run_at_past"}`)
  if older than one `tick_ms` grace; this also closes the agent-tier loophole
  where a past `run_at` trivially satisfies `max_horizon_ms`.
- **Approval of a stale pending job** (its `run_at`/occurrence passed while
  queued) → the job's misfire policy applies at approval (`:coalesce` = fire
  on next tick; `:skip` = advance/complete).
- **`resume` after a long pause** → the job's misfire policy applies, exactly
  as for scheduler downtime.

## 6. Trust model

### Layered agent gating (slots are fungible)

Agent slots are LRU-recycled — `agent_2` names a different conversation over
time. The package therefore never treats a slot name as an identity. Agent
access is gated in layers:

1. **Topology (host-side, first line):** agent→object messages travel through
   `Router.route`, which enforces topology edges — only agent templates the
   host wires with a `connections: [:cron, …]` edge can reach the scheduler
   at all. Role separation (coordinator may schedule, specialists may not) is
   expressed by giving only the coordinator template the edge, and/or by
   role-distinct slot prefixes chosen by the host's session runtime.
2. **`trusted_sources` (package):** objects by name; agents by name pattern.
3. **Class policy + quotas (package):** see below — with all agent-class
   accounting keyed by **principal**, never by slot name.

Class is derived from the framework Registry's entity type (objects and agents
are registered distinctly), with slot-name pattern matching only as fallback —
an object that happens to be named `agent_foo` must not inherit agent policy.

### Source classes and policies

```elixir
source_policies: %{
  object: %{schedule_kinds: :all, requires_approval: false},
  agent:  %{
    schedule_kinds: [:run_at],          # follow-up tier: one-shots only…
    max_horizon_ms: 86_400_000,         # …at most 24h out
    targets: [:runtime],                # subset of allowed_targets
    max_live_jobs: 5,                   # per PRINCIPAL (live = non-terminal)
    max_pending_approval: 3,            # per principal — bounds the human-attention queue
    min_period_ms: 300_000,             # frequency floor (see below)
    ttl_ms: 172_800_000,                # agent jobs expire in 48h (any non-terminal state)
    requires_approval: false,
    nil_principal: :deny,               # :deny | :system_bucket (quota under a synthetic key)
    durable: %{                         # everything beyond the follow-up tier
      schedule_kinds: :all,
      requires_approval: true           # → pending_approval
    }
  },
  # per-name override example: %{ingress: %{...}}
}
```

An agent-class `create_job` that exceeds the follow-up tier (recurring, far
horizon, wider target) is not rejected — it lands as `pending_approval`.
`approve_job` / `reject_job` are accepted only from `approver_sources`
(default: the objects in `trusted_sources`; configurable narrower). Who is an
approver and how approval surfaces (a command, a UI) is host business.

### Quotas and floors

- `max_live_jobs` and `max_pending_approval` per **principal** for agent-class
  sources (a recycled slot must neither inherit nor grief another
  conversation's quota); per source name for object-class.
- Instance-wide `max_jobs` safety valve (config) — bounds total non-terminal
  jobs even against a buggy *trusted object*.
- `min_period_ms` floor: validated at creation for `every_ms`; enforced at
  fire time **against scheduled occurrences only — never against retry
  attempts** (retries use `retry_backoff_ms` and are exempt, or a 60s backoff
  would trip a 300s floor).

### Mutation and read scoping

`pause` / `resume` / `delete` / `list` / `get` authority is scoped by class:

- **object-class** callers: any job in the instance.
- **agent-class** callers: ONLY jobs whose `principal` equals the caller's
  freshly re-computed attribution (`attribution_fn` runs on every such call,
  not just create). An agent-class caller with `nil` principal may mutate or
  read nothing. `list` output for agent-class callers contains only their own
  principal's jobs — job payloads authored in other conversations must never
  enter an unrelated LLM context.
- `tick`, `pause_all`, `resume_all`, and full `status` are **object-only**;
  agent-class `status` returns only the caller's own quota usage.

### Creation-time authorization

`attribution_fn` (see §7) may return `{:deny, reason}` — the host's way to
express "this source/context may not schedule at all" (per-conversation bans,
maintenance windows at create time). Agent-class creations resolving to `nil`
principal follow the `nil_principal` policy: denied (default) or quota'd under
a synthetic system bucket — an un-attributed agent job must never silently
escape per-principal quotas by looking like a system job.

### The golden rule

**The LLM never assigns identities.** `principal` and `context` come
exclusively from the host's `attribution_fn`; any such fields inside an
agent-class `create_job` message are grounds for rejection, and a `message`
containing the reserved `"cron"` key is rejected outright (§7). The agent
chooses *when*, never *who*, *where*, or *beyond what* the allowlists permit.
Attribution routes billing, reporting, and (via `context`) delivery framing —
it never elevates what a run may do (the allowlist decides that at creation;
confused-deputy prevention).

## 7. Attribution and the delivery envelope

Creation-time hook (also invoked to scope agent-class mutations, §6):

```elixir
attribution_fn: fn from, class, msg ->
  {:ok, principal_binary | nil, context_json | nil} | {:deny, reason}
end
```

The host derives the principal AND an opaque **context** blob from *its*
trusted state (session bindings, command identity) — e.g. the conversation a
follow-up must return to. The agent cannot supply either: agents never know
their own conversation identity in this ecosystem, and a claimed one would be
laundered through cron's trusted `from`. Default hook: `{:ok, nil, nil}`
(system job).

Every dispatched message is the job's `message` map with one reserved key
merged in:

```json
"cron": {
  "job_id": 7,
  "fire_id": "7:1751450400000",
  "scheduled_at": 1751450400000,
  "fired_at": 1751450400213,
  "attempt": 1,
  "created_by": {"source": "agent_2", "class": "agent"},
  "principal": "opaque-host-string-or-null",
  "context": {"opaque": "host blob or null"},
  "instance": "cron"
}
```

**Envelope integrity rules (each pinned by a test):**

- `create_job` **rejects** any `message` already containing the `"cron"` key —
  rejection, not overwrite: silently overwriting would hide a forgery attempt
  (`{"ok":false,"error":"reserved_key"}`).
- **Targets MUST resolve identity and routing from the host-stamped envelope
  fields (`principal`, `context`, `created_by`) whenever
  `created_by.class == "agent"`, and MUST treat any routing-shaped fields in
  the message body of agent-class jobs as untrusted data.** This is the
  spec-level contract that closes the recycled-slot / cross-conversation
  injection hole: `created_by.source` is *provenance* (stale at fire time),
  `context` is *routing* (host-bound at creation).

`fire_id = "<job_id>:<scheduled_at_ms>"` — deterministic per scheduled
occurrence, so redeliveries of the same occurrence carry the same id and
targets that need idempotency dedupe on it (the `action_key` pattern already
proven in the MicroMarkets Signer). The envelope and message MUST be JSON-pure
(no atoms/tuples in values) so `:process`-mode objects (Docker/SSH JSON
handlers) work unmodified.

**Creation idempotency:** `create_job` accepts an optional `ref`; for
agent-class sources the idempotency key is `(principal, ref)` — never
`(slot, ref)`, or conversation B inheriting a recycled slot would collide with
(and be handed) conversation A's job. Object-class refs key on `(source, ref)`.

## 8. Execution semantics

- **Delivery guarantee: at-least-once.** A crash between delivery and
  bookkeeping may redeliver an occurrence (same `fire_id`). Exactly-once is
  not promised anywhere.
- **Targets are objects only — never agent slots, never a Scheduler.** Slots
  are fungible; waking an agent is the host runtime object's job
  (`scheduled_turn` pattern). Config validation rejects agent-slot names AND
  any Scheduler instance (this or a sibling) in `allowed_targets` — a job
  arriving at a scheduler would carry `from = :cron`, object class, letting an
  agent launder privileged actions (self-approval, quota-free `create_job`
  chains) through the dispatch path. Belt-and-braces: a Scheduler **refuses
  every privileged action in any inbound message that carries the reserved
  `"cron"` envelope key** — machine-dispatched messages never carry object
  authority.
- **Delivery bypasses Router topology by design** (`deliver_message` is a
  direct cast); the scheduler's own `allowed_targets` allowlist is the
  authority on where jobs may land.
- **Ack contract (correlation-pinned):** dispatch is a cast; cast success
  means *delivered*. A target MAY report an attempt result by replying (or
  sending back) a message that **echoes the `fire_id`**:
  `{"ok": true|false, "fire_id": "7:1751450400000", ...}`. Replies without a
  matching in-flight `fire_id` are ignored. No echo within `run_timeout_ms`
  (monotonic clock) → the attempt closes as delivered-ok. `{"ok": false}` or a
  delivery error → failed attempt → retry with `retry_backoff_ms`, up to
  `max_attempts`. Cron is an alarm clock with guarantees, not a job runner:
  long work is the target's business.
- **Attempts are per-occurrence, never per-job** (§4): exhausting
  `max_attempts` fails that *occurrence*; recurring jobs continue to the next
  occurrence; only the consecutive-failure breaker parks the job (`paused`,
  resumable). One transient 3-retry outage must not kill a nightly job
  forever.
- **Misfire (`:coalesce` default):** occurrences missed while the scheduler
  was down collapse into ONE catch-up run whose `fire_id` is the latest missed
  occurrence; then normal future scheduling resumes. `:skip` advances to the
  next future occurrence and counts the missed ones. Never fire-all. The same
  policy applies on `resume` and on approval of stale pending jobs (§5).
- **Overlap:** `:skip` (default) — if the previous run of a job is still in
  flight when the next occurrence is due, the occurrence is skipped and
  counted (`overlap_skips`). `:allow` permits concurrent runs for targets that
  are safe under them.
- **Fire-time authorization (deferred authority):**

  ```elixir
  authorize_run: fn job, envelope -> :ok | {:skip, reason} | {:pause, reason} | {:cancel, reason} end
  ```

  Called before every dispatch. The host re-checks whatever "still allowed"
  means to it (membership, consent, budget). `{:pause, "budget"}` parks the
  job instead of burning attempts. Default: always `:ok`.
- **Jitter:** optional per-job `jitter_ms` (uniform 0..N added to each fire)
  so clock-aligned jobs don't stampede targets.

## 9. Failure reporting and observability

- **notify_target:** occurrence failures (attempts exhausted), breaker pauses,
  TTL expiries, and hook pauses emit ONE stamped message to the configured
  `notify_target` object (must be in `allowed_targets`), carrying the envelope
  + error. Per-job cooldown (`notify_cooldown_ms`) so a flapping job cannot
  spam. **Notify delivery failures never mutate job state** — a dead notifier
  must not park healthy jobs; instead the scheduler marks itself
  `notify_degraded` (surfaced in `status`, the heartbeat event, and the
  dashboard page). How a notification reaches a human (which channel,
  fallbacks) is entirely the host notifier's business.
- **LogStore events** (framework-native, PubSub-subscribable — the universal
  integration point for anything unforeseen): `job_created`, `job_approved`,
  `job_rejected`, `job_paused`, `job_resumed`, `job_deleted`, `job_fired`,
  `job_completed`, `job_failed`, `job_expired`, `quota_denied`
  (rate-coalesced per source — an agent retry loop must not flood the ring
  buffer), and a periodic **`cron_heartbeat`** with counts + degradation
  flags. The heartbeat exists so an external watchdog can detect a silently
  dead scheduler — a dead scheduler is the quietest failure there is: nothing
  errors, nothing happens.
- **Audit trail** in the Store: every mutation with acting `from` + timestamp;
  pruned on its own retention clock (§10) so it cannot grow without bound.
- **Dashboard page:** `DashboardPage.page(store_mod, swarm, instance, opts)`
  returns a declarative extension page (`extensions["dashboard_pages"]` entry —
  metrics: active/running/pending_approval/failures-24h/quota usage/
  `notify_degraded`; jobs table: id, human schedule, next run, target, state,
  created_by class, principal, TTL; recent-runs table). The host merges it
  into its `DataSource.snapshot/1` — one line. Read-only by construction (the
  renderer treats all values as display data); it reads the **Store**, not the
  object process, so jobs stay visible even when the scheduler is wedged.
  Respects renderer caps (≤100 rows; summary metrics carry the totals).
- Deterministic listing actions (`list`, `status`) give day-one visibility to
  host commands (e.g. a `/jobs` command) before any dashboard exists —
  scoped per §6 for agent-class callers.

## 10. Store behaviour

```elixir
@callback init(opts) :: {:ok, ref}
@callback put_job(ref, scope, job) :: :ok                 # scope = {swarm, instance}
@callback get_job(ref, scope, id) :: {:ok, job} | :not_found
@callback list_jobs(ref, scope, states) :: [job]
@callback max_job_id(ref, scope) :: non_neg_integer
@callback record_run(ref, scope, run) :: :ok              # fire_id, result, duration, error
@callback list_runs(ref, scope, job_id, limit) :: [run]
@callback record_audit(ref, scope, entry) :: :ok
@callback prune(ref, scope, %{runs_per_job: n, terminal_days: d, audit_days: a}) :: :ok
```

- Default `Store.Memory` (ETS) — tests and ephemeral swarms. The table is
  named/public (or heir-owned) so `DashboardPage` reads survive a wedged
  Scheduler process. **Documented caveat:** a Memory-store restart resets
  `max_job_id`, so `fire_id` values can recur across *different* jobs — hosts
  whose targets dedupe on `fire_id` across restarts need a durable store.
- Hosts implement Postgres/sqlite adapters (MicroMarkets already has the
  tables; migration is an adapter).
- All rows keyed by `(swarm, instance)` (multi-instance, shared-database
  safe).
- Pruning runs periodically from the Scheduler (defaults: 50 runs/job kept,
  terminal jobs 30 days, audit 90 days).
- **Documented limitation:** one Scheduler instance per `(swarm, instance)`
  Store scope (single-node BEAM — the stack's reality today). Multi-node
  would add an optional lease callback later; documented, not built.

## 11. Object API (JSON actions over `handle_message`)

All actions require `from ∈ trusted_sources`; authority is scoped per §6
(agent-class: own-principal jobs only; `tick`/`pause_all`/`resume_all`/full
`status` are object-only; `approve_job`/`reject_job` require
`approver_sources`).

```jsonc
// create (agent follow-up tier example)
{"action":"create_job","ref":"followup-mkt3","schedule":{"run_at":"2026-07-02T18:00:00Z"},
 "target":"runtime","message":{"action":"scheduled_turn","note":"re-check market 3"}}
// → {"ok":true,"job_id":12,"state":"active","next_run_at":1751479200000}
// → {"ok":true,"job_id":13,"state":"pending_approval"}          (durable tier)
// → {"ok":false,"error":"quota_exceeded"} | "target_not_allowed" | "bad_schedule"
//    | "run_at_past" | "reserved_key" | "message_too_large" | "attribution_denied" | …

{"action":"approve_job","job_id":13}      // approver_sources only
{"action":"reject_job","job_id":13}       // approver_sources only
{"action":"pause","job_id":12} / {"action":"resume","job_id":12} / {"action":"delete","job_id":12}
{"action":"list","states":["active","pending_approval"]}   // scoped for agent-class callers
{"action":"status"}                        // full for objects; own-quota-only for agents
{"action":"tick"}                          // object-only; manual drive (tests / auto_tick: false)
{"action":"pause_all"} / {"action":"resume_all"}   // object-only maintenance switch
```

The delivered payload (target side) is the job's `message` plus the reserved
`"cron"` envelope (§7). A target reporting a result echoes the `fire_id` (§8).

## 12. Configuration reference

```elixir
%{
  name: :cron,                       # instance name (Store scope, envelope field)
  swarm_name: "my-swarm",            # Store scope
  store_mod: {Genswarms.Cron.Store.Memory, []},
  now_fn: &Schedule.now_ms/0,        # injectable clock (tests)
  deliver_fn: nil,                   # default: ObjectServer.deliver_message within swarm
  auto_tick: true, tick_ms: 60_000,
  max_concurrency: 16,
  max_jobs: 1_000,                   # instance-wide non-terminal cap (safety valve)
  max_message_bytes: 16_384,         # payload cap, validated at creation
  defaults: %{max_attempts: 3, retry_backoff_ms: 60_000, run_timeout_ms: 30_000,
              misfire: :coalesce, overlap: :skip, jitter_ms: 0, breaker_threshold: 5},
  trusted_sources: [...],            # objects and/or agent name patterns (Registry-type checked)
  approver_sources: nil,             # default: the objects in trusted_sources
  allowed_targets: %{runtime: ["scheduled_turn"], notifier: ["cron_report"]},
                                     # validated: no agent slots, no Scheduler instances
  source_policies: %{...},           # §6 (class + per-name overrides)
  attribution_fn: nil,               # §7 — {:ok, principal, context} | {:deny, reason}
  authorize_run: nil,                # §8
  notify_target: :notifier, notify_cooldown_ms: 3_600_000,
  heartbeat_ms: 60_000,
  retention: %{runs_per_job: 50, terminal_days: 30, audit_days: 90}
}
```

## 13. Agent guide (subzeroclaw)

`priv/agent-guide/cron.md` — transport-neutral skill content the host may
concatenate into an agent's skills: how to `create_job`/`list`/`delete` via
`swarm-msg`, the follow-up vs durable distinction ("recurring requests await
human approval"), the `ref` idempotency field, and the explicit constraints
("you never choose who a job is billed to, where it routes, or where its
reports go — the system derives that; schedules below the configured floor
are rejected; you can only see and mutate your own jobs").

## 14. Testing strategy

- Pure-core vectors: `CronExpr` (steps, lists, ranges, the DOM/DOW OR-quirk,
  numeric-only enforcement — names rejected, invalid fields), `Schedule`
  next-occurrence + misfire math around clock jumps, and the §5 pinned edges
  as named vectors (every_ms first fire; past run_at rejected; stale pending
  approval; resume-misfire).
- Scheduler driven as a pure function: `auto_tick: false` + injected `now_fn`
  + `tick` action; `Store.Memory` + a `FakeStore` asserting the persist →
  restart → reload → resume cycle (the MicroMarkets harness Section E
  pattern).
- **Security vectors (each maps to a §6–§8 rule):** reserved-`"cron"`-key
  creation rejected; scheduler-as-target rejected at config validation;
  privileged actions refused when the inbound message carries the envelope
  key (self-approval laundering); agent-class mutation/list scoping — a
  second principal on a recycled slot can neither read, mutate, collide refs
  with, nor consume the quota of the first; `nil`-principal agent creation
  denied (and system-bucket mode quota'd); attribution `{:deny, …}` honored;
  envelope fields never overridable from message bodies.
- Execution-semantics vectors: at-least-once redelivery with stable
  `fire_id`; ack correlation (echoing vs non-echoing replies, timeout on
  monotonic clock); attempts-per-occurrence — recurring job survives an
  exhausted occurrence, breaker pauses after N consecutive, resume applies
  misfire; floor exempts retries; overlap `:skip` and `:allow`; TTL expiry in
  `pending_approval` and `paused`; payload/ref size caps; notify cooldown +
  `notify_degraded` never mutating job state; `quota_denied` event
  coalescing.
- Purity gate in CI (§2).

## 15. Publication

`swarmidx.json` at repo root:

```json
{"registry": {"scope": "acastellana"},
 "packages": [{"name": "genswarms-cron", "dir": ".", "kind": "handler",
               "description": "Deterministic scheduler object for GenSwarms swarms"}]}
```

Tag `v0.1.0` → `gsp publish swarmidx.json --version 0.1.0
--source github://genlayerlabs/genswarms-cron@main` against
`SWARMIDX_ENDPOINT=https://swarmidx.ygr.ai`. Consumers:
`{:genswarms_cron, github: "genlayerlabs/genswarms-cron", tag: "v0.1.0"}` with
a `GENSWARMS_CRON_PATH` sibling-checkout escape hatch (the genswarms-telegram
`mix.exs` pattern).

## 16. Migration notes (no forced timeline)

- **MicroMarkets:** its cron is the seed; migration = a Store adapter over the
  existing `cron_jobs`/`cron_runs` tables + config translation (its
  `allowed_targets`/`trusted_sources` map 1:1). Behavior deltas gained:
  recurrence, approval tiers, envelope stamping.
- **Wingston:** its product loops stay in its own orchestrator object; the
  five named timers become five cron-expression jobs
  (`"0 * * * *"`, `"15,45 * * * *"`, …) targeting that object.
- **Observer:** consumes from the first commit; opens the agent tiers for its
  coordinator (topology edge on the coordinator template only, §6).

## 17. Future (explicitly deferred, with their trigger)

| Item | Trigger to build it |
|---|---|
| `tz` per job (tzdata dep) | a real consumer needs local-time schedules |
| Month/DOW names in cron exprs | a consumer asks; numeric-only until then |
| Store lease callback (multi-node) | the stack runs distributed BEAM |
| New hooks | a second real consumer asks for the same intervention point |
| `overlap: :queue` | a consumer needs serialized backlog semantics |
| Dashboard drill-down (per-job run history page) | needs upstream section type; declarative page proves insufficient |
| Upstream contribution of the package itself | a third external project adopts it |

# genswarms-objects

> Surfacing a package in the swarm dashboard? The full three-channel contract
> (display wire, metrics allowlist, `dashboard_extension/1`) lives in
> [INTEGRATING.md](INTEGRATING.md).

Utility object handlers for [genswarms](https://github.com/genlayerlabs/genswarms)
swarms — one lockstep monorepo, four swarmidx packages (`kind: handler`):

| Package | Object | What it does |
|---|---|---|
| `cron` (`packages/cron`) | `Genswarms.Cron` | Deterministic global scheduler: a job = one schedule + one stamped message to one **allowlisted** target. One-shot, fixed-rate, and cron-expression schedules; in-place schedule updates; deterministic occurrence IDs; declarative seed_jobs; consecutive-failure breaker. Trust-gated sources, retry/backoff, bounded concurrency, persistence via injectable store. |
| `browser` (`packages/browser`) | `Genswarms.Browser` | Web browser for agents: render/click/type/back with compact replies. Two modes — **allowlist** (fail-closed) or **denylist** (allow any public host except a blocklist; requires deployment-provided IP-filtering egress proxy for sub-resource SSRF containment). Note: `browse@0.1.1` is the old name's final release; use `browser@≥0.1.0`. |
| `metrics` (`packages/metrics`) | `Genswarms.Metrics` | Fire-and-forget counters: closed key allowlist (a prompt-injected agent can't mint unbounded keys), in-memory totals, immediate retry-safe UTC-day persistence with a compatible store. |
| `tips` (`packages/tips`) | `Genswarms.Tips` | Rotating-content dispenser: per-recipient no-repeat rotation over fragment pools (configurable rotating + weighted-dressing slots), seeded deterministic `draw`/`commit` (a retried send reproduces the same message), pending→live→retired content lifecycle, injectable store. Makes no trust decisions — recipient selection and consent belong to the caller. |

Extracted from wingston-rally-bot (browse, metrics) and micro-markets (cron) —
the duplication these repos carried before the registry existed.

## Conventions (all four)

- **Config is pure data.** Module refs (`store_mod`/`store`/`events_mod`) arrive
  as atoms (Elixir defs) or strings (JSON IR); strings resolve via
  `to_existing_atom` — no atom minting, unknown module ⇒ treated as absent.
- **Stores are optional seams, fail-open.** Without one: cron jobs and metric
  totals live in memory (don't survive restarts); every store call is guarded
  with `function_exported?`, so partial implementations are fine.
- **Allowlists are fail-closed.** Cron ships with EMPTY `trusted_sources` /
  `allowed_targets` — nobody can create jobs and no target is deliverable until
  the host declares them. Browse only fetches hosts on its allowlist file.
- **No compile dep on the engine.** ObjectHandler callbacks by convention;
  `Genswarms.Objects.ObjectServer` delivery is a runtime-only call (the one
  expected compile warning).
- Display telemetry rides `Application.get_env(:genswarms_objects, :display_wire,
  [:genswarms, :display])` — hosts with an existing wire name ([:wingston,
  :display]) set that env.

## Store contracts

- **cron**: `load_cron_jobs(states)`, `max_cron_job_id()`, `save_cron_job(job)`,
  `save_cron_run(job, result)` — see the "Store seam contract" section in
  `.claude/skills/genswarms-cron-use/SKILL.md` for the load-bearing arg/return
  shapes (atom-keyed rows, the JSON round-trip, callback failure semantics);
  `Genswarms.Cron.Store` (packages/cron/store.ex) mirrors it as an optional
  `@behaviour` for compiler drift-checking.
- **metrics**: `add_metrics_batch(batch_id, day, deltas)` returns `:ok` after
  atomically deduplicating the opaque string ID and incrementing every delta, or
  `{:error, reason}`. `day` is a UTC `Date`; deltas have allowlisted string keys
  and positive integer values. Retrying an ID must never increment twice. IDs must
  remain deduplicated for as long as retries are possible. `today_metrics()` returns
  today's map; read failures should return an error/nil or raise, never a fake empty map.
  Bumps write immediately; failures retry with the same ID/day/payload on the next
  bump or timer. Later bumps coalesce per UTC day behind the immutable failed batch.
  Successfully written counts survive restarts; **pending writes remain in memory
  and can be lost on restart during an outage**. Buffers grow per outage day, not
  per bump, with no day cap; a durable outbox is needed for outage crash recovery.
  Snapshot `persistence.status` is `persisted`, `pending`, `best_effort` (legacy),
  or `memory_only`; `last_error` is `write_failed` until a write succeeds.
  Existing `add_metrics(pending_map)` stores keep periodic best-effort writes;
  only `:ok` clears pending, but their retries may duplicate partial writes and
  cannot guarantee event-day assignment. Upgrade the callback for those guarantees.
- **tips**: `load_fragments()`, `load_seen()`, `save_fragment(fragment)`,
  `save_fragment_status(id, status)`, `add_seen(recipient_id, ids)`,
  `replace_seen(recipient_id, keep_ids)` — all optional, memory-only without
  a store.
- **cron events** (optional `events_mod`): `object(:cron, event_type, message, opts)`
  — e.g. a LogStore wrapper; absent → Logger.

## Verification

```sh
mix deps.get
./checks/run.sh   # cron (mm suite), browse ×3 (wingston suites), metrics, tips — no store, no network
```

## Consuming

One mix dep gives all four (`{:genswarms_objects, github: "genlayerlabs/genswarms-objects", tag: "vX.Y.Z"}`);
each is notarized independently in swarmidx (`swarmidx:genlayerlabs/cron@…`, `…/browse@…`,
`…/metrics@…`, `…/tips@…`) with the dirhash covering exactly its `packages/<name>` dir
(NOT the repo-level `checks/` tests). One repo tag ships all four directories
in lockstep — but the four **package versions** advance independently: a repo
tag that only touched `cron` still gets published as a new `cron@X.Y.Z` with
`browse`/`metrics`/`tips` republished unchanged at their prior version. There
is no in-repo file mapping package version → repo tag; see CHANGELOG.md for
the reconstructed history (design doc §8 is the versioning policy, not a
version ledger).

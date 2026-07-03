# genswarms-objects

Utility object handlers for [genswarms](https://github.com/genlayerlabs/genswarms)
swarms — one lockstep monorepo, three swarmidx packages (`kind: handler`):

| Package | Object | What it does |
|---|---|---|
| `cron` (`packages/cron`) | `Genswarms.Cron` | Deterministic global scheduler: a job = one due datetime + one stamped message to one **allowlisted** target. One-shot, fixed-rate, and cron-expression schedules; declarative seed_jobs; consecutive-failure breaker. Trust-gated sources, retry/backoff, bounded concurrency, persistence via injectable store. |
| `browse` (`packages/browse`) | `Genswarms.Browse` | Allowlist-capped web browser for agents (render/click/type/back). Compact replies by default (head + nav-link index — the full page never re-enters agent context unless asked); off-cage redirect containment (re-gate on settle, session destroyed on escape). |
| `metrics` (`packages/metrics`) | `Genswarms.Metrics` | Fire-and-forget counters: closed key allowlist (a prompt-injected agent can't mint unbounded keys), in-memory totals, periodic flush to an injectable durable store. |

Extracted from wingston-rally-bot (browse, metrics) and micro-markets (cron) —
the duplication these repos carried before the registry existed.

## Conventions (all three)

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
  `save_cron_run(job, result)`.
- **metrics**: `add_metrics(pending_map)`, `today_metrics()`.
- **cron events** (optional `events_mod`): `object(:cron, event_type, message, opts)`
  — e.g. a LogStore wrapper; absent → Logger.

## Verification

```sh
mix deps.get
./checks/run.sh   # cron (mm suite), browse ×3 (wingston suites), metrics — no store, no network
```

## Consuming

One mix dep gives all three (`{:genswarms_objects, github: "genlayerlabs/genswarms-objects", tag: "vX.Y.Z"}`);
each is notarized independently in swarmidx (`swarmidx:genlayerlabs/cron@…`, `…/browse@…`,
`…/metrics@…`) with the dirhash covering exactly its `packages/<name>` dir. Lockstep
versioning: one tag versions the three (design doc §8).

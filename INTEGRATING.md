# Integrating a package with the swarm dashboard

Every genswarms package can surface itself in the subzero-swarm dashboard
through **three independent channels**. None is required; each is inert until a
host wires it. This is the contract a new package follows — previously it was
scattered across three repos' code comments, which is how integrations drifted.

## Channel 1 — the display wire (live canvas + story)

Emit one `:telemetry.execute` per user-visible fact:

```elixir
:telemetry.execute(
  Application.get_env(:genswarms_objects, :display_wire, [:genswarms, :display]),
  %{},
  %{kind: :my_kind, agent: from, whatever: "fields"}
)
```

Rules:

- **Topic comes from app env**, key `:display_wire`, default `[:genswarms, :display]`.
  Packages in THIS repo read the `:genswarms_objects` application.
  **`genswarms-llm-proxy` deliberately reads its own `:genswarms_llm_proxy` app env**
  — a host redirecting the wire (e.g. onto `[:wingston, :display]`) must set
  **both** app envs. Forgetting the second one is the classic silent miss
  (check every boot entrypoint: hosts often have more than one, e.g.
  `run_live.exs` *and* `docker/container_boot.exs`).
- Metadata is a flat map with a `kind:` atom plus the kind's documented fields.
  Values must be JSON-safe-able (the host collector stringifies atoms and
  bounds anything else).
- **Emitting must never take the package down.** Wrap the execute in
  `rescue`/`catch :exit` (see `packages/cron/cron.ex` `emit_display/1`).
  Telemetry contains raising *handlers* on its own, but the emit site should
  still be armored — display is decoration, never load-bearing.
- **Kinds are additive and consumers ignore unknown ones**, so a new kind is
  always safe to ship. But an *unknown* kind renders as a generic `· kind event`
  row and animates nothing. To be a first-class citizen, register it in the two
  vocabulary sources:
  - the host registry table: wingston `objects/event_feed.ex` moduledoc;
  - the dashboard's machine-readable mirror:
    `SubzeroSwarmDashboard.Story.Kinds` (genswarms-dashboard `frontend/`) —
    its parity tests then force the reducer, the Events filter and the canvas
    JS to keep up. **Renaming a kind requires delegation shims in the reducer
    AND `assets/js/hooks/pipeline.js`** — the browse→browser rename shipped
    with only the Elixir side and the canvas went silently blind.

## Channel 2 — metrics (durable daily counters)

The metrics object accepts `{"action":"bump","key":K,"n":N}` messages but
enforces a **closed key set** (`packages/metrics/metrics.ex` `@known_keys`).
A package introducing a new counter does NOT edit that set — the **host**
allowlists it:

```elixir
# host swarm config, metrics object opts
extra_keys: ["my_pkg_thing_total", "my_pkg_thing_ok"]
```

Never mint per-entity keys (`thing_<id>`) — the closed set exists to keep the
store bounded. Per-entity curation goes in a bounded host store table instead
(precedent: `browse_hosts` in wingston, deliberately NOT a metrics key).

## Channel 3 — `dashboard_extension/1` (probed data pages)

Export this and the host will probe it (`function_exported?` + `rescue`) when
building each dashboard snapshot:

```elixir
@doc "Dashboard extension (schema 1). Inert without a store."
def dashboard_extension(opts \\ []) do
  store = Keyword.get(opts, :store_mod)
  if is_nil(store), do: %{}, else: %{"my_key" => summary, "dashboard_pages" => [page]}
end
```

- **`:store_mod` is the canonical opt name** for the store module (cron,
  llm-proxy, tips ≥ 0.1.4). Return `%{}` when it's absent — never raise.
- Pages follow the generic page/section grammar — `GenswarmsDashboard.Extensions`
  moduledoc (genswarms-dashboard `backend/`) is the schema reference; current
  schema is **1**. Pages merge across providers first-`id`-wins.
- The host probe contains **crashes only** — a malformed-but-non-raising map
  flows straight to the renderer. Return a well-formed map or `%{}`; there is
  no validator downstream to save you.
- This channel is optional: metrics and browser expose no extension at all and
  are fully integrated via channels 1–2.

## Machine blocks + health_rules (observability contract)

`dashboard_extension/1` can also return a **machine block**: a top-level key
in the returned map, sibling to `"dashboard_pages"`, meant for machine
consumers (an observer, wingston) rather than the human-facing page renderer.
Convention, not a validated schema:

- Versioned: `"v" => 1`.
- Numeric where the page version is display-formatted: times are **ms
  integers**, never display strings like `"cron 12:00"` or `"every 60s"` —
  that formatting lives only in the page's `table` rows (see `job_row/1` vs
  `machine_job/1` in `packages/cron/cron.ex`).

A package may additionally ship `"health_rules"` **inside its own block**.
The idea: whoever owns the failure mode declares how to detect it — the
package knows what "stuck" or "over budget" means for its own data far
better than a generic external watcher would — and ships that as pure
declarative data alongside the numbers. Something else evaluates it.

Cron's block (`packages/cron/cron.ex`, `dashboard_extension/1`, built from
the `@health_rules` module attribute) looks like:

```elixir
%{
  "cron" => %{
    "v" => 1,
    "jobs" => [%{"name" => "...", "next_run_at_ms" => 1780982400000,
                 "last_run_at_ms" => 1780982340000, "state" => "active",
                 "consec_failures" => 0}, ...],
    "health_rules" => [
      %{"id" => "missed_tick", "severity" => "warn", ...},
      %{"id" => "job_failing", "severity" => "warn", ...}
    ]
  }
}
```

The two shipped rule ids are `missed_tick` (an active job overdue past a
30-minute grace baked into the rule) and `job_failing` (a job at or past 5
consecutive failures) — see `@health_rules` in `packages/cron/cron.ex` for
the exact predicate shape.

**Caveat: this data is inert today.** There is no observer in this repo (or
anywhere yet) that reads `health_rules` and evaluates it — no generic rule
evaluator exists. Until a host wires one up, `health_rules` is just JSON
sitting in the dashboard extension, same as any other unread field. Treat it
like Channel 1/2/3: shipping it is free and safe, but it does nothing on its
own.

## Testing your integration

- Display emits: live telemetry-attach test, not a source grep. Helper:
  `checks/support/display_wire_helper.exs`; reference tests:
  `checks/metrics_display_test.exs` here and
  `checks/llm_proxy_display_events_test.exs` in genswarms-llm-proxy
  (default topic + host override + raising-handler tolerance).
- Extension shape: assert the inert `%{}`, the page shape, and bad-store
  tolerance (see `checks/cron_dashboard_test.exs`, `checks/tips_dashboard_test.exs`).

## New-package checklist

1. Emit display facts via the app-env wire (armored, `kind:` + fields).
2. Register new kinds in both vocabulary sources (host table + `Story.Kinds`).
3. New counters → tell the host to add `extra_keys`; nothing per-entity.
4. Optional `dashboard_extension/1` with `:store_mod`, inert `%{}` default.
5. Live emit test + extension shape test in `checks/`.

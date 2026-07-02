---
name: genswarms-metrics-use
description: >-
  Wire the Genswarms.Metrics counters object: fire-and-forget bumps from other
  objects, closed key allowlist, periodic flush to an injectable store. Use
  when adding operational counters to a swarm or debugging "bump ignored"
  (key not in allowlist) or counters resetting on restart (no store).
---

# Genswarms.Metrics — using the counters object

## Wiring

```elixir
%{name: :metrics, handler: Genswarms.Metrics, config: %{
  flush_ms: 300_000,
  store: MyApp.MetricsStore,   # optional: add_metrics/1 + today_metrics/0
  extra_keys: ["my_app_event"]  # extends the closed baseline set (still closed)
}}
```

Bump from any connected object: `{"action":"bump","key":"reply_sent","n":2}`.
`{"action":"status"}` returns totals (boot session), pending, and today's
durable counters when a store is present.

## The allowlist is the point

Keys are a CLOSED set — a prompt-injected agent must not be able to mint
unbounded keys (metric amplification). Extend via config `extra_keys` (a declared list — still a closed set), never by
loosening the check.

## Gotchas

- Without `store`: totals live for the boot session only (memory), flush is a
  no-op — that's the documented dev mode, not a bug.
- Bumps are fire-and-forget by design: a metrics outage never blocks a sender.

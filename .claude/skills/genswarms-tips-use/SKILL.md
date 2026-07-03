---
name: genswarms-tips-use
description: >-
  Wire the Genswarms.Tips rotating-content dispenser: fragment pools assembled
  per recipient (no-repeat rotating slots + weighted dressing slots), seeded
  deterministic draw/commit, pending->live->retired lifecycle, injectable
  store. Use when adding rotating outbound copy (daily tips, onboarding
  nudges, rotating campaign angles) to a swarm, or debugging "empty_pool"
  replies or repeated content after a restart (no store).
---

# Genswarms.Tips — using the rotating-content dispenser

## Wiring

```elixir
%{name: :tips, handler: Genswarms.Tips, config: %{
  # ordered slots; rotate: true = seen-tracked no-repeat, rotate: false = weighted dressing
  template: [
    %{kind: "opener", rotate: false},
    %{kind: "body",   rotate: true},
    %{kind: "closer", rotate: false}
  ],                        # this IS the default — omit unless customizing
  salt: "tips-v1",          # seed component; change to reshuffle everyone
  reshuffle_guard: 20,      # ids kept on cycle-complete reshuffle
  store: MyApp.TipsStore    # optional; memory-only (dev mode) without it
}}
```

## The caller contract (draw → send → commit)

```
{"action":"draw","recipient_id":"tg:1:0","date":"2026-07-03"}
  -> {"ok":true,"text":"Coo coo: Tip body. Fly high.","fragment_ids":["a1b2..."]}
send the text (your transport, your consent gates)
{"action":"commit","recipient_id":"tg:1:0","fragment_ids":["a1b2..."]}
  -> {"ok":true,"reshuffled":false}
```

- `draw` is a PURE seeded read: same (recipient, date) => the same message,
  so a crash between draw and send retries identically. It marks nothing.
- `commit` only after a delivery ATTEMPT (sent or failed) — the same
  mark-after-attempt discipline as roster-style targeting.
- The object makes NO trust decisions: recipient selection, consent, opt-out,
  and rate limits are YOUR job before draw. Keep it topology-internal, not
  agent-callable.

## Content lifecycle

```
{"action":"add_fragments","fragments":[{"kind":"body","text":"...","category":"hooks","weight":1}]}
   -> always lands "pending" (ids are content-addressed: re-adding = no-op)
{"action":"promote","ids":[...]}   # pending -> live (the only drawable status)
{"action":"retire","ids":[...]}    # any -> retired; never deleted, stays in seen
{"action":"stats"}                 # pool sizes by kind/status + recipient count
```

## Store seam (all callbacks optional)

    load_fragments() :: [fragment_map]           # full pool at boot
    load_seen()      :: %{recipient => [id]}     # oldest-first per recipient
    save_fragment(fragment_map)                  # upsert by :id
    save_fragment_status(id, status)
    add_seen(recipient_id, ids)                  # upsert rows at now()
    replace_seen(recipient_id, keep_ids)         # reshuffle: delete the rest

## Gotchas

- Without `store`: pools and seen-state live for the boot session only — the
  documented dev mode, not a bug. Rotation resets on restart.
- `empty_pool` means a `rotate: true` slot has ZERO live fragments — promote
  something. Missing dressing kinds degrade silently (no opener/closer).
- Pool of 1 rotating fragment: repeats are allowed (starvation beats silence).
- `date` is a seed component, not parsed — pass a stable per-send day string;
  passing timestamps would defeat retry determinism.
- Templates with MULTIPLE `rotate: true` slots share one union coverage
  threshold for the exhaustion reshuffle, and two rotating slots of the same
  kind can pick the same fragment twice in one draw — v0.1.3 is designed
  around a single rotating slot.

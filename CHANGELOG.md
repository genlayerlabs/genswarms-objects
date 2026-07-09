# Changelog

This repo is one lockstep monorepo (one git tag ships all four package
directories together) but the four swarmidx packages are **published
independently** — a tag that only changed `cron` still republishes
`browse`/`metrics`/`tips` unchanged at their prior version. There was no
in-repo record of "package version → repo tag" before this file (arch
review M-9); the entries below were reconstructed from `git log`/`git tag`
and cross-checked against known consumer pins (wingston-rally-bot's
`wingston.swarm.exs`) — see the note on each entry for how confident the
mapping is. Repo tags run `v0.1.0`…`v0.1.5` as of this writing; package
versions do not track them 1:1.

## cron (`packages/cron`, module `Genswarms.Cron`)

### 0.2.6 - 2026-07-07

Additive machine block for the dashboard-extension observability contract
(observability v2 stages 2–4, task 1) — no change to `dashboard_pages` or
any other existing key.

- `dashboard_extension/1` now also returns `"cron" => %{"v" => 1, "jobs" =>
  [...], "health_rules" => [...]}` alongside the existing `"dashboard_pages"`
  page. Each job entry carries `name`, `next_run_at_ms`/`last_run_at_ms`
  (Unix ms integer or `nil` — never the display-formatted strings the human
  page uses), `state`, `consec_failures` — read from the same durable
  `safe_load_jobs/1` list the page already renders.
- Two rules ship as pure data (`@health_rules`): `missed_tick` (an active
  job overdue past a 30-minute grace embedded in the rule) and
  `job_failing` (5+ consecutive failures). Consumed by a separate
  observer-side generic rule evaluator — operators tune grace/thresholds
  via observer-side operator rules, not by editing this package.
- `dashboard_extension()` without a store is still `%{}`.

### 0.2.2 — repo tag `v0.1.6` (2026-07-03, branch `feat/cron-0.2.2`)

Absorbs the architecture review (`cron-arch-review.md`) and the audit's
previously-deferred findings. No public-contract break; every existing
vector stays green.

- **Wave 1 (refactor, no behavior change):** extracted `Genswarms.Cron.Job`
  (`packages/cron/job.ex`) — the pure job-lifecycle state machine
  (claim/finish/complete/exhaust/resume-misfire/recover/load-misfire) — out
  of `cron.ex`, mirroring the `tips_core.ex`/`browse_core.ex` core-shell
  convention (arch I-1).
- **Wave 2 (behavior):**
  - Opt-in `"once": true` on `create_job` consults terminal store rows by
    `dedupe_key` the way seeds do — "at most once ever" instead of the
    default "at most one live" (arch I-4).
  - New `run_now` action: trusted-gated, fires an **active** job
    immediately through the normal claim→deliver→finish path, re-arming
    recurring jobs from the fired occurrence rather than the old
    `next_run_at`.
  - New `:job_run_failed` / `:job_breaker_paused` events via `events_mod`.
  - Trusted sender + decoded JSON + unrecognized action now replies
    `{ok:false,error:"unknown_action"}` instead of a silent drop (arch M-5).
  - `list` rows gain `schedule` and `dedupe_key` (arch M-4).
  - Dead `sender`/`runtime` config keys removed (arch M-1).
  - `origin` is now free-form scalar provenance (no more key whitelist);
    `context_from` removed entirely — it was write-only (arch M-2).
  - `allowed_targets` misconfiguration now raises a descriptive
    `ArgumentError` at boot instead of an opaque `String.to_existing_atom`
    crash (arch M-6).
  - `handle_info(:tick)` returns `{:noreply, state}`; the message-path tick
    still replies. Shared core (arch M-7).
  - Busy-spin fix: the re-arm timer no longer schedules a 0ms retry when
    all task slots are saturated (audit M1).
  - Inbound message size cap (`max_message_bytes`, default 65536): oversized
    trusted messages get `{ok:false,error:"message_too_large"}`, untrusted
    ones are dropped silently (audit M2).
  - `Task.async` exits are now trapped so the existing `:DOWN` handler is
    reachable instead of dead code (audit M3).
  - String job ids from the store or inbound messages are coerced/validated
    consistently (audit M6).
  - `interface/0` now declares all 8 actions (`create_job`/`pause`/`resume`/
    `delete`/`tick`/`list`/`status`/`run_now`) with neutral examples instead
    of 2 of 7 with micromarkets-era vocabulary (arch I-5).
  - Minor: dead `field/3` branch removed, the search-window comment
    corrected to "1831 days", a direct vector added for the exact-`now`
    schedule boundary (audit I5).
- **Wave 3 (docs only):** store seam contract section, honest
  delivery paragraph, create-envelope documentation, this changelog, the
  README versioning-wording fix, a `Genswarms.Cron.Store` doc-only
  behaviour module, and the vixie `*/n` non-star-base note in
  `cron_expr.ex`.
- **Review fix pass (post whole-branch review):**
  - Non-boolean `once` is rejected (`once must be a boolean`) instead of
    silently degrading to live-only dedupe; `once: true`'s `store_mod`
    dependency is documented (memory-only wiring degrades to live-only).
  - `run_now` respects `max_concurrency` — at saturation it replies
    `{ok:false,error:"at max concurrency"}` instead of stacking tasks.
  - Schedule/floor/payload validation now runs **before** the once-terminal
    dedupe lookup, so a garbage schedule is rejected rather than masked by
    `deduped: true`; only the past-guard is skipped on a dedupe hit.
  - Vector 5b advances the clock before `run_now` so re-arm-anchor
    regressions are detectable; documented that `run_now` permanently
    re-phases `every_ms` jobs while cron-kind jobs stay on their absolute
    grid; documented `origin`. All fix-pass behaviors pinned by permanent
    vectors (negative-checked against the pre-fix code).

### 0.2.1 — repo tag `v0.1.5` (2026-07-03, PR #5 `fix/cron-audit-hardening`)

Six audit-hardening fixes, confirmed as `cron@0.2.1` by wingston-rally-bot's
pin (`wingston.swarm.exs`, per operator record):

- An operator `pause` issued while an occurrence is in flight survives the
  task result instead of being clobbered on completion (I1).
- `resume` only acts on **paused** jobs — resuming a running job used to
  double-fire it (I2).
- A poisoned/corrupt stored schedule no longer crashes boot or completion
  (I3).
- One-shot seeds no longer re-fire on every restart — the terminal-dedupe
  guard this 0.2.2 release generalizes to runtime `create_job` (I4).
- `skip` misfire policy is honored on ordinary downtime at load, not just
  on manual resume (I5).
- Non-scalar `create_job` string fields (`target`, `message.action`, etc.)
  are rejected, not coerced — silent coercion could crash the object or
  mint surprising names (I6).
- Plus a follow-up: load-misfire's no-next-occurrence branch now records
  `last_error` instead of silently parking the job (3bab147), and
  `SKILL.md`/moduledoc accuracy fixes (96b2469).

### 0.2.0 — repo tag `v0.1.2` (2026-07-03, PR #1 `feat/cron-kinds-seeds`)

Confirmed as `cron@0.2.0` by wingston-rally-bot's pin, per operator record.

- Three schedule kinds: one-shot `run_at`, fixed-rate `every_ms`, 5-field
  UTC `cron` expressions (vixie semantics, numeric-only) — new
  `cron_expr.ex`/`schedule.ex` modules with the grid rule pinned in one
  function.
- Consecutive-failure breaker (`breaker_threshold`, `paused_by: "breaker"`).
- Misfire policy (`skip`/`coalesce`) on resume and crash-recovery.
- Declarative `seed_jobs` (upsert-by-`dedupe_key` at init, raise-on-invalid,
  terminal-aware for one-shots) and a load-time upgrade shim for bare
  0.1.1-era persisted schedules (`run_at_ms` with no `kind`).
- `list` rows gain `kind` and `paused_by`.

### 0.1.1 — repo tags `v0.1.0`→`v0.1.1` (2026-07-02)

Initial extraction from micro-markets. A job was a bare one-shot due
timestamp (`run_at_ms`, no schedule "kind") plus a stamped message to one
allowlisted target; `store_mod`/`events_mod` optional seams; fail-closed
empty `trusted_sources`/`allowed_targets` defaults. `v0.1.1` added the
`swarm-object.json` entry-file manifest (module/compile-order declaration)
— no behavior change. Package version inferred: this is the pre-kinds
scheduler the 0.2.0 load-time upgrade shim (`upgrade_schedule/1`,
`cron.ex`) exists to stay compatible with; not independently confirmed by
a consumer pin (wingston adopted at 0.2.1 or later).

## browse (`packages/browse`, module `Genswarms.Browse`)

Renamed to `packages/browser` (module `Genswarms.Browser`, published as
`genlayerlabs/browser`) with the denylist-mode work; new entries continue
under this section with the new name.

### browser 0.2.0 — 2026-07-09 (branch `feat/browser-allow-sync`)

Runtime allowlist grants: a new object-to-object `allow_sync` action
(deliberately absent from the agent-facing `interface/0`) lets senders
listed in the new `grant_sources` config extend the allow set live —
`{"action":"allow_sync","hosts":[...],"meta":{...}}` → hosts re-pass a
package-side sanity floor (`Core.grantable_host?/1`: bare dotted DNS names
only — no IP literals, `localhost`, `.local`/`.internal`), union into the
allow policy + renderer cage, and persist through the new injectable
`grants_store` seam (`load_grants/0`, `save_grant/2`; tips/cron store
idiom). Boot allowset = file floor ∪ stored grants (store load re-applies
the floor; a raising store falls back to file-only). `grant_sources`
absent/empty = action disabled (full back-compat); denylist mode accepts +
persists grants but leaves the deny policy untouched (noted in the reply).
Store write failure keeps the grant in-memory, loudly. Each applied grant
emits a `:browser_grant` display event. `meta` is opaque provenance — this
package still never learns what a campaign is.

### 0.1.1 — repo tags `v0.1.0`→`v0.1.1` (2026-07-02)

Extracted from wingston-rally-bot: allowlist-capped web browser for agents
(render/click/type/back), compact replies by default, off-cage redirect
containment. Confirmed as `browse@0.1.1` by wingston-rally-bot's pin. No
further commits have touched `packages/browse` since (only the `v0.1.1`
manifest-file commit), so the package version has not advanced past 0.1.1
even though the repo tag has (`v0.1.5` as of this writing).

## metrics (`packages/metrics`, module `Genswarms.Metrics`)

### 0.1.1 — repo tags `v0.1.0`→`v0.1.1` (2026-07-02)

Extracted from wingston-rally-bot: fire-and-forget operational counters,
closed key allowlist (`extra_keys` config, still a closed set), periodic
flush to an injectable store. Confirmed as `metrics@0.1.1` by
wingston-rally-bot's pin. No further commits have touched
`packages/metrics` since (only the `v0.1.1` manifest-file commit).

## tips (`packages/tips`, module `Genswarms.Tips`)

### 0.1.1 — repo tag `v0.1.4` (2026-07-03, PR #4 `feat/tips-echo`)

First published version, per the commit message itself (`f701303`, "tips
0.1.1: echo recipient_id/date in draw and commit replies") and operator
record. Bundles everything merged up to and including this PR:

- Rotating-content dispenser: content-addressed fragments, seeded
  deterministic `draw`/`commit` (a retried send reproduces the same
  message), pending→live→retired lifecycle, per-recipient no-repeat
  rotation (`Tips.Core`, PR #2 `feat/tips-package`, repo tag `v0.1.3`).
  That PR's own commit messages/title reference "v0.1.3" — read here as the
  repo tag, not an independently-published tips version; no evidence tips
  was published to swarmidx before the echo release.
- Template-rotate coercion + config guard fix, README four-package
  consistency pass (`33b8c60`).
- `draw`/`commit` replies echo `recipient_id`/`date` (the feature this
  version is named for).

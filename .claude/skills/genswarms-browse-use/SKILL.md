---
name: genswarms-browse-use
description: >-
  Wire the Genswarms.Browse object: allowlist-capped web browsing for agents
  (render/click/type/back), compact replies that keep pages OUT of agent
  context, off-cage redirect containment. Use when giving agents web access,
  or debugging "denied_not_allowlisted", "render_failed {:open_failed,_}"
  (agent-browser binary missing), or context bloat from full pages.
---

# Genswarms.Browse — using the browser object

## Wiring

```elixir
%{name: :browse, handler: Genswarms.Browse, config: %{
  allowlist_path: "config/browse_allowlist.txt",  # one host per line — fail-closed
  head_chars: 2000,          # compact reply size
  session_ttl_ms: 120_000
  # renderer/resolver/fetcher injectable for tests; default renderer drives
  # the `agent-browser` CLI (must be on PATH); curl via GENSWARMS_CURL_BIN/PATH
}}
```

## The containment model (don't weaken it)

- Only `https://` URLs on allowlisted hosts are fetched/rendered.
- **Re-gate on settle**: a client-side redirect landing OFF the allowlist
  destroys the session (never reused) — pinned by checks/browse_regate_settle.
- **Compact replies by default**: head of main body + nav-link index + size.
  The agent asks `{"full":true}` only to have the full body written to ITS OWN
  workspace file (it greps there) — the page never re-enters conversation
  context. This is the context-bloat fix; don't return full pages inline.

## Gotchas

- `render_failed {:open_failed, ""}` → the `agent-browser` CLI is not on PATH
  (the default renderer shells out to it). Inject a renderer or install it.
- Display telemetry rides the `:genswarms_objects, :display_wire` app env
  (default [:genswarms, :display]) — set it to your host's wire name if your
  EventFeed listens elsewhere.

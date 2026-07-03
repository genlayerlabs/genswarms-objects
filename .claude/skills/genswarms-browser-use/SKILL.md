---
name: genswarms-browser-use
description: >-
  Wire the Genswarms.Browser object: web browser for agents with two modes
  (allowlist fail-closed, or denylist allow-any with IP-filtering proxy).
  Render/click/type/back with compact replies that keep pages OUT of agent
  context. Use when giving agents web access, or debugging containment issues.
  Denylist mode requires a deployment-provided IP-filtering egress proxy for
  sub-resource SSRF containment.
---

# Genswarms.Browser — using the browser object

## Wiring

```elixir
# Allowlist mode (fail-closed, default)
%{name: :browser, handler: Genswarms.Browser, config: %{
  mode: :allowlist,
  allowlist_path: "config/browser_allowlist.txt",  # one host per line — fail-closed
  head_chars: 2000,          # compact reply size
  session_ttl_ms: 120_000
  # renderer/resolver/fetcher injectable for tests; default renderer drives
  # the `agent-browser` CLI (must be on PATH); curl via GENSWARMS_CURL_BIN/PATH
}}

# Denylist mode (allow-any except blocklist; requires IP-filtering proxy)
%{name: :browser, handler: Genswarms.Browser, config: %{
  mode: :denylist,
  blocklist_path: "config/browser_blocklist.txt",  # one host per line to deny
  proxy_url: "http://proxy.internal:8080",  # required: deployment-provided IP-filtering egress proxy
  head_chars: 2000,
  session_ttl_ms: 120_000
}}
```

## The containment model (don't weaken it)

### Allowlist mode (default — fail-closed)
- Only `https://` URLs on allowlisted hosts are fetched/rendered.
- **Re-gate on settle**: a client-side redirect landing OFF the allowlist
  destroys the session (never reused) — pinned by checks/browser_regate_settle.
- **Compact replies by default**: head of main body + nav-link index + size.
  The agent asks `{"full":true}` only to have the full body written to ITS OWN
  workspace file (it greps there) — the page never re-enters conversation
  context. This is the context-bloat fix; don't return full pages inline.

### Denylist mode (allow-any except blocklist)
- Allows `https://` URLs to any public host except those in `blocklist_path`.
- **Requires IP-filtering egress proxy** (`proxy_url` config): the proxy must
  intercept and deny requests to internal / reserved IPs (10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 127.0.0.0/8, etc.) to prevent sub-resource SSRF (agent-initiated
  fetch of internal databases, cloud metadata, etc.). The proxy is YOUR responsibility.
- **Compact replies** work identically: agent gets head + nav index, can request
  full body to its workspace file.

## Gotchas

- `render_failed {:open_failed, ""}` → the `agent-browser` CLI is not on PATH
  (the default renderer shells out to it). Inject a renderer or install it.
- **Denylist mode without proxy**: traffic to internal IPs is NOT blocked by the
  browser itself — a missing or misconfigured proxy will expose your internal
  networks. Test your proxy (e.g. `curl -x http://proxy:8080 http://192.168.1.1`)
  before enabling denylist mode in production.
- Display telemetry rides the `:genswarms_objects, :display_wire` app env
  (default [:genswarms, :display]) — set it to your host's wire name if your
  EventFeed listens elsewhere.

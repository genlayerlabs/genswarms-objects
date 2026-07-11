defmodule Genswarms.Browser do
  @moduledoc """
  Allowlist-capped web browser for the isolated agent. The agent drives a real
  (persistent) browser session through five actions — `render` (navigate to a URL),
  `click` (a ref from the latest snapshot), `back`, `type` (fill a field by ref),
  `press` (a key). The reply is COMPACT by default — `{"url":…,"bytes":…,"head":…,
  "links":…,"more":…}` (`more` only when the body was truncated): the start of the page
  body plus the nav-link index, so a browsed page does NOT pile up in the agent's
  conversation history (the accumulated-context bloat that tips the model into the
  empty-tool-call flail). The full accessibility snapshot (refs + absolute link URLs) is
  delivered as `{"url":…,"text":…}` ONLY when the action carries `"full":true` — which the
  agent jq-extracts into a file in its own workspace and greps, keeping the body out of
  context. All page-derived text is wrapped as untrusted.

  This object is the SOLE gate (allowlist + SSRF). `render` pre-gates the URL and
  every redirect hop before the browser is pointed at it. Interactions can navigate
  (the browser cage does NOT stop click-driven top-level navigation), so the landed
  URL after EVERY action is re-gated; on failure the page text is discarded and the
  whole session is destroyed (fail-closed) — the agent gets `{"error":"blocked"}`.

  One session per asker. Each action renders SYNCHRONOUSLY — the object blocks until
  the render returns and replies inline (the agent `ask`s and gets the page back in
  the same turn), so concurrent askers serialize in the object mailbox. Sessions are
  closed after `session_ttl_ms` idle. Refs are only meaningful against the latest
  snapshot, so every action returns a fresh one.
  """
  require Logger
  alias Genswarms.Browser.Core, as: Browse

  # Agent-supplied strings that become CLI argv (System.cmd: no shell, but keep the
  # contract tight anyway): refs are snapshot handles, keys are key/chord names.
  @ref_re ~r/\Ae\d{1,5}\z/
  @key_re ~r/\A[A-Za-z0-9+]{1,32}\z/
  @type_text_max 500

  # L9 (audit 2026-07-02): agent-browser (pinned 0.27.1, confirmed) hoists a `type` text
  # into ITS OWN global CLI flag when the text is a single, whitespace-free token
  # starting with `-` — e.g. text "--json" flips agent-browser's own output to JSON. The
  # audit's originally-suggested `--` argv terminator does NOT stop this (agent-browser
  # ignores it — verified). System.cmd never invokes a shell (Genswarms.Browser.AgentBrowser
  # .cmd/1), so every element of the args list is passed as one exact, unsplit OS argv
  # entry: verb_args(:type, …) (browse_core.ex) hands `text` through WHOLE as a single
  # element, so text WITH internal whitespace ("-- hello world") can never be re-split
  # into separate tokens by the OS or by agent-browser's own arg parser — it lands as one
  # literal string, never a flag. So only a text with NO internal whitespace that starts
  # with `-` is dangerous; REJECT that shape here (no sanitizing — a clear, retryable
  # error back to the agent), before it ever reaches browse_core's argv. Benign text that
  # merely CONTAINS a dash ("self-driving cars") or is multi-word and dash-leading
  # ("-1 apples, please") is allowed through unchanged. \S is ASCII-scoped (no /u): a
  # Unicode space inside the token still matches \S — stricter, so still rejected.
  @flag_shaped_type_re ~r/\A-\S*\z/

  # A compact reply truncates the page's main BODY to a head but KEEPS the nav-link index
  # the renderer appends to the page text under this header (Genswarms.Browser.AgentBrowser.
  # nav_section/2). Splitting on it lets the agent still navigate (the "couldn't reach
  # GenVM" incident was exactly the nav index going missing) while the bulky body stays out
  # of context. Must match that header; the live test (tests/browse_live.exs §3c) pins the
  # string, so any drift fails there.
  @nav_marker "--- Other links on this page"

  # Default allowlist-mode hosts: the GenLayer-family sites (operator request
  # 2026-07-10). www. variants included where the apex 308-redirects to www —
  # the gate is exact-host and re-gates every redirect hop, so without them
  # those defaults would be dead on arrival. Override with config
  # `:default_hosts` (an explicit [] opts out entirely).
  @default_hosts [
    "genlayer.com",
    "docs.genlayer.com",
    "genlayerlabs.com",
    "www.genlayerlabs.com",
    "subzeroclaw.com",
    "genswarms.com",
    "unhardcoded.com",
    "www.unhardcoded.com"
  ]

  @doc """
  The baked-in allowlist-mode default hosts ("tier 0"), normalized and
  sorted — exactly the set `init/1` applies when config `:default_hosts`
  is unset (0.2.2). Public so consumers can DISPLAY the tier (dashboard
  gate pages) without hardcoding a copy. Display-only: the effective
  policy lives in the object's state (file floor ∪ defaults ∪ grants),
  and the kill switch suppresses defaults — a consumer rendering this
  list should mark it as conditional on a live file floor.
  """
  def default_hosts, do: nil |> normalize_default_hosts() |> Enum.sort()

  def init(config) do
    # No :code.priv_dir (objects are Code.require_file'd, there is no :wingston OTP app);
    # configs pass an explicit :allowlist_path/:blocklist_path (Task 6). Env override, then
    # a cwd default. `mode` selects allowlist (default, back-compat) or denylist: in denylist
    # mode there is no global allowed_domains string (the renderer isn't handed a positive
    # list), so allowed_domains is nil and the gate/redirect logic runs off `policy` alone.
    mode = Map.get(config, :mode, :allowlist)

    # Runtime grants (allow_sync): senders listed in :grant_sources may extend the
    # allow set live; absent/empty = the action is disabled (full back-compat).
    # Grants load from the injectable :grants_store at boot and union with the file
    # floor in allowlist mode; a store failure falls back to the file-only floor
    # (fail closed toward the trust anchor). The sanity floor re-applies on load —
    # a store row predating a floor tightening must not resurrect a bad host.
    grant_sources = normalize_grant_sources(Map.get(config, :grant_sources))
    grants_store = module_ref(Map.get(config, :grants_store))
    grants = load_grants(grants_store)

    if MapSet.size(grants) > 0,
      do: Logger.info("browser: #{MapSet.size(grants)} granted host(s) loaded from store")

    # Baked-in default hosts (operator request 2026-07-10): the GenLayer-family
    # sites every allowlist-mode consumer should reach out of the box. The gate
    # is exact-host and re-gates every redirect hop, so the apex→www 308s
    # (genlayerlabs.com, unhardcoded.com) need both spellings listed. Config
    # `:default_hosts` overrides ([] opts out). They EXTEND a live file floor
    # and are suppressed by the kill switch exactly like grants — an emptied
    # allowlist file must still stop ALL browsing. Denylist mode ignores them
    # (there is no positive list to extend).
    default_hosts = normalize_default_hosts(Map.get(config, :default_hosts))

    {policy, allowed_domains, floor_empty} =
      case mode do
        :denylist ->
          path =
            Map.get(config, :blocklist_path) || System.get_env("WINGSTON_BROWSER_BLOCKLIST") ||
              Path.join(File.cwd!(), "config/browser-blocklist.txt")

          case load_hostset(path) do
            {:ok, set} ->
              Logger.info("browser: denylist mode — #{MapSet.size(set)} blocked host(s) from #{path}")
              {{:deny, set}, nil, false}

            {:error, r} ->
              Logger.error("browser: denylist #{path} unreadable (#{inspect(r)}) — FAIL-CLOSED, blocking everything")
              {{:allow, MapSet.new()}, nil, true}
          end

        _ ->
          path =
            Map.get(config, :allowlist_path) || System.get_env("WINGSTON_BROWSE_ALLOWLIST") ||
              Path.join(File.cwd!(), "config/browse-allowlist.txt")

          file_set =
            case load_hostset(path) do
              {:ok, s} -> s
              {:error, _} -> MapSet.new()
            end

          # The FILE is the operator's kill switch: an empty/unreadable floor means
          # NOTHING is reachable — stored grants must not reopen the gate (emptying
          # the file during an incident has to actually stop browsing). The same
          # flag suppresses RUNTIME grants below (apply_grants) AND the baked-in
          # default hosts: defaults only ever EXTEND a live floor.
          if MapSet.size(file_set) == 0 do
            Logger.error("browser: allowlist #{path} empty/unreadable — fail-closed")

            if MapSet.size(grants) > 0,
              do:
                Logger.error(
                  "browser: #{MapSet.size(grants)} stored grant(s) SUPPRESSED — the file floor is the kill switch"
                )

            if MapSet.size(default_hosts) > 0,
              do:
                Logger.error(
                  "browser: #{MapSet.size(default_hosts)} default host(s) SUPPRESSED — the file floor is the kill switch"
                )

            {{:allow, MapSet.new()}, Browse.allowed_domains_arg(MapSet.new()), true}
          else
            Logger.info(
              "browser: allowlist mode — #{MapSet.size(file_set)} host(s) from #{path} + #{MapSet.size(default_hosts)} default(s)"
            )

            set = file_set |> MapSet.union(default_hosts) |> MapSet.union(grants)
            {{:allow, set}, Browse.allowed_domains_arg(set), false}
          end
      end

    renderer = Map.get(config, :renderer, Genswarms.Browser.AgentBrowser)
    if renderer == Genswarms.Browser.AgentBrowser and System.find_executable("agent-browser") == nil,
      do: Logger.error("browse: `agent-browser` not on PATH — render requests will fail with render_failed. Install: brew install agent-browser && agent-browser install")

    {:ok,
     %{
       policy: policy,
       # the --allowed-domains string is passed to the renderer per call (no global state);
       # nil in denylist mode (no positive allowlist to hand the renderer).
       allowed_domains: allowed_domains,
       mode: mode,
       # true when the allowlist file floor was empty/unreadable at boot — the
       # operator kill switch; grants (stored or runtime) never reopen the gate.
       floor_empty: floor_empty,
       grant_sources: grant_sources,
       grants_store: grants_store,
       # granted hosts kept in BOTH modes (denylist persists them ready for a
       # mode flip; they only shape `policy` in allowlist mode).
       grants: grants,
       renderer: renderer,
       resolver: Map.get(config, :resolver, &Browse.resolve_host/1),
       redirect_fetcher: Map.get(config, :redirect_fetcher),
       # host-app-specific, config-driven (keeps this object reusable across bots):
       untrusted_tag: Map.get(config, :untrusted_tag, "untrusted"),
       # backstop cap on delivered page text (chars): a single oversized page (a
       # full-site export / "print everything" dump) would otherwise flood the agent's
       # context. Generic — size only, no per-site knowledge.
       max_text_chars: Map.get(config, :max_text_chars, 40_000),
       # Default replies are COMPACT: the agent gets the first `head_chars` of the page's
       # main body PLUS the nav-link index — not the whole body. This keeps a browsed page
       # OUT of the agent's conversation history (the accumulated-context bloat that tips
       # the model into the empty-tool-call flail). The full body is delivered ONLY when the
       # action carries {"full":true}; the agent redirects THAT to a file in its own
       # workspace and greps it, so the page never re-enters context. See the browse section
       # of skills/wingston-using-objects.md.
       head_chars: Map.get(config, :head_chars, 2_000),
       # Defensive cap on the nav-link index carried in a compact reply (the renderer already
       # caps it at @nav_links_max links, but a pathological page could still be large).
       nav_chars_max: Map.get(config, :nav_chars_max, 4_000),
       session_prefix: Map.get(config, :session_prefix, "browse"),
       # per-asker live browser session: from => %{name, last_used}.
       sessions: %{},
       session_ttl_ms: Map.get(config, :session_ttl_ms, 300_000),
       rate: %{},
       rate_max: Map.get(config, :rate_max, 10),
       render_timeout_ms: Map.get(config, :render_timeout_ms, 45_000),
       now_fn: Map.get(config, :now_fn, fn -> System.monotonic_time(:millisecond) end)
     }}
  end

  def interface do
    %{
      # Default reply is COMPACT: head (start of the body) + links (nav index) + bytes,
      # so the page stays out of your context. Add "full":true to ANY action to get the
      # whole body as "text" — redirect THAT to a file and grep it (see using-objects).
      render: %{
        input: ~s({"action":"render","url":"https://allowed.example.com/path"}),
        output: ~s({"url":"https://allowed.example.com/landed","bytes":18234,"head":"<untrusted>…start of the body…</untrusted>","links":"<untrusted>…- Title — https://……</untrusted>","more":"…how to read the rest with full:true…"})
      },
      render_full: %{
        input: ~s({"action":"render","url":"https://allowed.example.com/path","full":true}),
        output: ~s({"url":"https://allowed.example.com/landed","text":"<untrusted>…WHOLE page; jq -r .result.text into a file & grep…</untrusted>","truncated":"present only if the page exceeded the hard size cap"})
      },
      click: %{
        input: ~s({"action":"click","ref":"e47"}),
        output: ~s({"url":"https://allowed.example.com/where-the-click-landed","bytes":9001,"head":"<untrusted>…fresh snapshot head…</untrusted>","links":"<untrusted>…nav index…</untrusted>"})
      },
      back: %{
        input: ~s({"action":"back"}),
        output: ~s({"url":"https://allowed.example.com/previous","bytes":7200,"head":"<untrusted>…fresh snapshot head…</untrusted>"})
      },
      type: %{
        input: ~s({"action":"type","ref":"e39","text":"search words"}),
        output: ~s({"url":"https://allowed.example.com/same","bytes":5120,"head":"<untrusted>…fresh snapshot head…</untrusted>"})
      },
      press: %{
        input: ~s({"action":"press","key":"Enter"}),
        output: ~s({"url":"https://allowed.example.com/result","bytes":6400,"head":"<untrusted>…fresh snapshot head…</untrusted>"})
      }
    }
  end

  def handle_message(from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "render", "url" => url} = m} when is_binary(url) ->
        do_render(from, url, full?(m), state)

      {:ok, %{"action" => "click", "ref" => ref} = m} when is_binary(ref) ->
        do_act(from, :click, %{ref: ref}, "click #{ref}", full?(m), state)

      {:ok, %{"action" => "back"} = m} ->
        do_act(from, :back, %{}, "back", full?(m), state)

      {:ok, %{"action" => "type", "ref" => ref, "text" => text} = m}
      when is_binary(ref) and is_binary(text) ->
        do_act(from, :type, %{ref: ref, text: text}, "type #{ref}", full?(m), state)

      {:ok, %{"action" => "press", "key" => key} = m} when is_binary(key) ->
        do_act(from, :press, %{key: key}, "press #{key}", full?(m), state)

      # Object-to-object surface, NOT agent-facing (deliberately absent from
      # interface/0): a grant source extends the allow set at runtime.
      {:ok, %{"action" => "allow_sync"} = m} ->
        do_allow_sync(from, m, state)

      {:ok, %{"action" => other}} ->
        {:reply, err("unknown action: #{other}"), state}

      _ ->
        Logger.debug("browse: ignoring non-action message from #{from}")
        {:noreply, state}
    end
  end

  defp do_render(from, url, full?, state) do
    cond do
      over_rate?(from, state) ->
        display(:browser_done, %{agent: from, verdict: "rate_limited"})
        Logger.info("browse: from=#{from} url=#{url} verdict=rate_limited")
        {:reply, err("rate_limited"), state}

      true ->
        # Meter the request BEFORE the network-touching gate (DNS for allowlisted hosts)
        # + redirect resolution (curl HEAD). Previously bump_rate ran only on the success
        # path, so a render that failed the gate/redirect step consumed no budget — an
        # agent could issue unbounded DNS/HEAD egress without ever tripping the limiter.
        state = bump_rate(state, from)

        ropts =
          if state.redirect_fetcher,
            do: [fetcher: state.redirect_fetcher, resolver: state.resolver],
            else: [resolver: state.resolver]

        with :ok <- Browse.gate(url, state.policy, state.resolver),
             {:ok, final} <- Browse.resolve_redirects(url, state.policy, ropts) do
          {sess, state} = ensure_session(from, state)
          r = state.renderer
          ad = state.allowed_domains
          display(:browser_dispatch, %{agent: from, url: url})
          Logger.info("browse: from=#{from} url=#{url} resolved=#{final} verdict=dispatched session=#{sess}")
          deliver(from, "render #{url}", render_sync(fn -> r.navigate(final, sess, ad) end, state), full?, state)
        else
          {:error, {:not_allowed, _}} ->
            display(:browser_done, %{agent: from, verdict: "not_allowed"})
            Logger.info("browse: from=#{from} url=#{url} verdict=not_allowed")
            {:reply, err("not_allowed"), state}

          # An upstream HTTP failure during redirect resolution (404, 5xx) is NOT a
          # security rejection — calling it "blocked" misled the agent (live incident
          # 2026-06-10: a 404'd docs page reported as blocked → the agent fabricated
          # the page's content instead of saying it couldn't be loaded).
          {:error, {:http_status, s}} ->
            display(:browser_done, %{agent: from, verdict: "render_failed"})
            Logger.info("browse: from=#{from} url=#{url} verdict=render_failed reason=http_#{s}")
            {:reply, err("render_failed"), state}

          {:error, reason} ->
            display(:browser_done, %{agent: from, verdict: "blocked"})
            Logger.info("browse: from=#{from} url=#{url} verdict=blocked reason=#{inspect(reason)}")
            {:reply, err("blocked"), state}
        end
    end
  end

  # ── allow_sync: runtime allowlist grants ──
  # The sender must be in :grant_sources (unset/empty = disabled — unauthorized).
  # Hosts pass the package-side sanity floor AGAIN (the caller curates, we verify),
  # union into the allow policy (allowlist mode) and persist via :grants_store.
  # `meta` is opaque provenance (this package never learns what a campaign is) —
  # passed through to the store and the audit log only.
  defp do_allow_sync(from, m, state) do
    cond do
      to_string(from) not in state.grant_sources ->
        Logger.warning("browse: from=#{from} action=allow_sync verdict=unauthorized")
        {:reply, err("unauthorized"), state}

      not is_list(m["hosts"]) ->
        {:reply, err("bad_hosts — expected a list of hostnames"), state}

      true ->
        meta = if is_map(m["meta"]), do: m["meta"], else: %{}

        {valid, invalid} = Enum.split_with(m["hosts"], &Browse.grantable_host?/1)
        fresh = valid |> Enum.map(&Browse.normalize_host/1) |> MapSet.new() |> MapSet.difference(state.grants)

        state = apply_grants(fresh, meta, from, state)

        payload = %{
          ok: true,
          added: MapSet.size(fresh),
          skipped: length(invalid),
          total: MapSet.size(state.grants)
        }

        payload =
          cond do
            state.mode == :denylist ->
              Map.put(payload, :note, "denylist mode — grants persisted but inactive (no positive allowlist)")

            state.floor_empty ->
              Map.put(payload, :note, "kill switch engaged (empty file floor) — grants persisted but inactive")

            true ->
              payload
          end

        Logger.info(
          "browse: from=#{from} action=allow_sync added=#{payload.added} skipped=#{payload.skipped} " <>
            "total=#{payload.total} meta=#{inspect(meta)}"
        )

        {:reply, Jason.encode!(payload), state}
    end
  end

  # Batch-apply fresh grants: ONE policy union + ONE renderer-cage recompute
  # (never per-host), then persist + emit per host. Policy is only extended in
  # allowlist mode with a healthy file floor — grants are recorded/persisted
  # regardless (ready for a mode flip or a healthy-floor restart), which is also
  # why `grants` is tracked separately from `policy`. Persistence is best-effort:
  # a flaky store must not break a live flow — the grant stays in memory and is
  # lost on restart, loudly.
  defp apply_grants(fresh, meta, from, state) do
    state =
      case {state.mode, state.floor_empty, state.policy} do
        {:allowlist, false, {:allow, set}} ->
          set = MapSet.union(set, fresh)
          %{state | policy: {:allow, set}, allowed_domains: Browse.allowed_domains_arg(set)}

        _ ->
          state
      end

    Enum.each(fresh, fn host ->
      if state.grants_store do
        try do
          state.grants_store.save_grant(host, meta)
        rescue
          e ->
            Logger.error("browser: grant store write failed for #{host} (#{Exception.message(e)}) — in-memory only")
        end
      end

      display(:browser_grant, %{host: host, source: to_string(from)})
    end)

    %{state | grants: MapSet.union(state.grants, fresh)}
  end

  defp do_act(from, verb, arg, desc, full?, state) do
    cond do
      not Map.has_key?(state.sessions, from) ->
        display(:browser_done, %{agent: from, verdict: "no_session"})
        Logger.info("browse: from=#{from} act=#{desc} verdict=no_session")
        {:reply, err("no_session — render a page first"), state}

      verb == :type and flag_shaped_type?(arg.text) ->
        display(:browser_done, %{agent: from, verdict: "flag_shaped_text"})
        Logger.info("browse: from=#{from} act=#{desc} verdict=flag_shaped_text")
        {:reply, err("bad_arg — type text can't be a single '-'-leading word (it looks like a CLI flag); add a space or another word"), state}

      not valid_arg?(verb, arg) ->
        display(:browser_done, %{agent: from, verdict: "bad_arg"})
        Logger.info("browse: from=#{from} act=#{desc} verdict=bad_arg")
        {:reply, err("bad_arg"), state}

      over_rate?(from, state) ->
        display(:browser_done, %{agent: from, verdict: "rate_limited"})
        Logger.info("browse: from=#{from} act=#{desc} verdict=rate_limited")
        {:reply, err("rate_limited"), state}

      true ->
        sess = state.sessions[from].name
        r = state.renderer
        state = bump_rate(state, from)
        display(:browser_dispatch, %{agent: from, act: desc})
        Logger.info("browse: from=#{from} act=#{desc} verdict=dispatched session=#{sess}")
        deliver(from, desc, render_sync(fn -> r.act(verb, arg, sess) end, state), full?, state)
    end
  end

  defp valid_arg?(:click, %{ref: ref}), do: Regex.match?(@ref_re, ref)
  defp valid_arg?(:back, _), do: true
  defp valid_arg?(:type, %{ref: ref, text: text}),
    do: Regex.match?(@ref_re, ref) and String.length(text) <= @type_text_max
  defp valid_arg?(:press, %{key: key}), do: Regex.match?(@key_re, key)

  # See @flag_shaped_type_re above for the boundary rationale (L9).
  defp flag_shaped_type?(text), do: Regex.match?(@flag_shaped_type_re, text)

  # Run `fun` (the render) INLINE with the render-timeout watchdog, blocking this
  # object until it returns — the agent `ask`s and gets the page back in the same
  # turn (concurrent askers serialize in the object mailbox). A hung render is killed
  # at render_timeout_ms. Returns the renderer's {:ok, %{landed_url, text}} |
  # {:error, reason}.
  defp render_sync(fun, state) do
    parent = self()
    timeout = state.render_timeout_ms

    {worker, ref} =
      spawn_monitor(fn ->
        res =
          try do
            fun.()
          rescue
            e -> {:error, {:render_crashed, Exception.message(e)}}
          catch
            kind, reason -> {:error, {:render_crashed, {kind, reason}}}
          end

        send(parent, {:worker_result, res})
      end)

    receive do
      {:worker_result, res} ->
        Process.demonitor(ref, [:flush])
        res

      {:DOWN, ^ref, :process, ^worker, down_reason} ->
        {:error, {:render_crashed, down_reason}}
    after
      timeout ->
        Process.exit(worker, :kill)
        {:error, :render_timeout}
    end
  end

  # Re-gate the landed URL (clicks and JS redirects can leave the allowlist), then
  # reply inline. On gate failure the session is DESTROYED, not just refused: the live
  # browser is sitting on an off-cage page, and any further action would interact with
  # it.
  defp deliver(from, desc, {:ok, %{landed_url: landed, text: text}}, full?, state) do
    case Browse.gate(landed, state.policy, state.resolver) do
      :ok ->
        display(:browser_done, %{agent: from, verdict: "ok", host: host_of(landed)})
        Logger.info("browse: from=#{from} act=#{desc} landed=#{landed} verdict=ok full=#{full?}")
        state = touch_session(from, state)
        {clamped, truncated?} = clamp(text, state.max_text_chars)
        # true page size (pre-clamp) — so `bytes`/`more` report the real size, not the cap
        payload = build_payload(landed, clamped, truncated?, full?, byte_size(text), state)
        {:reply, Jason.encode!(payload), state}

      {:error, reason} ->
        display(:browser_done, %{agent: from, verdict: "escape_blocked"})
        Logger.info("browse: from=#{from} act=#{desc} landed=#{landed} verdict=escape_blocked reason=#{inspect(reason)}")
        {:reply, err("blocked"), drop_session(from, state)}
    end
  end

  defp deliver(from, desc, {:error, reason}, _full?, state) do
    display(:browser_done, %{agent: from, verdict: "render_failed"})
    Logger.info("browse: from=#{from} act=#{desc} verdict=render_failed reason=#{inspect(reason)}")
    {:reply, err("render_failed"), state}
  end

  # Defensive: any unexpected renderer shape still tells the agent the action failed.
  defp deliver(from, desc, other, _full?, state) do
    Logger.warning("browse: from=#{from} act=#{desc} verdict=render_failed reason=unexpected:#{inspect(other)}")
    {:reply, err("render_failed"), state}
  end

  # full:true — the WHOLE body, as before. The agent asks for this ONLY to pipe it into
  # its own workspace file and grep it (so it stays out of context); the skill is explicit
  # about pairing full:true with the jq-extract + redirect.
  defp build_payload(url, text, capped?, true = _full?, _orig_bytes, state) do
    payload = %{url: url, text: wrap(text, state.untrusted_tag)}
    if capped?, do: Map.put(payload, :truncated, true), else: payload
  end

  # Default — COMPACT. Truncate the main body to `head_chars` but KEEP the nav-link index
  # (split on @nav_marker), so the page body stays out of the agent's context while the
  # navigation surface survives. `bytes` is the true (pre-clamp) page size; `more` (present
  # only when the body was actually truncated) tells the agent how to read the rest without
  # flooding context. Both page-derived fields are wrapped as untrusted.
  defp build_payload(url, text, _capped?, false = _full?, orig_bytes, state) do
    {main, nav} = split_nav(text)
    head = String.slice(main, 0, state.head_chars)
    truncated? = String.length(main) > state.head_chars

    payload = %{url: url, bytes: orig_bytes, head: wrap(head, state.untrusted_tag)}

    payload =
      case nav do
        nil -> payload
        nav_text -> Map.put(payload, :links, wrap(String.slice(nav_text, 0, state.nav_chars_max), state.untrusted_tag))
      end

    if truncated? do
      Map.put(
        payload,
        :more,
        "Showing the first #{state.head_chars} chars of the body; the full page is #{orig_bytes} bytes. " <>
          "To read the rest WITHOUT flooding your context, re-send this action with \"full\":true, pipe it " <>
          "through jq into a file, then grep that file (the ask reply is a JSON envelope — jq pulls out just " <>
          "the page text, with real line breaks, so grep returns only the matching lines): " <>
          ~s(SWARM_ASK_TIMEOUT=60 swarm-msg ask browse '{...,"full":true}' | jq -r '.result.text' > /workspace/page.txt && grep -i '<search-term>' /workspace/page.txt)
      )
    else
      payload
    end
  end

  # Split the rendered page into {main_body, nav_index | nil} on the renderer's nav header
  # (@nav_marker). Fail-soft: no marker → {whole_text, nil} (the agent still gets the head).
  defp split_nav(text) do
    case String.split(text, @nav_marker, parts: 2) do
      [main, nav] -> {main, @nav_marker <> nav}
      [only] -> {only, nil}
    end
  end

  def handle_info({:session_sweep, from}, state) do
    case Map.get(state.sessions, from) do
      nil ->
        {:noreply, state}

      %{last_used: t} ->
        idle = now_ms(state) - t

        if idle >= state.session_ttl_ms do
          Logger.info("browse: from=#{from} verdict=session_expired idle_ms=#{idle}")
          {:noreply, drop_session(from, state)}
        else
          Process.send_after(self(), {:session_sweep, from}, state.session_ttl_ms)
          {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── session helpers ──
  defp ensure_session(from, state) do
    case Map.get(state.sessions, from) do
      %{name: name} ->
        {name, state}

      nil ->
        # Deterministic name: an orphan from a previous object incarnation gets
        # re-attached (and navigated) instead of leaking.
        name = "#{state.session_prefix}-#{from}"
        Process.send_after(self(), {:session_sweep, from}, state.session_ttl_ms)
        {name, put_in(state.sessions[from], %{name: name, last_used: now_ms(state)})}
    end
  end

  defp touch_session(from, state) do
    case state.sessions[from] do
      nil -> state
      s -> put_in(state.sessions[from], %{s | last_used: now_ms(state)})
    end
  end

  defp drop_session(from, state) do
    case Map.get(state.sessions, from) do
      nil ->
        state

      %{name: name} ->
        r = state.renderer
        Task.start(fn -> r.close(name) end)
        %{state | sessions: Map.delete(state.sessions, from)}
    end
  end

  # ── helpers ──
  # Returns {:ok, MapSet} on a readable file (possibly empty), {:error, reason} if unreadable.
  # The unreadable/empty distinction matters for denylist fail-closed (Task 4): an unreadable
  # blocklist must NOT be treated as "nothing blocked".
  defp load_hostset(path) do
    case File.read(path) do
      {:ok, body} ->
        set =
          body
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
          |> Enum.map(&String.downcase/1)
          |> MapSet.new()
        {:ok, set}

      {:error, r} ->
        {:error, r}
    end
  end

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) -> String.downcase(String.trim_trailing(h, "."))
      _ -> nil
    end
  end

  # Backstop size cap (see :max_text_chars). Returns {text, truncated?}; when it bites,
  # the envelope carries truncated:true (a TRUSTED flag outside the untrusted wrapper) so
  # the agent knows it has only the START of a long page. Generic — no per-site knowledge.
  defp clamp(text, max) when is_binary(text) do
    if String.length(text) > max, do: {String.slice(text, 0, max), true}, else: {text, false}
  end

  defp wrap(text, tag) do
    # The closing form mirrors the opening one (`(?:\s[^>]*)?`): a page could smuggle
    # a closer past a stricter strip with whitespace OR attribute junk (`</tag >`,
    # `</tag foo>` — invalid HTML, but a fuzzy reader may honor it) and terminate the
    # untrusted wrapper early.
    stripped = String.replace(text, ~r{<#{Regex.escape(tag)}(?:\s[^>]*)?>|</#{Regex.escape(tag)}(?:\s[^>]*)?>}i, "")
    "<#{tag}>" <> stripped <> "</#{tag}>"
  end

  # Did the action ask for the full body? Only a literal JSON `true` counts — any other
  # value (missing, "true" string, etc.) keeps the safe compact default.
  defp full?(m), do: Map.get(m, "full", false) == true

  defp err(msg), do: Jason.encode!(%{error: msg})

  defp now_ms(state), do: state.now_fn.()

  defp over_rate?(from, state) do
    # fixed 60s window keyed by agent slot; a reused slot self-heals at window expiry
    {count, t} = Map.get(state.rate, from, {0, now_ms(state)})
    now_ms(state) - t < 60_000 and count >= state.rate_max
  end

  defp bump_rate(state, from) do
    {count, t} = Map.get(state.rate, from, {0, now_ms(state)})
    new = if now_ms(state) - t < 60_000, do: {count + 1, t}, else: {1, now_ms(state)}
    %{state | rate: Map.put(state.rate, from, new)}
  end

  # ── grants config + store seams (tips/cron idiom) ──
  # Sources compare as strings (config may hold atoms, engine senders arrive as
  # either). Anything but a non-empty list disables the action.
  defp normalize_grant_sources(l) when is_list(l), do: Enum.map(l, &to_string/1)
  defp normalize_grant_sources(_), do: []

  # nil = unset ⇒ the package default; an explicit list (incl. []) wins verbatim.
  defp normalize_default_hosts(nil), do: normalize_default_hosts(@default_hosts)

  defp normalize_default_hosts(hosts) when is_list(hosts) do
    hosts
    |> Enum.map(fn h -> h |> to_string() |> String.trim() |> Browse.normalize_host() end)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_default_hosts(_), do: MapSet.new()

  # Boot load: every stored host re-passes the sanity floor (a row written before
  # a floor tightening must not resurrect). A raising store → file-only floor.
  defp load_grants(nil), do: MapSet.new()

  # Store calls are DIRECT applies — no function_exported? shield. A store wired
  # against a stale contract (wrong arity, renamed callback) must fail LOUDLY
  # through the rescue paths, not silently persist nothing forever.
  defp load_grants(store) do
    store.load_grants()
    |> Enum.filter(&Browse.grantable_host?/1)
    |> Enum.map(&Browse.normalize_host/1)
    |> MapSet.new()
  rescue
    e ->
      Logger.error("browser: grants store load failed (#{Exception.message(e)}) — file-only floor")
      MapSet.new()
  end

  # Resolve a module from config without minting atoms (tips idiom).
  defp module_ref(nil), do: nil
  defp module_ref(mod) when is_atom(mod), do: mod

  defp module_ref(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp module_ref(_), do: nil

  # display-event one-liner (docs/display-event-feed-plan.md): a free no-op
  # unless the EventFeed collector is attached on the live host
  defp display(kind, meta),
    do: :telemetry.execute(Application.get_env(:genswarms_objects, :display_wire, [:genswarms, :display]), %{}, Map.put(meta, :kind, kind))
end

defmodule Genswarms.Browser.Core do
  @moduledoc """
  Promotable core for the allowlist-capped web browser. No wingston/campaign
  concept — could move to `Genswarms.Browser` unchanged.

  Security model (measured against agent-browser 0.27.1 — see the spec): this module
  is the SOLE gate on which URL the browser may sit on. `global_ip?/1` is the SSRF
  primitive (rejects non-routable targets). The companion `gate/3` (https + allowlist
  + SSRF) and `resolve_redirects/3` (redirect-chain pre-validation) build on it so the
  browser is only ever pointed at a fully-validated public URL — and since clicks can
  navigate (agent-browser's `--allowed-domains` cage gates `open` targets and
  sub-resources but NOT click-driven top-level navigation), the landed URL after EVERY
  interaction must be re-`gate/3`-d before any page text is delivered.
  """
  require Logger
  import Bitwise

  @max_redirects 3

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})
  @type policy :: {:allow, MapSet.t(String.t())} | {:deny, MapSet.t(String.t())}

  @doc """
  Gate a URL the agent wants opened. THE sole gate (agent-browser does not gate the
  open target). `resolver` is injected for testability; defaults to real DNS.
  """
  @spec gate(String.t(), policy(), resolver()) :: :ok | {:error, term()}
  def gate(url, policy, resolver \\ &resolve_host/1) do
    with {:ok, uri} <- parse(url),
         :ok <- https_only(uri),
         :ok <- no_userinfo(uri),
         :ok <- ok_port(uri),
         :ok <- membership(uri.host, policy),
         :ok <- ssrf_safe?(uri.host, resolver) do
      :ok
    end
  end

  defp parse(url) do
    uri = URI.parse(url)
    host = if is_binary(uri.host), do: String.trim_trailing(uri.host, "."), else: nil
    if is_binary(host) and host != "", do: {:ok, %{uri | host: host}}, else: {:error, :bad_url}
  end

  defp https_only(%URI{scheme: "https"}), do: :ok
  defp https_only(%URI{scheme: s}), do: {:error, {:not_https, s}}

  defp no_userinfo(%URI{userinfo: nil}), do: :ok
  defp no_userinfo(%URI{}), do: {:error, :userinfo_not_allowed}

  # https default port is 443; URI.parse fills :port (443 for a bare https URL). Reject any
  # explicit non-443 port (prevents pointing the gate at an off-standard service on an allowed host).
  defp ok_port(%URI{port: p}) when p in [nil, 443], do: :ok
  defp ok_port(%URI{port: p}), do: {:error, {:bad_port, p}}

  # Allowlist: exact-host membership (unchanged semantics). Denylist: pass unless blocked.
  defp membership(host, {:allow, set}) do
    if MapSet.member?(set, String.downcase(host)), do: :ok, else: {:error, {:not_allowed, host}}
  end

  defp membership(host, {:deny, set}) do
    if blocked?(host, set), do: {:error, {:not_allowed, host}}, else: :ok
  end

  @doc "Normalize a host for matching: lowercase, strip one trailing dot, punycode→ascii."
  @spec normalize_host(String.t()) :: String.t()
  def normalize_host(host) when is_binary(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> to_ascii()
  end

  # Seed blocklist is all-ASCII; keep this a straight passthrough (no IDNA dependency).
  defp to_ascii(host), do: host

  @doc "True iff `host` is blocked by `blockset` on a LABEL boundary (apex or subdomain)."
  @spec blocked?(String.t(), MapSet.t(String.t())) :: boolean()
  def blocked?(host, blockset) do
    h = normalize_host(host)
    labels = String.split(h, ".")

    0..(length(labels) - 1)
    |> Enum.any?(fn i ->
      suffix = labels |> Enum.drop(i) |> Enum.join(".")
      MapSet.member?(blockset, suffix)
    end)
  end

  defp ssrf_safe?(host, resolver) do
    case resolver.(host) do
      {:ok, []} -> {:error, {:dns_fail, host, :empty}}
      {:ok, ips} ->
        bad = Enum.reject(ips, &global_ip?/1)
        if bad == [], do: :ok, else: {:error, {:internal_ip, host, bad}}
      {:error, r} -> {:error, {:dns_fail, host, r}}
    end
  end

  @doc "Default resolver: IPv4 + IPv6 addresses for `host`."
  @spec resolve_host(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve_host(host) do
    hc = String.to_charlist(host)
    v4 =
      case :inet.getaddrs(hc, :inet) do
        {:ok, a} -> a
        _ -> []
      end

    v6 =
      case :inet.getaddrs(hc, :inet6) do
        {:ok, a} -> a
        _ -> []
      end

    case v4 ++ v6 do
      [] -> {:error, :nxdomain}
      ips -> {:ok, ips}
    end
  end

  @doc "Render the allowlist into agent-browser's --allowed-domains (with *. wildcards)."
  # Assumes `allowset` holds bare domains (e.g. "example.com"), not pre-wildcarded entries.
  @spec allowed_domains_arg(MapSet.t(String.t())) :: String.t()
  def allowed_domains_arg(allowset) do
    allowset |> Enum.sort() |> Enum.flat_map(&[&1, "*." <> &1]) |> Enum.join(",")
  end

  @doc "True iff `ip` (a 4- or 8-tuple) is a globally-routable address (SSRF-safe target)."
  @spec global_ip?(:inet.ip_address()) :: boolean()
  # IPv4 non-global ranges
  def global_ip?({127, _, _, _}), do: false
  def global_ip?({10, _, _, _}), do: false
  def global_ip?({172, b, _, _}) when b in 16..31, do: false
  def global_ip?({192, 168, _, _}), do: false
  def global_ip?({169, 254, _, _}), do: false
  def global_ip?({100, b, _, _}) when b in 64..127, do: false  # CGNAT 100.64/10
  def global_ip?({0, _, _, _}), do: false
  def global_ip?({192, 0, 0, _}), do: false                    # 192.0.0.0/24 IETF protocol assignments
  def global_ip?({192, 0, 2, _}), do: false                    # TEST-NET-1
  def global_ip?({198, 51, 100, _}), do: false                 # TEST-NET-2
  def global_ip?({203, 0, 113, _}), do: false                  # TEST-NET-3
  def global_ip?({198, b, _, _}) when b in 18..19, do: false   # 198.18.0.0/15 benchmarking
  def global_ip?({a, _, _, _}) when a >= 224, do: false        # multicast + reserved
  def global_ip?({_, _, _, _}), do: true
  # IPv6 non-global ranges
  def global_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false                       # ::1
  def global_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false                       # ::
  def global_ip?({w, _, _, _, _, _, _, _}) when band(w, 0xFE00) == 0xFC00, do: false  # fc00::/7
  def global_ip?({w, _, _, _, _, _, _, _}) when band(w, 0xFFC0) == 0xFE80, do: false  # fe80::/10
  def global_ip?({w, _, _, _, _, _, _, _}) when band(w, 0xFF00) == 0xFF00, do: false  # ff00::/8 multicast
  def global_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false  # IPv4-mapped ::ffff:0:0/96
  # NAT64 64:ff9b::/96 — embeds an IPv4 in the low 32 bits, so 64:ff9b::a9fe:a9fe
  # IS 169.254.169.254; without this clause it looks like a routable global v6.
  def global_ip?({0x64, 0xFF9B, 0, 0, 0, 0, h, l}), do: global_ip?({div(h, 256), rem(h, 256), div(l, 256), rem(l, 256)})
  def global_ip?({_, _, _, _, _, _, _, _}), do: true

  @doc """
  Follow the redirect chain WITHOUT a browser, `gate/3`-ing every hop, so the browser
  is only ever pointed at a fully-validated terminal URL. `opts[:fetcher]` and
  `opts[:resolver]` are injected for tests; defaults hit the network via `curl`.
  """
  @spec resolve_redirects(String.t(), policy(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_redirects(url, policy, opts \\ []) do
    fetcher = Keyword.get(opts, :fetcher, &http_head/1)
    resolver = Keyword.get(opts, :resolver, &resolve_host/1)
    follow(url, policy, fetcher, resolver, @max_redirects)
  end

  defp follow(_url, _policy, _fetcher, _resolver, 0), do: {:error, :too_many_redirects}
  defp follow(url, policy, fetcher, resolver, n) do
    with :ok <- gate(url, policy, resolver) do
      case fetcher.(url) do
        {status, loc} when status in 300..399 and is_binary(loc) ->
          follow(URI.merge(URI.parse(url), loc) |> URI.to_string(), policy, fetcher, resolver, n - 1)
        {status, nil} when status in 300..399 ->
          {:error, {:missing_location, status}}
        {status, _} when status in 200..299 ->
          {:ok, url}
        {status, _} when is_integer(status) ->
          {:error, {:http_status, status}}
        {:error, reason} ->
          {:error, {:fetch_failed, reason}}
        other ->
          {:error, {:fetch_failed, other}}
      end
    end
  end

  # Default fetcher: a HEAD via `curl` — the CLI this stack already relies on, and robust
  # to runtimes that don't carry :inets on the code path (the genswarms engine doesn't).
  # No redirect following (no -L is the mechanism; `--max-redirs 0` is belt-and-suspenders
  # if -L were ever added). curl's `%{redirect_url}` reports the Location target WITHOUT
  # connecting to it, so `follow/5` gates every hop itself before any connection. TLS is
  # verified (no -k). A server that rejects HEAD (e.g. 405) aborts the browse fail-closed
  # rather than falling back to GET. The tests inject a fetcher instead of hitting the net.
  defp http_head(url) do
    args = [
      "-sS", "-o", "/dev/null", "-I", "--max-redirs", "0",
      "--max-time", "10", "--connect-timeout", "5",
      "-w", "%{http_code} %{redirect_url}", "--", url
    ]

    try do
      case System.cmd(curl_bin(), args, stderr_to_stdout: true) do
        {out, 0} -> parse_curl_head(out)
        {out, code} -> {:error, {:curl_exit, code, String.slice(out, 0, 160)}}
      end
    rescue
      e -> {:error, {:curl_unavailable, Exception.message(e)}}
    end
  end

  defp curl_bin do
    System.get_env("GENSWARMS_CURL_BIN") || System.find_executable("curl") ||
      raise "curl not found on PATH (set GENSWARMS_CURL_BIN)"
  end

  @doc false
  # Parse `curl -w "%{http_code} %{redirect_url}"` output into the fetcher contract
  # `{status, location | nil} | {:error, reason}`. Public only so tests can cover it
  # offline (no network). `http_code` 000 means curl got no response.
  @spec parse_curl_head(String.t()) :: {non_neg_integer(), String.t() | nil} | {:error, term()}
  def parse_curl_head(out) do
    case String.split(String.trim(out), " ", parts: 2) do
      [code_str | rest] ->
        case Integer.parse(code_str) do
          {0, _} -> {:error, :no_response}
          {status, _} ->
            loc = rest |> List.first() |> to_string() |> String.trim()
            {status, if(loc == "", do: nil, else: loc)}

          :error ->
            {:error, {:bad_curl_output, String.slice(out, 0, 120)}}
        end

      _ ->
        {:error, {:bad_curl_output, String.slice(out, 0, 120)}}
    end
  end
end

defmodule Genswarms.Browser.Renderer do
  @moduledoc """
  Swappable renderer with a PERSISTENT session: `navigate/3` opens a URL in the named
  session and leaves it open; `act/3` interacts with the live page (click/back/type/
  press); `close/1` ends the session. Default impl: `Genswarms.Browser.AgentBrowser`.

  Every callback that touches the page returns the LANDED url so the object can re-gate
  it — measured against agent-browser 0.27.1: the `--allowed-domains` cage gates `open`
  targets and sub-resource egress but does NOT stop click-driven top-level navigation
  (a click on an external link sails out of the cage), so the engine-side re-gate is
  the only thing standing between an interaction and an off-allowlist page. The landed
  url is captured AFTER the page settles (post-snapshot), so a client-side redirect
  completing during the settle window cannot slip off-cage text past the re-gate.
  """
  @callback navigate(url :: String.t(), session :: String.t(), allowed_domains :: String.t()) ::
              {:ok, %{landed_url: String.t(), text: String.t()}} | {:error, term()}
  @callback act(verb :: :click | :back | :type | :press, arg :: map(), session :: String.t()) ::
              {:ok, %{landed_url: String.t(), text: String.t()}} | {:error, term()}
  @callback close(session :: String.t()) :: :ok
end

defmodule Genswarms.Browser.AgentBrowser do
  @moduledoc """
  agent-browser adapter over a persistent named session. Snapshots are taken with
  `--urls` (links carry their absolute hrefs — without this the agent cannot navigate
  except by guessing URLs, the 2026-06-11 hallucinated-URL incident) and `--compact`.

  A delivered snapshot is two parts (see `content_snapshot/1`):
    1. the page's `main` content region (`--selector main`) — the readable article.
       Scoping matters: docs/blog/app pages bury the article under a nav sidebar +
       footer often 5-6x its size, so the unscoped snapshot pushed the body PAST the
       clamp and the agent got only chrome ("can't read the content" incident: the
       genlayer IC intro page was 59k, article starting ~16k in). No usable `main`
       (landing/app pages) → fall back to the whole page.
    2. a compact index of every other link on the page (titles + URLs) — because the
       section nav (e.g. the GenVM page) lives in the SIDEBAR, which `main` omits;
       without it the agent can read a page but can't discover where to go next (the
       2026-06-11 "couldn't reach GenVM" incident). The agent navigates by RENDERING a
       URL from this index, never by clicking a nav ref — so the index needs no refs,
       and the `main` snapshot is taken LAST so the live ref table matches the refs the
       agent WILL click inside the content.

  The exposed verbs are navigation-shaped only (click/back/type/press) — never
  eval/cookies/storage. The object validates verb args before they reach this module;
  `cmd/1` uses System.cmd (argv, no shell), so there is no shell injection surface
  either way.
  """
  @behaviour Genswarms.Browser.Renderer

  @bin "agent-browser"
  # Main content is far smaller than the old full-page snapshot (the intro article is
  # ~10k vs 59k full), so a long article is truncated at its TAIL rather than starved
  # at its head by the nav. 20k ≈ 5k tokens — comfortable for a deliberate read.
  @snapshot_max 20_000
  # The content region preferred over the full page. A standard HTML5 landmark; present
  # on the docs site and most modern content pages. Missing → full-page fallback.
  @content_selector "main"
  # Cap on the appended navigation-link index (titles + URLs from the full page) so a
  # huge nav tree can't blow the payload past the main content.
  @nav_links_max 200

  @impl true
  def navigate(url, session, allowed) do
    if not String.starts_with?(url, "https://") do
      {:error, {:unsafe_url, url}}
    else
      # parse_open_json validates that `open` really landed somewhere; its URL is a
      # PRE-settle answer, so settle_and_snapshot re-reads the landed URL itself.
      with {:open, {out, 0}} <- {:open, open_with_retry(url, allowed, session)},
           {:ok, _pre_settle} <- parse_open_json(out) do
        settle_and_snapshot(session)
      else
        {:open, {out, _}} -> {:error, {:open_failed, String.slice(out, 0, 200)}}
        {:error, r} -> {:error, r}
      end
    end
  end

  @impl true
  def act(verb, arg, session) do
    case verb_args(verb, arg) do
      {:ok, args} ->
        case cmd(args ++ ["--session", session]) do
          {_, 0} ->
            # The verb may have navigated (click/back) — settle_and_snapshot reads the
            # landed URL AFTER the page settles, and the object re-gates that, so
            # off-cage page text never reaches the agent.
            settle_and_snapshot(session)

          {out, _} ->
            {:error, {:act_failed, verb, String.slice(out, 0, 200)}}
        end

      {:error, r} ->
        {:error, r}
    end
  end

  @impl true
  def close(session) do
    cmd(["close", "--session", session])
    :ok
  end

  defp verb_args(:click, %{ref: ref}), do: {:ok, ["click", "@" <> ref]}
  defp verb_args(:back, _), do: {:ok, ["back"]}
  defp verb_args(:type, %{ref: ref, text: text}), do: {:ok, ["fill", "@" <> ref, text]}
  defp verb_args(:press, %{key: key}), do: {:ok, ["press", key]}
  defp verb_args(verb, arg), do: {:error, {:bad_verb, verb, arg}}

  # Settle-then-capture (L1, audit 2026-07-02): the landed URL is read AFTER the
  # wait + snapshot, never before. A client-side redirect (JS `location=`, meta
  # refresh) that completes during the settle window would otherwise leave a STALE
  # pre-settle URL here — still pointing at the allowed host — and the object's
  # re-gate would pass off-cage page text through. Capturing after the snapshot
  # skews the race toward the gate seeing the NEWER url, so a single off-cage
  # redirect now lands on "blocked" (snapshot/get-url are not atomic — a page
  # that bounces off-cage and BACK between them is a theoretical residual). A
  # failed post-settle `get url` is an error, not a fallback to a stale URL.
  defp settle_and_snapshot(session) do
    cmd(["wait", "--load", "networkidle", "--session", session])

    case content_snapshot(session) do
      {:ok, text} ->
        case cmd(["get", "url", "--session", session]) do
          {out, 0} -> {:ok, %{landed_url: String.trim(out), text: text}}
          {out, _} -> {:error, {:get_url_failed, String.slice(out, 0, 200)}}
        end

      {:error, out} ->
        {:error, {:snapshot_failed, String.slice(out, 0, 200)}}
    end
  end

  # Deliver the page's `main` content (the readable article) PLUS a compact index of
  # every other link on the page. The index matters because a docs site's section nav
  # (e.g. the GenVM page) lives in the SIDEBAR, which `main` omits — without it the
  # agent can read a page but can't discover where to navigate next. The agent travels
  # by RENDERING a URL from the index (never clicking a nav ref), so the index needs no
  # refs; the `main` snapshot is taken LAST so the live ref table matches the refs the
  # agent WILL click inside the content (buttons / expanders / search).
  #
  # content_snapshot returns fully-bounded text (main clamped + nav list capped), so
  # the caller does NOT clamp again (that would truncate the nav list off the tail).
  defp content_snapshot(session) do
    full =
      case cmd(["snapshot", "--urls", "--compact", "--session", session]) do
        {out, 0} -> out
        _ -> ""
      end

    case cmd(["snapshot", "--urls", "--compact", "--selector", @content_selector, "--session", session]) do
      {main, 0} ->
        if usable_content?(main) do
          {:ok, clamp(main) <> nav_section(full, main)}
        else
          # No usable <main>: deliver the whole page, re-taken LAST so its refs are live.
          full_snapshot(session)
        end

      {_out, _} ->
        full_snapshot(session)
    end
  end

  defp full_snapshot(session) do
    case cmd(["snapshot", "--urls", "--compact", "--session", session]) do
      {out, 0} -> {:ok, clamp(out)}
      {out, _} -> {:error, out}
    end
  end

  # Pull every titled link (+ absolute URL) from the full-page snapshot, drop ones
  # already shown inline in `main`, dedup by URL, cap the count, and render a compact
  # render-me list. This is the navigation surface the main-scope drops.
  defp nav_section(full, main) do
    links =
      ~r/link "([^"]+)" \[ref=\w+, url=([^\]\s]+)\]/
      |> Regex.scan(full)
      |> Enum.map(fn [_, title, url] -> {String.trim(title), url} end)
      |> Enum.uniq_by(fn {_t, url} -> url end)
      |> Enum.reject(fn {_t, url} -> url == "" or String.contains?(main, url) end)
      |> Enum.take(@nav_links_max)

    case links do
      [] ->
        ""

      _ ->
        body = Enum.map_join(links, "\n", fn {t, url} -> "- #{t} — #{url}" end)
        "\n\n--- Other links on this page (render a URL to go there) ---\n" <> body
    end
  end

  # agent-browser exits 0 even when the selector misses, printing
  # "✗ Selector ... did not match any element"; treat that — and an essentially-empty
  # body (an empty <main> shell) — as "no usable main" so we fall back to the full page.
  defp usable_content?(out) do
    not String.contains?(out, "did not match any element") and
      String.length(String.trim(out)) >= 200
  end

  defp open_with_retry(url, allowed, session) do
    case cmd(["open", url, "--allowed-domains", allowed, "--session", session, "--json"]) do
      {out, 0} -> {out, 0}
      {_, _} ->
        Process.sleep(600)
        cmd(["open", url, "--allowed-domains", allowed, "--session", session, "--json"])
    end
  end

  @doc "Extract the landed URL from `agent-browser open --json` output."
  @spec parse_open_json(String.t()) :: {:ok, String.t()} | {:error, term()}
  def parse_open_json(out) do
    case Jason.decode(out) do
      {:ok, %{"data" => %{"url" => url}}} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, decoded} -> {:error, {:no_url, decoded}}
      {:error, _} -> {:error, {:bad_json, String.slice(out, 0, 120)}}
    end
  end

  defp cmd(args), do: System.cmd(@bin, args, stderr_to_stdout: true)
  defp clamp(t) do
    if String.length(t) > @snapshot_max,
      do: String.slice(t, 0, @snapshot_max) <> "\n…[truncated]",
      else: t
  end
end

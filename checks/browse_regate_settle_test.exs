# Tests for the browse re-gate settle-then-capture fix (L1, audit 2026-07-02): the URL
# the object re-gates must be captured AFTER `wait --load networkidle` + snapshot — not
# before. A client-side redirect (JS `location=`, meta refresh, setTimeout) that
# completes during the settle/snapshot window otherwise leaves the delivered text on the
# post-redirect (off-cage) page while the re-gate inspects the STALE pre-settle URL,
# which still points at the allowed host — so off-cage page text reaches the agent. The
# `--allowed-domains` cage does NOT stop client-driven top-level navigation and the HTTP
# redirect pre-flight never sees JS/meta redirects, so this re-gate is the only backstop
# and it must see the post-settle ground truth.
#
# These tests exercise the REAL Genswarms.Browse.AgentBrowser adapter against a FAKE
# `agent-browser` CLI (a bash shim prepended to PATH — no network, no Chromium). The
# shim models the redirect race deterministically: `get url` answers the allowed URL
# BEFORE the first snapshot and the off-cage URL AFTER it, so a pre-settle capture (the
# bug) and a post-settle capture (the fix) produce different results every run.
#
#   mix run tests/browse_regate_settle_test.exs
ExUnit.start()
defmodule FakeAgentBrowser do
  @moduledoc false
  @allowed "https://allowed.example.com/landing"
  @evil "https://evil.example.net/phish"

  def allowed_url, do: @allowed
  def evil_url, do: @evil

  # Write the shim once and prepend its dir to PATH so System.cmd("agent-browser", …)
  # resolves to it for the rest of this BEAM.
  def install! do
    dir = Path.join(System.tmp_dir!(), "fake_ab_bin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "agent-browser")
    File.write!(script, script_body())
    File.chmod!(script, 0o755)
    System.put_env("PATH", dir <> ":" <> System.get_env("PATH"))
    :ok
  end

  # Fresh per-test shim state: the marker file records "a snapshot has been taken",
  # which is what flips `get url` from the allowed URL to the off-cage URL.
  def fresh_state!(mode) when mode in ["redirect", "stable", "geturl_fail"] do
    dir = Path.join(System.tmp_dir!(), "fake_ab_state_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("FAKE_AB_DIR", dir)
    System.put_env("FAKE_AB_MODE", mode)
    :ok
  end

  defp script_body do
    """
    #!/usr/bin/env bash
    # Fake agent-browser for browse_regate_settle_test.exs. Models a client-side
    # redirect completing during the settle/snapshot window: `get url` reports the
    # allowed URL until the first `snapshot`, and the off-cage URL afterwards.
    mode="${FAKE_AB_MODE:-stable}"
    marker="${FAKE_AB_DIR:?}/snapshot_taken"
    allowed="https://allowed.example.com/landing"
    evil="https://evil.example.net/phish"
    case "$1" in
      open) printf '{"data":{"url":"%s"}}\\n' "$allowed" ;;
      get)
        if [ -e "$marker" ] && [ "$mode" = "geturl_fail" ]; then echo "boom"; exit 1; fi
        if [ -e "$marker" ] && [ "$mode" = "redirect" ]; then echo "$evil"; else echo "$allowed"; fi ;;
      snapshot) touch "$marker"; printf 'lorem ipsum settled content %.0s' $(seq 1 12) ;;
      wait|click|back|press|fill|close) : ;;
    esac
    exit 0
    """
  end
end

defmodule GenswarmsBrowseRegateSettleTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browse.AgentBrowser
  alias Genswarms.Browse

  setup_all do
    FakeAgentBrowser.install!()
    :ok
  end

  test "act: landed_url is the POST-settle URL — a mid-settle redirect is visible to the re-gate" do
    FakeAgentBrowser.fresh_state!("redirect")

    assert {:ok, %{landed_url: landed, text: text}} =
             AgentBrowser.act(:click, %{ref: "e1"}, "sess_act")

    assert landed == FakeAgentBrowser.evil_url(),
           "landed_url must be the post-settle ground truth, not the pre-settle capture"
    assert text =~ "settled content"
  end

  test "navigate: landed_url is the POST-settle URL, not `open`'s pre-settle JSON answer" do
    FakeAgentBrowser.fresh_state!("redirect")

    assert {:ok, %{landed_url: landed}} =
             AgentBrowser.navigate(FakeAgentBrowser.allowed_url(), "sess_nav", "allowed.example.com")

    assert landed == FakeAgentBrowser.evil_url()
  end

  test "post-settle `get url` failure is fail-closed: an error, never a stale allowed URL" do
    FakeAgentBrowser.fresh_state!("geturl_fail")
    assert {:error, {:get_url_failed, _}} = AgentBrowser.act(:click, %{ref: "e1"}, "sess_fail")
  end

  test "end-to-end: mid-settle off-cage redirect → blocked, text discarded, session destroyed" do
    FakeAgentBrowser.fresh_state!("redirect")
    st = object_state()

    {:reply, json, st2} =
      Browse.handle_message(:agentE, ~s({"action":"render","url":"#{FakeAgentBrowser.allowed_url()}"}), st)

    assert %{"error" => "blocked"} = Jason.decode!(json)
    refute Map.has_key?(st2.sessions, :agentE),
           "the live browser is on an off-cage page — the session must be destroyed, not reused"
  end

  test "end-to-end regression: a stable (non-redirecting) page still delivers normally" do
    FakeAgentBrowser.fresh_state!("stable")
    st = object_state()

    {:reply, json, st2} =
      Browse.handle_message(:agentS, ~s({"action":"render","url":"#{FakeAgentBrowser.allowed_url()}"}), st)

    m = Jason.decode!(json)
    refute Map.has_key?(m, "error"), "stable page wrongly refused: #{inspect(m)}"
    assert m["url"] == FakeAgentBrowser.allowed_url()
    assert Map.has_key?(st2.sessions, :agentS)
  end

  # Real AgentBrowser renderer + injected resolver/fetcher (no DNS, no curl) — the only
  # external process is the PATH shim above.
  defp object_state do
    allow = Path.join(System.tmp_dir!(), "browse_regate_allow_#{System.unique_integer([:positive])}.txt")
    File.write!(allow, "allowed.example.com\n")
    on_exit(fn -> File.rm(allow) end)

    {:ok, st} =
      Browse.init(%{
        allowlist_path: allow,
        renderer: AgentBrowser,
        resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
        redirect_fetcher: fn _url -> {200, nil} end,
        now_fn: fn -> 0 end
      })

    st
  end
end

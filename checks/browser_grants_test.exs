# Browser allow_sync grants: runtime, source-gated allowlist extension with an
# injectable persistence seam (campaign-derived grants design, wingston
# docs/superpowers/specs/2026-07-07-campaign-browser-allowlist-design.md).
# The package knows nothing about campaigns — `meta` is opaque provenance.
# Standalone — no store, no network:  mix run checks/browser_grants_test.exs
Code.require_file("packages/browser/browser_core.ex", ".")
Code.require_file("packages/browser/browser.ex", ".")

ExUnit.start()
Code.require_file("support/display_wire_helper.exs", __DIR__)

defmodule BrowserGrantsTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser
  alias Genswarms.Browser.Core

  defmodule RecorderRenderer do
    @behaviour Genswarms.Browser.Renderer
    # navigate runs inside the object's render worker process — report to the
    # registered test process, not self().
    def navigate(url, _session, allowed) do
      if pid = Process.whereis(:grants_e2e_test), do: send(pid, {:allowed_domains, allowed})
      {:ok, %{landed_url: url, text: "hello"}}
    end

    def act(_v, _a, _s), do: {:ok, %{landed_url: "https://ok.example/", text: "hi"}}
    def close(_s), do: :ok
  end

  # Same-process fake store (handle_message runs in the test process, so the
  # Process dictionary is a deterministic seam with zero setup).
  defmodule FakeStore do
    def load_grants, do: Process.get(:fake_grants, [])

    def save_grant(host, meta) do
      Process.put(:fake_grants, Process.get(:fake_grants, []) ++ [host])
      Process.put(:fake_grant_meta, meta)
      :ok
    end
  end

  defmodule BoomLoadStore do
    def load_grants, do: raise("store down")
    def save_grant(_h, _m), do: :ok
  end

  # Wrong arity — simulates a store wired against a stale/renamed contract.
  defmodule BadArityStore do
    def load_grants, do: []
    def save_grant(_h, _m, _extra), do: :ok
  end

  defmodule BoomSaveStore do
    def load_grants, do: []
    def save_grant(_h, _m), do: raise("write failed")
  end

  defp write!(lines) do
    path = "/tmp/grants-alw-#{System.unique_integer([:positive])}.txt"
    File.write!(path, Enum.join(lines, "\n"))
    path
  end

  defp init!(over) do
    {:ok, st} =
      Browser.init(
        Map.merge(
          %{
            mode: :allowlist,
            allowlist_path: write!(["genlayer.com"]),
            renderer: RecorderRenderer,
            resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
            redirect_fetcher: fn _url -> {200, nil} end,
            grant_sources: [:rally]
          },
          over
        )
      )

    st
  end

  defp allow_sync(st, hosts, from \\ :rally) do
    Browser.handle_message(
      from,
      Jason.encode!(%{"action" => "allow_sync", "hosts" => hosts, "meta" => %{"campaign" => "0xabc"}}),
      st
    )
  end

  # ── core sanity floor (pure) ────────────────────────────────────────────────

  test "grantable_host?: accepts bare dotted hostnames only" do
    assert Core.grantable_host?("example.com")
    assert Core.grantable_host?("Docs.Example.COM.")
    refute Core.grantable_host?("192.168.0.1")
    refute Core.grantable_host?("2001:db8::1")
    refute Core.grantable_host?("localhost")
    refute Core.grantable_host?("LOCALHOST")
    refute Core.grantable_host?("nas.local")
    refute Core.grantable_host?("vault.internal")
    refute Core.grantable_host?("dotless")
    refute Core.grantable_host?("host:443")
    refute Core.grantable_host?("a/b.com")
    refute Core.grantable_host?("user@x.com")
    refute Core.grantable_host?("a b.com")
    refute Core.grantable_host?("")
    refute Core.grantable_host?(nil)
  end

  # ── grant path ──────────────────────────────────────────────────────────────

  test "grant from a granted source extends the gate and allowed_domains" do
    st = init!(%{})

    # before the grant: not on the allowlist
    assert {:error, {:not_allowed, _}} =
             Core.gate("https://campaign.example/", st.policy, st.resolver)

    {:reply, reply, st} = allow_sync(st, ["campaign.example"])
    assert %{"ok" => true, "added" => 1, "skipped" => 0, "total" => 1} = Jason.decode!(reply)

    assert :ok = Core.gate("https://campaign.example/", st.policy, st.resolver)
    # renderer cage string extended too (positive sub-resource list)
    assert String.contains?(st.allowed_domains, "campaign.example")
    assert String.contains?(st.allowed_domains, "*.campaign.example")
    # the static floor is still there
    assert :ok = Core.gate("https://genlayer.com/", st.policy, st.resolver)
  end

  test "grants are idempotent: re-granting adds nothing" do
    st = init!(%{})
    {:reply, _r, st} = allow_sync(st, ["campaign.example"])
    {:reply, reply, _st} = allow_sync(st, ["campaign.example", "CAMPAIGN.EXAMPLE."])
    assert %{"ok" => true, "added" => 0, "total" => 1} = Jason.decode!(reply)
  end

  test "a grant emits a :browser_grant display event" do
    DisplayWireHelper.attach!([:genswarms, :display])
    st = init!(%{})
    {:reply, _r, _st} = allow_sync(st, ["campaign.example"])
    assert_receive {:display_event, %{kind: :browser_grant, host: "campaign.example"}}
  end

  # ── source gating ───────────────────────────────────────────────────────────

  test "non-granted source is unauthorized and changes nothing" do
    st = init!(%{})
    {:reply, reply, st2} = allow_sync(st, ["campaign.example"], :agent_tg_1_2)
    assert %{"error" => "unauthorized"} = Jason.decode!(reply)
    assert st2.policy == st.policy
  end

  test "absent grant_sources disables the action entirely (back-compat)" do
    st = init!(%{grant_sources: nil})
    {:reply, reply, st2} = allow_sync(st, ["campaign.example"])
    assert %{"error" => "unauthorized"} = Jason.decode!(reply)
    assert st2.policy == st.policy

    st3 = init!(%{grant_sources: []})
    {:reply, reply3, _} = allow_sync(st3, ["campaign.example"])
    assert %{"error" => "unauthorized"} = Jason.decode!(reply3)
  end

  # ── package-side sanity floor on receipt ────────────────────────────────────

  test "invalid hosts are skipped and counted, valid ones land" do
    st = init!(%{})

    {:reply, reply, st} =
      allow_sync(st, ["ok.example", "127.0.0.1", "localhost", "bad host", "x.internal"])

    assert %{"ok" => true, "added" => 1, "skipped" => 4, "total" => 1} = Jason.decode!(reply)
    assert :ok = Core.gate("https://ok.example/", st.policy, st.resolver)
    assert {:error, {:not_allowed, _}} = Core.gate("https://localhost/", st.policy, st.resolver)
  end

  test "malformed payload errors without crashing" do
    st = init!(%{})

    {:reply, reply, _} =
      Browser.handle_message(:rally, Jason.encode!(%{"action" => "allow_sync", "hosts" => "nope"}), st)

    assert %{"error" => _} = Jason.decode!(reply)
  end

  # ── persistence seam ────────────────────────────────────────────────────────

  test "grants persist through the injected store with opaque meta" do
    Process.delete(:fake_grants)
    st = init!(%{grants_store: FakeStore})
    {:reply, _r, _st} = allow_sync(st, ["campaign.example"])
    assert Process.get(:fake_grants) == ["campaign.example"]
    assert %{"campaign" => "0xabc"} = Process.get(:fake_grant_meta)
  end

  test "boot unions the file floor with stored grants" do
    Process.put(:fake_grants, ["stored.example"])
    st = init!(%{grants_store: FakeStore})
    assert :ok = Core.gate("https://stored.example/", st.policy, st.resolver)
    assert :ok = Core.gate("https://genlayer.com/", st.policy, st.resolver)
    assert String.contains?(st.allowed_domains, "*.stored.example")
    Process.delete(:fake_grants)
  end

  test "a stored grant that fails the sanity floor is dropped at boot" do
    Process.put(:fake_grants, ["ok.example", "localhost"])
    st = init!(%{grants_store: FakeStore})
    assert :ok = Core.gate("https://ok.example/", st.policy, st.resolver)
    assert {:error, {:not_allowed, _}} = Core.gate("https://localhost/", st.policy, st.resolver)
    Process.delete(:fake_grants)
  end

  test "store raising at boot falls back to the file-only floor (no crash)" do
    st = init!(%{grants_store: BoomLoadStore})
    assert :ok = Core.gate("https://genlayer.com/", st.policy, st.resolver)
    assert {:error, {:not_allowed, _}} = Core.gate("https://anything.example/", st.policy, st.resolver)
  end

  test "an EMPTY file floor is a kill switch: stored grants do NOT reopen the gate" do
    Process.put(:fake_grants, ["stored.example"])
    empty = "/tmp/grants-empty-#{System.unique_integer([:positive])}.txt"
    File.write!(empty, "# nothing\n")

    st = init!(%{allowlist_path: empty, grants_store: FakeStore})

    assert {:allow, set} = st.policy
    assert MapSet.size(set) == 0
    assert {:error, {:not_allowed, _}} = Core.gate("https://stored.example/", st.policy, st.resolver)
    Process.delete(:fake_grants)
  end

  test "an UNREADABLE file floor is a kill switch too" do
    Process.put(:fake_grants, ["stored.example"])

    st =
      init!(%{
        allowlist_path: "/tmp/grants-missing-#{System.unique_integer([:positive])}.txt",
        grants_store: FakeStore
      })

    assert {:allow, set} = st.policy
    assert MapSet.size(set) == 0
    Process.delete(:fake_grants)
  end

  test "with an empty floor, runtime grants persist but do NOT reopen the gate" do
    Process.delete(:fake_grants)
    empty = "/tmp/grants-empty-#{System.unique_integer([:positive])}.txt"
    File.write!(empty, "")

    st = init!(%{allowlist_path: empty, grants_store: FakeStore})
    {:reply, reply, st2} = allow_sync(st, ["campaign.example"])

    assert %{"ok" => true, "added" => 1} = Jason.decode!(reply)
    # persisted for a healthy-floor restart…
    assert Process.get(:fake_grants) == ["campaign.example"]
    # …but the kill switch holds: nothing reachable now
    assert {:error, {:not_allowed, _}} = Core.gate("https://campaign.example/", st2.policy, st2.resolver)
    Process.delete(:fake_grants)
  end

  test "a wrong-arity store save fails LOUDLY, grant still applies in memory" do
    st = init!(%{grants_store: BadArityStore})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:reply, reply, st2} = allow_sync(st, ["campaign.example"])
        assert %{"ok" => true, "added" => 1} = Jason.decode!(reply)
        assert :ok = Core.gate("https://campaign.example/", st2.policy, st2.resolver)
      end)

    assert log =~ "grant store write failed"
  end

  test "store write failure still applies the grant in memory" do
    st = init!(%{grants_store: BoomSaveStore})
    {:reply, reply, st} = allow_sync(st, ["campaign.example"])
    assert %{"ok" => true, "added" => 1} = Jason.decode!(reply)
    assert :ok = Core.gate("https://campaign.example/", st.policy, st.resolver)
  end

  # ── denylist mode ───────────────────────────────────────────────────────────

  test "denylist mode accepts + persists grants without touching the policy" do
    Process.delete(:fake_grants)
    block = "/tmp/grants-blk-#{System.unique_integer([:positive])}.txt"
    File.write!(block, "bit.ly\n")

    {:ok, st} =
      Browser.init(%{
        mode: :denylist,
        blocklist_path: block,
        renderer: RecorderRenderer,
        resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
        grant_sources: [:rally],
        grants_store: FakeStore
      })

    {:reply, reply, st2} = allow_sync(st, ["campaign.example"])
    decoded = Jason.decode!(reply)
    assert %{"ok" => true, "added" => 1} = decoded
    # noted in the reply that grants are inactive in this mode
    assert decoded["note"] =~ "denylist"
    # persisted (ready for a mode flip) …
    assert Process.get(:fake_grants) == ["campaign.example"]
    # … but the deny policy and the (nil) renderer cage are untouched
    assert st2.policy == st.policy
    assert st2.allowed_domains == nil
    Process.delete(:fake_grants)
  end

  # ── end-to-end: a granted host renders ──────────────────────────────────────

  test "a render to a freshly granted host dispatches (was not_allowed before)" do
    Process.register(self(), :grants_e2e_test)
    st = init!(%{})
    render = Jason.encode!(%{"action" => "render", "url" => "https://campaign.example/"})

    {:reply, before_reply, st} = Browser.handle_message(:agent1, render, st)
    assert %{"error" => "not_allowed"} = Jason.decode!(before_reply)

    {:reply, _r, st} = allow_sync(st, ["campaign.example"])

    {:reply, after_reply, _st} = Browser.handle_message(:agent1, render, st)
    assert %{"url" => "https://campaign.example/"} = Jason.decode!(after_reply)
    # the renderer was handed the extended cage
    assert_receive {:allowed_domains, allowed}
    assert String.contains?(allowed, "campaign.example")
  end
end

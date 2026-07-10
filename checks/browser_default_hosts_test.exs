# Baked-in default hosts (operator request 2026-07-10): allowlist-mode consumers
# reach the GenLayer-family sites out of the box. Contract under test:
#   - defaults UNION into a live file floor (file + defaults + grants);
#   - the kill switch (empty/unreadable file) suppresses defaults too;
#   - config :default_hosts overrides; an explicit [] opts out (file-only floor);
#   - denylist mode ignores them (no positive list to extend).
# Standalone — no store, no network:  mix run checks/browser_default_hosts_test.exs
Code.require_file("packages/browser/browser_core.ex", ".")
Code.require_file("packages/browser/browser.ex", ".")

ExUnit.start()

defmodule BrowserDefaultHostsTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser

  @defaults [
    "genlayer.com",
    "docs.genlayer.com",
    "genlayerlabs.com",
    "www.genlayerlabs.com",
    "subzeroclaw.com",
    "genswarms.com",
    "unhardcoded.com",
    "www.unhardcoded.com"
  ]

  defp write!(hosts) do
    path = Path.join(System.tmp_dir!(), "default-hosts-#{System.unique_integer([:positive])}.txt")
    File.write!(path, Enum.join(hosts, "\n"))
    path
  end

  defp init!(over) do
    {:ok, st} = Browser.init(Map.merge(%{mode: :allowlist}, over))
    st
  end

  defp allow_set(%{policy: {:allow, set}}), do: set

  test "defaults union into a live file floor (every family site allowed)" do
    st = init!(%{allowlist_path: write!(["example.org"])})
    set = allow_set(st)

    assert MapSet.member?(set, "example.org")
    for h <- @defaults, do: assert(MapSet.member?(set, h), "missing default #{h}")

    # ...and the renderer's --allowed-domains string carries them too.
    assert st.allowed_domains =~ "genswarms.com"
  end

  test "www variants are present for the apex→www 308 sites (exact-host gate, re-gated redirects)" do
    st = init!(%{allowlist_path: write!(["example.org"])})
    assert MapSet.member?(allow_set(st), "www.genlayerlabs.com")
    assert MapSet.member?(allow_set(st), "www.unhardcoded.com")
  end

  test "the kill switch suppresses defaults too — an emptied file stops ALL browsing" do
    st = init!(%{allowlist_path: write!([])})
    assert st.floor_empty
    assert allow_set(st) == MapSet.new()
  end

  test "a missing file is the same kill switch (defaults never bootstrap a dead floor)" do
    st =
      init!(%{
        allowlist_path: "/tmp/default-hosts-missing-#{System.unique_integer([:positive])}.txt"
      })

    assert st.floor_empty
    assert allow_set(st) == MapSet.new()
  end

  test "config :default_hosts overrides the baked list; [] opts out (file-only floor)" do
    st = init!(%{allowlist_path: write!(["example.org"]), default_hosts: ["custom.example"]})
    assert MapSet.member?(allow_set(st), "custom.example")
    refute MapSet.member?(allow_set(st), "genlayer.com")

    st2 = init!(%{allowlist_path: write!(["example.org"]), default_hosts: []})
    assert allow_set(st2) == MapSet.new(["example.org"])
  end

  test "default hosts are normalized like any other floor entry" do
    st =
      init!(%{
        allowlist_path: write!(["example.org"]),
        default_hosts: ["  MiXeD.Example.  ", ""]
      })

    assert MapSet.member?(allow_set(st), "mixed.example")
    refute MapSet.member?(allow_set(st), "")
  end

  test "denylist mode ignores defaults (no positive list to extend)" do
    path = write!(["blocked.example"])
    {:ok, st} = Browser.init(%{mode: :denylist, blocklist_path: path})
    assert {:deny, set} = st.policy
    assert MapSet.member?(set, "blocked.example")
    assert st.allowed_domains == nil
  end
end

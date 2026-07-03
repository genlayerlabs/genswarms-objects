Code.require_file("packages/browser/browser_core.ex", ".")
Code.require_file("packages/browser/browser.ex", ".")

ExUnit.start()

defmodule BrowserDenylistObjectTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser

  # A renderer stub that records the allowed_domains it was handed and returns a fixed page.
  defmodule RecorderRenderer do
    @behaviour Genswarms.Browser.Renderer
    def navigate(url, _session, allowed) do
      send(self(), {:allowed_domains, allowed})
      {:ok, %{landed_url: url, text: "hello"}}
    end
    def act(_v, _a, _s), do: {:ok, %{landed_url: "https://ok.example/", text: "hi"}}
    def close(_s), do: :ok
  end

  defp write!(path, lines) do
    File.write!(path, Enum.join(lines, "\n"))
    path
  end

  test "denylist init builds a deny policy and passes nil allowed_domains" do
    block = write!("/tmp/blk.txt", ["bit.ly"])
    {:ok, st} =
      Browser.init(%{
        mode: :denylist,
        blocklist_path: block,
        renderer: RecorderRenderer,
        resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end
      })
    assert st.allowed_domains == nil
    assert {:deny, _} = st.policy
  end

  test "denylist unreadable blocklist fails closed (blocks everything)" do
    {:ok, st} =
      Browser.init(%{
        mode: :denylist,
        blocklist_path: "/tmp/does-not-exist-#{System.unique_integer([:positive])}.txt",
        renderer: RecorderRenderer,
        resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end
      })
    # fail-closed policy = an empty allow set = nothing passes
    assert {:allow, set} = st.policy
    assert MapSet.size(set) == 0
  end

  test "allowlist mode unchanged: builds allow policy + non-nil allowed_domains" do
    allow = write!("/tmp/alw.txt", ["genlayer.com"])
    {:ok, st} =
      Browser.init(%{
        mode: :allowlist,
        allowlist_path: allow,
        renderer: RecorderRenderer,
        resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end
      })
    assert {:allow, _} = st.policy
    assert is_binary(st.allowed_domains)
  end
end

Code.require_file("packages/browser/browser_core.ex", ".")

ExUnit.start()

defmodule BrowserPreflightPinTest do
  use ExUnit.Case, async: true
  alias Genswarms.Browser.Core

  test "head_args pins the vetted IP via --resolve host:port:ip" do
    args = Core.head_args("https://example.com/x", "1.2.3.4")
    assert "--resolve" in args
    assert "example.com:443:1.2.3.4" in args
    # the URL is still the last positional arg (curl connects to the pinned IP for that host)
    assert List.last(args) == "https://example.com/x"
  end

  test "resolve_and_pin rejects a host that resolves to a private IP" do
    priv = fn _ -> {:ok, [{10, 0, 0, 5}]} end
    assert {:error, :internal_ip} = Core.resolve_and_pin("internal.example", priv)
  end

  test "resolve_and_pin rejects the whole host on ANY private address (mixed records)" do
    mixed = fn _ -> {:ok, [{93, 184, 216, 34}, {169, 254, 169, 254}]} end
    assert {:error, :internal_ip} = Core.resolve_and_pin("rebind.example", mixed)
  end

  test "resolve_and_pin returns the pinned ip string for an all-public host" do
    pub = fn _ -> {:ok, [{93, 184, 216, 34}]} end
    assert {:ok, "93.184.216.34"} = Core.resolve_and_pin("example.com", pub)
  end
end

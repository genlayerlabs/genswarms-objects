Code.require_file("packages/browser/browser_core.ex", ".")

ExUnit.start()

defmodule BrowserPolicyGateTest do
  use ExUnit.Case, async: true
  alias Genswarms.Browser.Core

  # resolver stub: everything resolves to a public IP unless the host says otherwise
  defp public(_host), do: {:ok, [{93, 184, 216, 34}]}

  test "allow policy: member passes, non-member rejected" do
    pol = {:allow, MapSet.new(["genlayer.com"])}
    assert Core.gate("https://genlayer.com/x", pol, &public/1) == :ok
    assert {:error, {:not_allowed, _}} = Core.gate("https://evil.com/x", pol, &public/1)
  end

  test "deny policy: blocked host rejected, everything else passes SSRF-permitting" do
    pol = {:deny, MapSet.new(["bit.ly"])}
    assert {:error, {:not_allowed, _}} = Core.gate("https://bit.ly/x", pol, &public/1)
    assert {:error, {:not_allowed, _}} = Core.gate("https://www.bit.ly/x", pol, &public/1)
    assert Core.gate("https://anything-else.com/x", pol, &public/1) == :ok
  end

  test "deny policy still enforces SSRF (private IP rejected even if not on blocklist)" do
    pol = {:deny, MapSet.new(["bit.ly"])}
    priv = fn _ -> {:ok, [{127, 0, 0, 1}]} end
    assert {:error, {:internal_ip, _, _}} = Core.gate("https://internal.example/x", pol, priv)
  end
end

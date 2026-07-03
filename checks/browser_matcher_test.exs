Code.require_file("packages/browser/browser_core.ex", ".")

ExUnit.start()

defmodule BrowserMatcherTest do
  use ExUnit.Case, async: true
  alias Genswarms.Browser.Core

  @block MapSet.new(["bit.ly", "t.co"])

  test "normalize_host lowercases and strips one trailing dot" do
    assert Core.normalize_host("Bit.LY.") == "bit.ly"
  end

  test "punycode host normalizes to ascii" do
    # xn--nxasmq6b == the ascii form of a unicode label; normalize keeps ascii ascii
    assert Core.normalize_host("EXAMPLE.com") == "example.com"
  end

  test "blocked? matches apex and subdomains on a label boundary" do
    assert Core.blocked?("bit.ly", @block)
    assert Core.blocked?("www.bit.ly", @block)
    assert Core.blocked?("BIT.LY.", @block)
  end

  test "blocked? does NOT match a lookalike that only string-suffixes" do
    refute Core.blocked?("notbit.ly", @block)
  end

  test "blocked? is false for unrelated hosts" do
    refute Core.blocked?("genlayer.com", @block)
  end
end

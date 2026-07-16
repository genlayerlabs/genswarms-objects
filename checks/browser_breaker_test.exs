Code.require_file("packages/browser/browser_core.ex", ".")

ExUnit.start()

defmodule BrowserBreakerTest do
  use ExUnit.Case, async: true
  alias Genswarms.Browser.Core

  @threshold 3
  @cooldown 60_000

  defp fold(outcomes, now) do
    Enum.reduce(outcomes, {0, nil}, fn o, {streak, _open} ->
      Core.register_render(o, streak, @threshold, @cooldown, now)
    end)
  end

  test "opens only after `threshold` consecutive timeouts" do
    {s1, o1} = fold([:timeout], 1_000)
    assert {s1, o1} == {1, nil}
    assert Core.breaker_open?(o1, 1_000) == false

    {_s2, o2} = fold([:timeout, :timeout], 1_000)
    assert Core.breaker_open?(o2, 1_000) == false

    {_s3, o3} = fold([:timeout, :timeout, :timeout], 1_000)
    assert o3 == 1_000 + @cooldown
    assert Core.breaker_open?(o3, 1_000) == true
  end

  test "open window expires after the cooldown" do
    {_s, open_until} = fold([:timeout, :timeout, :timeout], 1_000)
    assert Core.breaker_open?(open_until, open_until - 1) == true
    assert Core.breaker_open?(open_until, open_until) == false
    assert Core.breaker_open?(open_until, open_until + 1) == false
  end

  test "a success closes the breaker and resets the streak" do
    # two timeouts then a success — streak back to 0, not armed
    {streak, open} = fold([:timeout, :timeout, :ok], 1_000)
    assert {streak, open} == {0, nil}
    refute Core.breaker_open?(open, 1_000)
  end

  test "after cooldown a single fresh timeout re-opens (streak was not reset while open)" do
    # 3 timeouts arm it; the failfast path records no outcome, so a real attempt
    # after cooldown is the 4th timeout → streak 4 >= threshold → re-open.
    {streak, _} = fold([:timeout, :timeout, :timeout], 1_000)
    {streak2, open2} = Core.register_render(:timeout, streak, @threshold, @cooldown, 70_000)
    assert streak2 == 4
    assert open2 == 70_000 + @cooldown
  end

  test "a non-timeout outcome (fast crash/http error) leaves the breaker untouched" do
    {streak, open} = Core.register_render(:other, 2, @threshold, @cooldown, 1_000)
    assert {streak, open} == {2, nil}
  end

  test "nil open_until is never open" do
    refute Core.breaker_open?(nil, 999_999)
  end
end

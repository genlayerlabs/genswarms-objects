# Integration test for the render circuit breaker WIRING in the browse object
# (browser.ex): do_render fast-fails when the breaker is open, note_render folds
# render outcomes into state, and a success closes it. The pure decision is
# covered separately in browser_breaker_test.exs — this pins that browser.ex
# actually uses it (state threading + the fast-fail path skips the renderer).
#
#   mix run checks/browser_breaker_wiring_test.exs
Code.require_file("packages/browser/browser_core.ex", ".")
Code.require_file("packages/browser/browser.ex", ".")

ExUnit.start()

# A renderer that returns whatever it's told and counts navigate calls, so a
# test can prove the fast-fail path never dispatches.
defmodule MockCountingRenderer do
  @behaviour Genswarms.Browser.Renderer
  @counter :breaker_wiring_navcount

  def start! do
    if Process.whereis(@counter) == nil,
      do: {:ok, _} = Agent.start_link(fn -> {0, {:error, :render_timeout}} end, name: @counter)

    :ok
  end

  def set_result(r), do: Agent.update(@counter, fn {n, _} -> {n, r} end)
  def navigate_count, do: Agent.get(@counter, fn {n, _} -> n end)
  def reset!, do: Agent.update(@counter, fn {_, r} -> {0, r} end)

  @impl true
  def navigate(_u, _s, _a) do
    Agent.get_and_update(@counter, fn {n, r} -> {r, {n + 1, r}} end)
  end

  @impl true
  def act(_v, _a, _s), do: {:ok, %{landed_url: "https://allowed.example.com/l", text: "hi"}}
  @impl true
  def close(_s), do: :ok
end

defmodule BrowserBreakerWiringTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser

  @url "https://allowed.example.com/p"

  defp fresh_state do
    :ok = MockCountingRenderer.start!()
    MockCountingRenderer.reset!()

    allow = Path.join(System.tmp_dir!(), "brk_#{System.unique_integer([:positive])}.txt")
    File.write!(allow, "allowed.example.com\n")
    on_exit(fn -> File.rm(allow) end)

    {:ok, st} =
      Browser.init(%{
        allowlist_path: allow,
        renderer: MockCountingRenderer,
        resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
        redirect_fetcher: fn _ -> {200, nil} end,
        render_breaker_threshold: 3,
        render_breaker_cooldown_ms: 60_000,
        now_fn: fn -> 0 end
      })

    st
  end

  defp render(st) do
    {:reply, json, st2} = Browser.handle_message(:agentA, ~s({"action":"render","url":"#{@url}"}), st)
    {Jason.decode!(json), st2}
  end

  test "three render timeouts open the breaker; the 4th fails fast without dispatching" do
    st = fresh_state()
    MockCountingRenderer.set_result({:error, :render_timeout})

    # three real attempts — each dispatches (navigate) and returns render_failed
    st =
      Enum.reduce(1..3, st, fn _, acc ->
        {reply, acc2} = render(acc)
        assert reply == %{"error" => "render_failed"}
        acc2
      end)

    assert MockCountingRenderer.navigate_count() == 3
    assert st.render_fail_streak == 3
    assert st.breaker_open_until == 60_000

    # breaker is open (now=0 < 60_000): the 4th fails fast, renderer NOT called
    {reply, _st} = render(st)
    assert reply == %{"error" => "render_unavailable"}
    assert MockCountingRenderer.navigate_count() == 3, "fast-fail must not dispatch to the renderer"
  end

  test "a success before the threshold resets the streak and never opens" do
    st = fresh_state()

    MockCountingRenderer.set_result({:error, :render_timeout})
    {_r, st} = render(st)
    {_r, st} = render(st)
    assert st.render_fail_streak == 2
    assert st.breaker_open_until == nil

    MockCountingRenderer.set_result({:ok, %{landed_url: "https://allowed.example.com/l", text: "ok"}})
    {reply, st} = render(st)
    assert Map.has_key?(reply, "url")
    assert st.render_fail_streak == 0
    assert st.breaker_open_until == nil
  end
end

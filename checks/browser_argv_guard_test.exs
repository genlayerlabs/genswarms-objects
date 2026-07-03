# Unit tests for the browse object's argv-injection guard (L9, audit 2026-07-02): a
# `type` action's `text` is REJECTED at the browse.ex validation layer — before it ever
# reaches browse_core.ex's `verb_args(:type, …)` and becomes an agent-browser argv
# element — when it is a single, whitespace-free token starting with `-`. That is the
# one shape agent-browser (pinned 0.27.1, CONFIRMED) hoists into its OWN global CLI flag
# (e.g. a type text of "--json" flips agent-browser's own output format to JSON). The
# audit's originally-suggested `--` argv terminator does NOT work against agent-browser
# 0.27.1 (it still hoists a later --json) — so the fix is this Wingston-side guard, not
# argv plumbing. Decision: REJECT, not sanitize — the agent gets a clear, retryable
# bad_arg error, never a silently-mangled text.
#
# These are PURE shaping tests (mock renderer, injected resolver/fetcher — no network,
# no agent-browser, no live Chromium), matching the style of tests/browse_compact_test.exs.
# The "rejected" mock's act/3 RAISES if invoked, so if the guard ever regresses (a
# flag-shaped text reaches the renderer), the test fails loudly instead of silently
# passing.
#
#   mix run tests/browse_argv_guard_test.exs
ExUnit.start()
# act/3 must NEVER be called when the guard correctly rejects a flag-shaped text.
defmodule MockNoAct do
  @behaviour Genswarms.Browser.Renderer
  @impl true
  def navigate(_u, _s, _a), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: "hi"}}
  @impl true
  def act(_verb, _arg, _s),
    do: raise("act/3 must not be called — the argv guard should have rejected this arg before dispatch")
  @impl true
  def close(_s), do: :ok
end

# Records the args a benign `type` reached the renderer with, so tests can assert the
# whole text arrived intact (single argv element, unmangled — no sanitizing happened).
# render_sync/2 runs the renderer callback inside a SPAWNED worker process, so a plain
# Process dictionary wouldn't be visible back in the test process — use a named Agent.
defmodule MockRecordAct do
  @behaviour Genswarms.Browser.Renderer
  @recorder :browse_argv_guard_recorder

  def start_recorder! do
    if Process.whereis(@recorder) == nil, do: {:ok, _} = Agent.start_link(fn -> nil end, name: @recorder)
    :ok
  end

  def reset!, do: Agent.update(@recorder, fn _ -> nil end)
  def last_arg, do: Agent.get(@recorder, & &1)

  @impl true
  def navigate(_u, _s, _a), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: "hi"}}
  @impl true
  def act(_verb, arg, _s) do
    Agent.update(@recorder, fn _ -> arg end)
    {:ok, %{landed_url: "https://allowed.example.com/landed", text: "typed:#{arg[:text]}"}}
  end
  @impl true
  def close(_s), do: :ok
end

defmodule GenswarmsBrowserArgvGuardTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser

  @url "https://allowed.example.com/p"

  defp state_for(renderer) do
    allow = Path.join(System.tmp_dir!(), "browse_argv_guard_allow_#{System.unique_integer([:positive])}.txt")
    File.write!(allow, "allowed.example.com\n")
    on_exit(fn -> File.rm(allow) end)

    {:ok, st} =
      Browser.init(%{
        allowlist_path: allow,
        renderer: renderer,
        # injected — no DNS, no curl, no browser
        resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
        redirect_fetcher: fn _url -> {200, nil} end,
        now_fn: fn -> 0 end
      })

    st
  end

  # `type` needs a live session first, same as every other interactive action.
  defp with_session(renderer) do
    st = state_for(renderer)
    {:reply, _json, st2} = Browser.handle_message(:agentA, ~s({"action":"render","url":"#{@url}"}), st)
    st2
  end

  defp type_reply(st, text) do
    body = Jason.encode!(%{"action" => "type", "ref" => "e39", "text" => text})
    Browser.handle_message(:agentA, body, st)
  end

  test "rejects the CONFIRMED repro ('--json') with a clear bad_arg error, never reaching the renderer" do
    st = with_session(MockNoAct)
    {:reply, json, _st} = type_reply(st, "--json")
    m = Jason.decode!(json)

    assert Map.has_key?(m, "error"), "expected an error reply, got: #{inspect(m)}"
    assert m["error"] =~ "bad_arg", "expected a bad_arg refusal, got: #{inspect(m["error"])}"
    assert m["error"] =~ "flag", "the error should explain WHY, so the agent can retry sanely"
  end

  test "rejects other single-token dash-leading shapes" do
    for text <- ["-v", "-", "--", "-1", "--verbose=1", "-x", "---"] do
      st = with_session(MockNoAct)
      {:reply, json, _st} = type_reply(st, text)
      m = Jason.decode!(json)

      assert Map.has_key?(m, "error"), "text #{inspect(text)} should have been rejected"
      assert m["error"] =~ "bad_arg", "text #{inspect(text)}: expected bad_arg, got #{inspect(m["error"])}"
    end
  end

  test "the refusal is a normal, readable error reply — not a crash" do
    st = with_session(MockNoAct)
    assert {:reply, json, new_state} = type_reply(st, "--json")
    assert %{"error" => msg} = Jason.decode!(json)
    assert is_binary(msg)
    # the session survives a refused arg (the agent can immediately retry with better text)
    assert Map.has_key?(new_state.sessions, :agentA)
  end

  test "allows benign multi-word dash-leading text through unmangled (can't hoist as one argv element)" do
    MockRecordAct.start_recorder!()

    for text <- ["-- hello world", "-1 apples, please", "hello -world", "a - b - c", "- leading space after dash"] do
      st = with_session(MockRecordAct)
      MockRecordAct.reset!()
      {:reply, json, _st} = type_reply(st, text)
      m = Jason.decode!(json)

      refute Map.has_key?(m, "error"), "benign multi-word text #{inspect(text)} was wrongly rejected: #{inspect(m)}"
      assert %{text: ^text} = MockRecordAct.last_arg(), "text must reach the renderer WHOLE, unsanitized"
    end
  end

  test "allows text that merely contains a dash mid-string" do
    MockRecordAct.start_recorder!()
    MockRecordAct.reset!()
    st = with_session(MockRecordAct)
    {:reply, json, _st} = type_reply(st, "self-driving cars")
    m = Jason.decode!(json)

    refute Map.has_key?(m, "error")
    assert %{text: "self-driving cars"} = MockRecordAct.last_arg()
  end

  test "allows ordinary text with no leading dash (regression: existing behavior untouched)" do
    MockRecordAct.start_recorder!()
    MockRecordAct.reset!()
    st = with_session(MockRecordAct)
    {:reply, json, _st} = type_reply(st, "search words")
    m = Jason.decode!(json)

    refute Map.has_key?(m, "error")
    assert %{text: "search words"} = MockRecordAct.last_arg()
  end

  test "still enforces the existing ref-shape and length checks (guard is additive, not a replacement)" do
    st = with_session(MockNoAct)
    body = Jason.encode!(%{"action" => "type", "ref" => "not-a-ref", "text" => "benign text"})
    {:reply, json, _st} = Browser.handle_message(:agentA, body, st)
    m = Jason.decode!(json)

    assert m["error"] == "bad_arg", "malformed ref should still hit the generic bad_arg path"
  end
end

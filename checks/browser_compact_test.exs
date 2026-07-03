# Unit tests for the browse object's COMPACT-reply shaping (the context-bloat fix).
#
# WHY: browse used to return the WHOLE rendered page inline, so every browsed page
# stayed in the agent's conversation history forever — the accumulated-context bloat
# that makes tool-capable models waste turns or stall. The object now returns a
# COMPACT reply by default (head of the main body + the nav-link index + size), and
# the full body ONLY when the agent asks {"full":true} — which it redirects to its own
# workspace file and greps, so the page never re-enters context.
#
# These cover the PURE shaping (mock renderer, injected resolver/fetcher — no network,
# no agent-browser). The real renderer is exercised by tests/browse_live.exs.
#
#   mix run tests/browse_compact_test.exs
ExUnit.start()
# A page whose MAIN body is long enough to be truncated by a small head_chars, with a
# unique token PAST the head, plus the renderer's nav-link index appended at the tail
# (the "--- Other links on this page ---" section browse must preserve for navigation).
defmodule MockLong do
  @behaviour Genswarms.Browser.Renderer
  @text "TITLE-Foo\n" <>
          String.duplicate("MAINBODY ", 50) <>
          "DEEPMARKER-past-the-head" <>
          "\n\n--- Other links on this page (render a URL to go there) ---\n" <>
          "- GenVM — https://docs.example.com/genvm\n- Other — https://docs.example.com/other"
  def text, do: @text
  @impl true
  def navigate(_u, _s, _a), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: @text}}
  @impl true
  def act(_v, _a, _s), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: @text}}
  @impl true
  def close(_s), do: :ok
end

# A page shorter than head_chars and with no nav index — the whole thing fits in head.
defmodule MockShort do
  @behaviour Genswarms.Browser.Renderer
  @text "tiny page, no nav, fits in head"
  def text, do: @text
  @impl true
  def navigate(_u, _s, _a), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: @text}}
  @impl true
  def act(_v, _a, _s), do: {:ok, %{landed_url: "https://allowed.example.com/landed", text: @text}}
  @impl true
  def close(_s), do: :ok
end

defmodule GenswarmsBrowserCompactTest do
  use ExUnit.Case, async: false
  alias Genswarms.Browser

  @url "https://allowed.example.com/p"

  defp state_for(renderer, head_chars) do
    allow = Path.join(System.tmp_dir!(), "browse_compact_allow_#{System.unique_integer([:positive])}.txt")
    File.write!(allow, "allowed.example.com\n")
    on_exit(fn -> File.rm(allow) end)

    {:ok, st} =
      Browser.init(%{
        allowlist_path: allow,
        untrusted_tag: "rally_data",
        renderer: renderer,
        # injected — no DNS, no curl, no browser
        resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
        redirect_fetcher: fn _url -> {200, nil} end,
        head_chars: head_chars,
        now_fn: fn -> 0 end
      })

    st
  end

  defp render(st, body \\ ~s({"action":"render","url":"#{@url}"})) do
    {:reply, json, _st} = Browser.handle_message(:agentA, body, st)
    Jason.decode!(json)
  end

  test "default render is COMPACT: head (not full text), bytes, and the body is truncated" do
    m = render(state_for(MockLong, 100))

    assert Map.has_key?(m, "head"), "compact reply must carry :head"
    refute Map.has_key?(m, "text"), "compact reply must NOT carry the full :text"
    assert m["head"] =~ "TITLE-Foo"
    refute m["head"] =~ "DEEPMARKER-past-the-head", "the deep body must be cut from the head"
    assert m["bytes"] == byte_size(MockLong.text())
    assert m["url"] == "https://allowed.example.com/landed"
    # a hint telling the agent how to get the rest, since the body was truncated — and it
    # MUST teach the jq-extract (a raw `> file` redirect greps the one-line JSON envelope
    # as one blob and re-floods context, defeating the whole change).
    assert Map.has_key?(m, "more")
    assert m["more"] =~ "jq -r '.result.text'"
    assert m["more"] =~ "/workspace/page.txt"
    # the grep term must be an obvious fill-in placeholder, NOT a literal token the agent
    # copies verbatim (live test: the agent ran `grep -i WORD …`, which matches nothing).
    assert m["more"] =~ "<search-term>"
    refute m["more"] =~ "grep -i WORD"
  end

  test "compact reply PRESERVES the nav-link index (navigation surface), wrapped untrusted" do
    m = render(state_for(MockLong, 100))

    assert Map.has_key?(m, "links"), "compact reply must keep the nav-link index"
    assert m["links"] =~ "https://docs.example.com/genvm"
    assert m["links"] =~ "rally_data"
  end

  test "compact head is wrapped in the untrusted tag" do
    m = render(state_for(MockLong, 100))
    assert m["head"] =~ "<rally_data>"
    assert m["head"] =~ "</rally_data>"
  end

  test "full:true returns the whole body as :text (historical shape), no :head" do
    st = state_for(MockLong, 100)
    m = render(st, ~s({"action":"render","url":"#{@url}","full":true}))

    assert Map.has_key?(m, "text"), "full reply carries the whole body as :text"
    refute Map.has_key?(m, "head")
    assert m["text"] =~ "DEEPMARKER-past-the-head", "full body present"
    assert m["text"] =~ "https://docs.example.com/genvm", "nav present too"
    assert m["text"] =~ "rally_data"
  end

  test "a short page fits entirely in the compact head — no nav, no truncation hint" do
    m = render(state_for(MockShort, 2_000))

    assert m["head"] =~ "tiny page, no nav"
    refute Map.has_key?(m, "links")
    refute Map.has_key?(m, "more")
    refute Map.has_key?(m, "text")
  end

  test "the full flag works on an interactive action too (click full:true)" do
    st = state_for(MockLong, 100)
    # one render establishes the per-asker session the click then acts on
    st2 = elem(Browser.handle_message(:agentA, ~s({"action":"render","url":"#{@url}"}), st), 2)

    m_compact = Browser.handle_message(:agentA, ~s({"action":"click","ref":"e5"}), st2) |> elem(1) |> Jason.decode!()
    assert Map.has_key?(m_compact, "head")
    refute Map.has_key?(m_compact, "text")

    m_full = Browser.handle_message(:agentA, ~s({"action":"click","ref":"e5","full":true}), st2) |> elem(1) |> Jason.decode!()
    assert Map.has_key?(m_full, "text")
    assert m_full["text"] =~ "DEEPMARKER-past-the-head"
  end
end

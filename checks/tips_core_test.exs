# Tips core: pure pool/rotation/assembly logic. Standalone — no store, no network:
#   mix run checks/tips_core_test.exs
ExUnit.start()

defmodule TipsCoreFragmentTest do
  use ExUnit.Case, async: false
  alias Genswarms.Tips.Core

  test "fragment/3 builds defaults and a deterministic content-addressed id" do
    f = Core.fragment("body", "Write your last line first.")
    assert f.kind == "body"
    assert f.text == "Write your last line first."
    assert f.status == "pending"
    assert f.source == "generated"
    assert f.weight == 1
    assert f.category == nil
    assert f.id == Core.fragment_id("body", "Write your last line first.")
    assert String.length(f.id) == 16
    # same (kind, text) => same id; different kind => different id
    assert f.id == Core.fragment("body", "Write your last line first.").id
    refute f.id == Core.fragment("opener", "Write your last line first.").id
  end

  test "fragment/3 honors opts" do
    f = Core.fragment("closer", "", category: "signoff", weight: 5, status: "live", source: "seed")
    assert %{category: "signoff", weight: 5, status: "live", source: "seed", text: ""} = f
  end
end

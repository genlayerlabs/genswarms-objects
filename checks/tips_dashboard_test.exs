# Tips dashboard surface (probed extension over the durable fragment/seen tables).
#
#   mix run checks/tips_dashboard_test.exs
ExUnit.start()

defmodule Genswarms.TipsDashboardStore do
  def load_fragments do
    [
      %{id: "a1", kind: "opener", text: "x"},
      %{id: "b2", kind: "body", text: "y"},
      %{id: "c3", kind: "body", text: "z"}
    ]
  end

  def load_seen, do: %{"tg:1:0" => ["a1", "b2"], "tg:2:0" => ["c3"]}
end

defmodule Genswarms.TipsDashboardTest do
  use ExUnit.Case

  test "no store -> inert extension" do
    assert Genswarms.Tips.dashboard_extension([]) == %{}
  end

  test ":store_mod is the canonical opt name (INTEGRATING.md); :store stays as alias" do
    canonical = Genswarms.Tips.dashboard_extension(store_mod: Genswarms.TipsDashboardStore)
    legacy = Genswarms.Tips.dashboard_extension(store: Genswarms.TipsDashboardStore)
    assert canonical == legacy
    assert %{"dashboard_pages" => [_page]} = canonical
  end

  test "with a store -> pool metrics page (fragments, recipients, seen, per-kind)" do
    %{"dashboard_pages" => [page]} =
      Genswarms.Tips.dashboard_extension(store: Genswarms.TipsDashboardStore)

    assert page["id"] == "tips-pool"
    [%{"type" => "metrics", "items" => items}] = page["sections"]
    get = fn label -> Enum.find(items, &(&1["label"] == label))["value"] end
    assert get.("Fragments") == 3
    assert get.("Recipients") == 2
    assert get.("Seen marks") == 3
    assert get.("body") == 2
    assert get.("opener") == 1
  end

  test "a dead store never raises out of the extension" do
    assert %{"dashboard_pages" => [page]} = Genswarms.Tips.dashboard_extension(store: Nope)
    [%{"items" => items}] = page["sections"]
    assert Enum.find(items, &(&1["label"] == "Fragments"))["value"] == 0
  end
end

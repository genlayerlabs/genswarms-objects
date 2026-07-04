# Metrics display wire: LIVE emit contract (telemetry attach, not a source grep).
# Standalone — no store, no network:  mix run checks/metrics_display_test.exs
ExUnit.start()
Code.require_file("support/display_wire_helper.exs", __DIR__)

defmodule GenswarmsMetricsDisplayTest do
  use ExUnit.Case, async: false
  alias Genswarms.Metrics

  defp bump(state) do
    Metrics.handle_message(:sender, Jason.encode!(%{"action" => "bump", "key" => "reply_sent"}), state)
  end

  test "a bump emits chatter on the DEFAULT wire" do
    DisplayWireHelper.attach!([:genswarms, :display])
    {:ok, state} = Metrics.init(%{flush_ms: 0})

    {:noreply, _state} = bump(state)

    assert_receive {:display_event, %{kind: :chatter, from: "sender", to: "metrics"}}
  end

  test "a host override on :genswarms_objects :display_wire redirects the emit" do
    Application.put_env(:genswarms_objects, :display_wire, [:acme, :display])
    on_exit(fn -> Application.delete_env(:genswarms_objects, :display_wire) end)

    DisplayWireHelper.attach!([:acme, :display])
    {:ok, state} = Metrics.init(%{flush_ms: 0})

    {:noreply, _state} = bump(state)

    assert_receive {:display_event, %{kind: :chatter, from: "sender", to: "metrics"}}
  end

  test "a raising display consumer never breaks the bump itself" do
    DisplayWireHelper.attach_raising!([:genswarms, :display])
    {:ok, state} = Metrics.init(%{flush_ms: 0})

    {:noreply, state} = bump(state)

    assert state.totals["reply_sent"] == 1
  end
end

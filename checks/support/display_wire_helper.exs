# Shared attach-and-collect helper for display-wire emit tests.
# Usage (from a standalone check):
#   Code.require_file("support/display_wire_helper.exs", __DIR__)
#   handler = DisplayWireHelper.attach!([:genswarms, :display])
#   ... exercise the package ...
#   assert_receive {:display_event, %{kind: :my_kind}}
# Detach happens automatically at test exit (on_exit).
defmodule DisplayWireHelper do
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Attach a collector to `topic`; events arrive as {:display_event, meta}."
  def attach!(topic) do
    id = "display-wire-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(id, topic, fn _topic, _measure, meta, _cfg ->
      send(test, {:display_event, meta})
    end, nil)

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  @doc "Attach a handler that raises — proves emit sites survive a bad consumer."
  def attach_raising!(topic) do
    id = "display-wire-raising-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, topic, fn _t, _m, _meta, _c -> raise "bad handler" end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
    id
  end
end

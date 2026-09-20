ExUnit.start()

defmodule GenLayerObjectTest do
  use ExUnit.Case

  test "actual bundled runtime, sender checks and asynchronous describe delivery" do
    root = Path.join(System.tmp_dir!(), "genlayer-handler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    master = Path.join(root, "master")
    File.write!(master, :crypto.strong_rand_bytes(32))
    File.chmod!(master, 0o600)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, state} = Genswarms.GenLayer.init(%{"swarm_id" => "check", "agents" => ["alice", "bob"], "storage_dir" => Path.join(root, "vault"), "master_key_file" => master})
    on_exit(fn -> if Port.info(state.port), do: Port.close(state.port) end)
    ready = receive do
      message ->
        {:noreply, ready} = Genswarms.GenLayer.handle_info(message, state)
        ready
    after
      10_000 -> flunk("runtime did not initialize")
    end
    assert ready.ready
    {:reply, denied, _} = Genswarms.GenLayer.handle_message(:mallory, ~s({"action":"describe"}), ready)
    assert Jason.decode!(denied)["ok"] == false
    {:reply, ack, pending} = Genswarms.GenLayer.handle_message(:alice, ~s({"action":"describe"}), ready)
    id = Jason.decode!(ack)["request_id"]
    completed = receive do
      message ->
        {:send, :alice, reply, completed} = Genswarms.GenLayer.handle_info(message, pending)
        response = Jason.decode!(reply)
        assert response["ok"]
        assert response["result"]["interface_version"] == 1
        assert response["result"]["wallet"] == nil
        assert response["result"]["write_enabled"] == false
        completed
    after
      10_000 -> flunk("runtime did not answer")
    end
    {:reply, own, _} = Genswarms.GenLayer.handle_message(:alice, Jason.encode!(%{action: "result", request_id: id}), completed)
    assert Jason.decode!(own)["ok"]
    {:reply, foreign, _} = Genswarms.GenLayer.handle_message(:bob, Jason.encode!(%{action: "result", request_id: id}), completed)
    refute Jason.decode!(foreign)["ok"]
    Genswarms.GenLayer.terminate(:normal, completed)
  end
end

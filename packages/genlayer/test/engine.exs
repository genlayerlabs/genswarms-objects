# Run in a GenSwarms host: mix run --no-start /path/to/this/file
Application.put_env(:genswarms, :load_dotenv, false)
Application.ensure_all_started(:genswarms)
Code.require_file("../genlayer.ex", __DIR__)

defmodule GenLayerProbeSink do
  def init(config), do: {:ok, config}
  def interface, do: %{}
  def handle_message(from, content, state) do
    send(state.owner, {:probe, from, Jason.decode!(content)})
    {:noreply, state}
  end
end
root = Path.join(System.tmp_dir!(), "genlayer-engine-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
File.chmod!(root, 0o700)
master = Path.join(root, "master")
File.write!(master, :crypto.strong_rand_bytes(32))
File.chmod!(master, 0o600)
swarm = "genlayer-probe-#{System.unique_integer([:positive])}"
config = %{"swarm_id" => swarm, "agents" => ["alice", "bob"], "storage_dir" => Path.join(root, "vault"), "master_key_file" => master}
{:ok, genlayer} = Genswarms.Objects.ObjectServer.start_link(name: :genlayer, swarm_name: swarm, handler: Genswarms.GenLayer, config: config)
{:ok, alice} = Genswarms.Objects.ObjectServer.start_link(name: :alice, swarm_name: swarm, handler: GenLayerProbeSink, config: %{owner: self()})
Genswarms.Routing.Router.register_topology(swarm, [{:alice, :genlayer}, {:genlayer, :alice}])
try do
  Enum.reduce_while(1..100, nil, fn _, _ ->
    if :sys.get_state(genlayer).handler_state.ready do
      {:halt, :ok}
    else
      Process.sleep(20)
      {:cont, nil}
    end
  end)
  true = :sys.get_state(genlayer).handler_state.ready
  Genswarms.Routing.Router.route(swarm, :alice, :genlayer, ~s({"action":"describe"}))
  receive do
    {:probe, :genlayer, %{"status" => "accepted"}} -> :ok
  after
    5000 -> raise "no routed acknowledgement"
  end
  receive do
    {:probe, :genlayer, %{"ok" => true, "result" => %{"interface_version" => 1, "chain_id" => 4221}}} -> :ok
  after
    5000 -> raise "no routed result"
  end
  IO.puts("PASS: real ObjectServer + Router + bundled runtime + schema discovery")
after
  GenServer.stop(genlayer)
  GenServer.stop(alice)
  Genswarms.Routing.Router.unregister_topology(swarm)
  File.rm_rf!(root)
end

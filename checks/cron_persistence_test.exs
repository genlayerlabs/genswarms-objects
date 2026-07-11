# Cron save failures degrade to observable in-memory scheduling.

alias Genswarms.Cron

defmodule CronPersistenceStore do
  def start, do: Agent.start_link(fn -> :ok end, name: __MODULE__)
  def mode(mode), do: Agent.update(__MODULE__, fn _ -> mode end)

  def save_cron_job(_job) do
    case Agent.get(__MODULE__, & &1) do
      :ok -> :ok
      :error -> {:error, :db_down}
      :raise -> raise "db down"
      :throw -> throw(:db_down)
      :exit -> exit(:db_down)
    end
  end
end

defmodule CronPersistencePartialStore do
end

defmodule CronPersistenceEvents do
  def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

  def object(object, type, message, opts),
    do: Agent.update(__MODULE__, &[{object, type, message, opts} | &1])

  def all, do: Agent.get(__MODULE__, &Enum.reverse/1)
end

{:ok, failures} = Agent.start_link(fn -> [] end)

check = fn name, condition ->
  if condition do
    IO.puts("  \e[32m✓\e[0m #{name}")
  else
    IO.puts("  \e[31m✗ #{name}\e[0m")
    Agent.update(failures, &[name | &1])
  end
end

IO.puts("\n══ Cron persistence degradation events ══\n")

{:ok, _store} = CronPersistenceStore.start()
{:ok, _events} = CronPersistenceEvents.start()
{:ok, clock} = Agent.start_link(fn -> 1_800_000_000_000 end)
{:ok, deliveries} = Agent.start_link(fn -> 0 end)

config = %{
  name: :cron,
  swarm_name: "persistence-test",
  auto_tick: false,
  async?: false,
  now_fn: fn -> Agent.get(clock, & &1) end,
  deliver_fn: fn _target, _from, _message ->
    Agent.update(deliveries, &(&1 + 1))
    :ok
  end,
  trusted_sources: [:ops],
  allowed_targets: %{worker: ["run"]},
  events_mod: CronPersistenceEvents
}

create = fn state, name ->
  Cron.handle_message(
    :ops,
    Jason.encode!(%{
      action: "create_job",
      name: name,
      schedule: %{every_ms: 60_000},
      target: "worker",
      message: %{action: "run", secret: "payload-secret"},
      origin: %{secret: "origin-secret"},
      dedupe_key: "persistence:test"
    }),
    state
  )
end

{:ok, memory_state} = Cron.init(config)
{:reply, _reply, _memory_state} = create.(memory_state, "memory only")
{:ok, partial_state} = Cron.init(Map.put(config, :store_mod, CronPersistencePartialStore))
{:reply, _reply, _partial_state} = create.(partial_state, "partial store")

check.(
  "missing Store or save callback stays silent memory-only mode",
  CronPersistenceEvents.all() == []
)

CronPersistenceEvents.reset()
CronPersistenceStore.mode(:error)
{:ok, state} = Cron.init(Map.put(config, :store_mod, CronPersistenceStore))
{:reply, create_reply, state} = create.(state, "durable job")
job_id = Jason.decode!(create_reply)["job_id"]

[{_, :job_persistence_failed, _, failed_opts}] = CronPersistenceEvents.all()
failed_metadata = failed_opts[:metadata]

check.(
  "explicit save error keeps the job and emits one safe failure event",
  Map.has_key?(state.jobs, job_id) and
    failed_metadata == %{
      operation: :save_cron_job,
      job_id: job_id,
      name: "durable job",
      dedupe_key: "persistence:test"
    }
)

Agent.update(clock, &(&1 + 60_000))

{:reply, _tick_reply, state} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "tick"}), state)

check.(
  "repeated failed saves stay debounced while the in-memory job still fires",
  Enum.count(CronPersistenceEvents.all(), &(elem(&1, 1) == :job_persistence_failed)) == 1 and
    Agent.get(deliveries, & &1) == 1
)

CronPersistenceStore.mode(:ok)

{:reply, _pause_reply, state} =
  Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: job_id}), state)

check.(
  "a later successful save emits one recovery event",
  CronPersistenceEvents.all()
  |> Enum.map(&elem(&1, 1))
  |> Enum.filter(&(&1 in [:job_persistence_failed, :job_persistence_recovered])) == [
    :job_persistence_failed,
    :job_persistence_recovered
  ]
)

state =
  Enum.reduce([:raise, :throw, :exit], state, fn failure_mode, state ->
    CronPersistenceStore.mode(failure_mode)

    {:reply, reply, state} =
      Cron.handle_message(:ops, Jason.encode!(%{action: "resume", job_id: job_id}), state)

    check.("#{failure_mode} from save is contained", Jason.decode!(reply)["ok"] == true)

    CronPersistenceStore.mode(:ok)

    {:reply, _reply, state} =
      Cron.handle_message(:ops, Jason.encode!(%{action: "pause", job_id: job_id}), state)

    state
  end)

event_types = Enum.map(CronPersistenceEvents.all(), &elem(&1, 1))

check.(
  "raise/throw/exit failures recover and re-arm future failure detection",
  Enum.count(event_types, &(&1 == :job_persistence_failed)) == 4 and
    Enum.count(event_types, &(&1 == :job_persistence_recovered)) == 4 and
    Map.fetch!(state.jobs, job_id).state == "paused"
)

case Agent.get(failures, &Enum.reverse/1) do
  [] ->
    IO.puts("\nCRON_PERSISTENCE: ALL PASS")

  failed ->
    Enum.each(failed, &IO.puts(" - #{&1}"))
    System.halt(1)
end

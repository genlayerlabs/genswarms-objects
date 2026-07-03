defmodule Genswarms.Cron do
  @moduledoc """
  Global deterministic scheduler object.

  This object is deliberately not market-scoped. A job is one due datetime plus
  one stamped message to one allowlisted target. It owns timing, concurrency,
  persistence, and audit; target objects still own domain authority.
  """

  require Logger

  alias Genswarms.Objects.ObjectServer
  alias Genswarms.Cron.Schedule
  # Events seam: optional events_mod (exports object/4, e.g. a LogStore wrapper);
  # absent -> Logger. Injected via config, resolved in init.

  @terminal_states ~w(done deleted failed)
  @load_states ~w(active paused running)

  def init(config) do
    store_mod = module_ref(Map.get(config, :store_mod))
    now_fn = Map.get(config, :now_fn, &Schedule.now_ms/0)
    now = now_fn.()

    jobs =
      store_call(store_mod, :load_cron_jobs, [@load_states], [])
      |> Enum.map(&normalize_loaded_job/1)
      |> Enum.map(&recover_running_job(&1, now))
      |> Map.new(fn job -> {job.id, job} end)

    state = %{
      name: Map.get(config, :name, :cron),
      swarm_name: Map.get(config, :swarm_name, "swarm"),
      sender: Map.get(config, :sender, :sender),
      runtime: Map.get(config, :runtime, nil),
      store_mod: store_mod,
      events_mod: module_ref(Map.get(config, :events_mod)),
      now_fn: now_fn,
      deliver_fn:
        Map.get(
          config,
          :deliver_fn,
          default_deliver_fn(Map.get(config, :swarm_name, "swarm"))
        ),
      auto_tick: Map.get(config, :auto_tick, true),
      timer_ref: nil,
      tick_ms: Map.get(config, :tick_ms, 60_000),
      max_concurrency: Map.get(config, :max_concurrency, 16),
      max_attempts: Map.get(config, :max_attempts, 3),
      retry_backoff_ms: Map.get(config, :retry_backoff_ms, 60_000),
      async?: Map.get(config, :async?, true),
      min_period_ms: Map.get(config, :min_period_ms, 60_000),
      jobs: jobs,
      tasks: %{},
      next_id: max(store_call(store_mod, :max_cron_job_id, [], 0) + 1, next_memory_id(jobs)),
      # Fail-closed defaults: with no configured allowlists NOBODY can create
      # jobs and NO target is deliverable — the host declares both (pure data).
      trusted_sources:
        MapSet.new(Map.get(config, :trusted_sources, []) |> Enum.map(&to_string/1)),
      allowed_targets:
        normalize_allowed_targets(Map.get(config, :allowed_targets, %{}))
    }

    if map_size(jobs) > 0 do
      Logger.info("[cron] loaded #{map_size(jobs)} active/paused/recovered job(s)")
    end

    {:ok, arm_timer(state, now)}
  end

  def interface do
    %{
      create_job: %{
        input:
          ~s({"action":"create_job","run_at":"2026-06-09T08:00:00Z","target":"telegram_conversation_runtime","message":{"action":"scheduled_turn","conversation_id":"tg:1:0","prompt":"Summarize active markets"}}),
        output: ~s({"ok":true,"job_id":1,"next_run_at":1780982400000})
      },
      tick: %{input: ~s({"action":"tick"}), output: ~s({"ok":true,"launched":1})}
    }
  end

  def handle_message(from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "create_job"} = msg} ->
        if trusted?(from, state), do: create_job(from, msg, state), else: {:noreply, state}

      {:ok, %{"action" => "pause", "job_id" => id}} ->
        if trusted?(from, state), do: set_job_state(id, "paused", state), else: {:noreply, state}

      {:ok, %{"action" => "resume", "job_id" => id}} ->
        if trusted?(from, state), do: resume_job(id, state), else: {:noreply, state}

      {:ok, %{"action" => "delete", "job_id" => id}} ->
        if trusted?(from, state), do: set_job_state(id, "deleted", state), else: {:noreply, state}

      {:ok, %{"action" => "tick"}} ->
        if trusted?(from, state), do: run_due(state), else: {:noreply, state}

      {:ok, %{"action" => "list"} = msg} ->
        if trusted?(from, state), do: list_jobs(msg, state), else: {:noreply, state}

      {:ok, %{"action" => "status"}} ->
        if trusted?(from, state) do
          {:reply,
           Jason.encode!(%{
             ok: true,
             jobs: map_size(state.jobs),
             running: map_size(state.tasks),
             max_concurrency: state.max_concurrency,
             max_attempts: state.max_attempts
           }), state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: run_due(state)

  def handle_info({ref, {:cron_run_result, job_id, result}}, state) do
    Process.demonitor(ref, [:flush])
    state = %{state | tasks: Map.delete(state.tasks, ref)}
    {:noreply, finish_run(job_id, result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {job_id, tasks} = Map.pop(state.tasks, ref)
    state = %{state | tasks: tasks}

    state =
      if job_id do
        finish_run(
          job_id,
          %{
            status: "error",
            started_at: state.now_fn.(),
            finished_at: state.now_fn.(),
            error: "task down: #{inspect(reason)}"
          },
          state
        )
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp create_job(from, msg, state) do
    now = state.now_fn.()

    with {:ok, norm} <- Schedule.normalize(due_value(msg), now),
         :ok <- check_floor(norm, state),
         :ok <- check_not_past(norm, now, state) do
      case existing_dedupe_job(state, msg["dedupe_key"]) do
        nil ->
          case build_job(from, msg, norm, state, now) do
            {:ok, job} ->
              state =
                %{
                  state
                  | jobs: Map.put(state.jobs, job.id, job),
                    next_id: max(state.next_id, job.id + 1)
                }
                |> persist_job(job)

              {:reply,
               Jason.encode!(%{
                 ok: true,
                 job_id: job.id,
                 state: job.state,
                 next_run_at: job.next_run_at
               }), arm_timer(state, now)}

            {:error, reason} ->
              {:reply, Jason.encode!(%{ok: false, error: reason}), state}
          end

        job ->
          {:reply,
           Jason.encode!(%{
             ok: true,
             job_id: job.id,
             state: job.state,
             next_run_at: job.next_run_at,
             deduped: true
           }), arm_timer(state, now)}
      end
    else
      {:error, reason} ->
        {:reply, Jason.encode!(%{ok: false, error: reason}), state}
    end
  end

  defp existing_dedupe_job(_state, nil), do: nil
  defp existing_dedupe_job(_state, ""), do: nil

  defp existing_dedupe_job(state, dedupe_key) do
    dedupe_key = safe_optional(dedupe_key, 200)

    state.jobs
    |> Map.values()
    |> Enum.find(fn job ->
      job.dedupe_key == dedupe_key and job.state not in @terminal_states
    end)
  end

  defp build_job(from, msg, norm, state, now) do
    id = state.next_id

    with {:ok, payload} <- normalize_payload(msg, state),
         {:ok, first} <- Schedule.first_run_at(norm, now) do
      {:ok,
       %{
         id: id,
         name: safe_text(msg["name"] || "cron job #{id}", 120),
         schedule: norm,
         next_run_at: first,
         last_run_at: nil,
         last_status: nil,
         last_error: nil,
         state: "active",
         misfire: normalize_misfire(msg["misfire"]),
         consecutive_failures: 0,
         paused_by: nil,
         claimed_due: nil,
         attempts: 0,
         max_attempts: positive_int(msg["max_attempts"], state.max_attempts),
         retry_backoff_ms: nonnegative_int(msg["retry_backoff_ms"], state.retry_backoff_ms),
         origin: normalize_origin(msg["origin"], from),
         payload: payload,
         context_from: normalize_context_from(msg["context_from"]),
         dedupe_key: safe_optional(msg["dedupe_key"], 200),
         created_by: to_string(from),
         created_at: now,
         updated_at: now
       }}
    end
  end

  defp check_floor(%{"kind" => "every_ms", "every_ms" => n}, state)
       when n < state.min_period_ms,
       do: {:error, "every_ms below min_period_ms (#{state.min_period_ms})"}

  defp check_floor(_norm, _state), do: :ok

  defp check_not_past(%{"kind" => "run_at", "run_at_ms" => ms}, now, state)
       when ms < now - state.tick_ms,
       do: {:error, "run_at_past"}

  defp check_not_past(_norm, _now, _state), do: :ok

  defp normalize_misfire("skip"), do: "skip"
  defp normalize_misfire(_), do: "coalesce"

  defp normalize_payload(msg, state) do
    target = to_string(msg["target"] || "")
    message = msg["message"]
    action = if is_map(message), do: to_string(message["action"] || ""), else: ""

    cond do
      target == "" or action == "" ->
        {:error, "create_job needs target and message.action"}

      not allowed_target_action?(target, action, state) ->
        {:error, "cron target #{target}.#{action} is not allowlisted"}

      true ->
        {:ok, %{"target" => target, "message" => message}}
    end
  end

  defp due_value(msg),
    do: msg["run_at"] || msg["at"] || msg["next_run_at"] || msg["schedule"]

  defp run_due(state) do
    now = state.now_fn.()
    state = disarm_timer(state)
    capacity = max(state.max_concurrency - map_size(state.tasks), 0)

    {due, rest} =
      state.jobs
      |> Map.values()
      |> Enum.filter(&due?(&1, now))
      |> Enum.sort_by(& &1.next_run_at)
      |> Enum.split(capacity)

    state =
      Enum.reduce(due, state, fn job, st ->
        launch_job(job, st, now)
      end)

    state = arm_timer(state, now)

    {:reply,
     Jason.encode!(%{
       ok: true,
       launched: length(due),
       deferred: length(rest),
       running: map_size(state.tasks)
     }), state}
  end

  defp due?(%{state: "active", next_run_at: next_run_at, id: id}, now)
       when is_integer(next_run_at) do
    next_run_at <= now and id != nil
  end

  defp due?(_job, _now), do: false

  defp launch_job(job, state, now) do
    {claimed, state} = claim_job(job, state, now)

    if state.async? do
      task =
        Task.async(fn ->
          {:cron_run_result, claimed.id, safe_run(claimed, state)}
        end)

      %{state | tasks: Map.put(state.tasks, task.ref, claimed.id)}
    else
      finish_run(claimed.id, safe_run(claimed, state), state)
    end
  end

  defp claim_job(job, state, now) do
    job = %{
      job
      | last_run_at: now,
        next_run_at: nil,
        claimed_due: job.next_run_at,
        state: "running",
        attempts: Map.get(job, :attempts, 0) + 1,
        updated_at: now
    }

    state = persist_job(%{state | jobs: Map.put(state.jobs, job.id, job)}, job)
    {job, state}
  end

  defp safe_run(job, state) do
    started = state.now_fn.()

    try do
      case dispatch(job, state) do
        :ok ->
          %{status: "ok", started_at: started, finished_at: state.now_fn.(), error: nil}

        {:error, reason} ->
          %{
            status: "error",
            started_at: started,
            finished_at: state.now_fn.(),
            error: to_string(reason)
          }
      end
    rescue
      e ->
        %{
          status: "error",
          started_at: started,
          finished_at: state.now_fn.(),
          error: Exception.message(e)
        }
    end
  end

  defp dispatch(%{payload: %{"target" => target, "message" => message}}, state) do
    target_atom = Map.fetch!(state.allowed_targets.targets, target)
    state.deliver_fn.(target_atom, state.name, Jason.encode!(message))
  end

  defp finish_run(job_id, result, state) do
    now = state.now_fn.()

    case Map.get(state.jobs, job_id) do
      nil ->
        state

      job ->
        job = complete_job(job, result, now)
        store_call(state.store_mod, :save_cron_run, [job, result], :ok)

        jobs =
          if job.state in @terminal_states,
            do: Map.delete(state.jobs, job_id),
            else: Map.put(state.jobs, job_id, job)

        state = persist_job(%{state | jobs: jobs}, job)

        emit_event(state, :job_run, "Scheduled job run finished",
          swarm: state.swarm_name,
          metadata: %{
            job_id: job_id,
            target: job.payload["target"],
            status: result.status,
            state: job.state,
            attempts: job.attempts
          }
        )

        arm_timer(state, now)
    end
  end

  defp complete_job(job, %{status: "ok"} = result, now) do
    if Schedule.recurring?(job.schedule) do
      case Schedule.next_after(job.schedule, job.claimed_due || now, now) do
        {:ok, next} ->
          %{
            job
            | state: "active",
              next_run_at: next,
              claimed_due: nil,
              attempts: 0,
              consecutive_failures: 0,
              last_status: result.status,
              last_error: nil,
              updated_at: now
          }

        :none ->
          %{
            job
            | state: "done",
              next_run_at: nil,
              claimed_due: nil,
              last_status: result.status,
              last_error: nil,
              updated_at: now
          }
      end
    else
      %{
        job
        | state: "done",
          next_run_at: nil,
          claimed_due: nil,
          last_status: result.status,
          last_error: nil,
          updated_at: now
      }
    end
  end

  defp complete_job(job, result, now) do
    attempts = Map.get(job, :attempts, 1)
    max_attempts = Map.get(job, :max_attempts, 3)

    if attempts < max_attempts do
      %{
        job
        | state: "active",
          next_run_at: now + retry_delay(job, attempts),
          last_status: result.status,
          last_error: result.error,
          updated_at: now
      }
    else
      %{
        job
        | state: "failed",
          next_run_at: nil,
          last_status: result.status,
          last_error: result.error,
          updated_at: now
      }
    end
  end

  defp retry_delay(job, attempts) do
    base = max(Map.get(job, :retry_backoff_ms, 60_000), 0)
    min(base * max(attempts, 1), 15 * 60_000)
  end

  defp set_job_state(id, new_state, state) do
    id = to_id(id)

    case Map.get(state.jobs, id) do
      nil ->
        {:reply, Jason.encode!(%{ok: false, error: "job not found"}), state}

      job ->
        job = %{job | state: new_state, updated_at: state.now_fn.()}

        jobs =
          if new_state in @terminal_states,
            do: Map.delete(state.jobs, id),
            else: Map.put(state.jobs, id, job)

        state = persist_job(%{state | jobs: jobs}, job)

        {:reply, Jason.encode!(%{ok: true, job_id: id, state: new_state}),
         arm_timer(state, state.now_fn.())}
    end
  end

  defp resume_job(id, state) do
    id = to_id(id)

    case Map.get(state.jobs, id) do
      nil ->
        {:reply, Jason.encode!(%{ok: false, error: "job not found"}), state}

      job ->
        now = state.now_fn.()
        job = %{job | state: "active", updated_at: now}

        if job.next_run_at do
          state = persist_job(%{state | jobs: Map.put(state.jobs, id, job)}, job)

          {:reply, Jason.encode!(%{ok: true, job_id: id, state: "active"}), arm_timer(state, now)}
        else
          {:reply, Jason.encode!(%{ok: false, error: "job has no future run_at"}), state}
        end
    end
  end

  defp list_jobs(msg, state) do
    include_paused = msg["include_paused"] != false

    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(include_paused or &1.state == "active"))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&public_job/1)

    {:reply, Jason.encode!(%{ok: true, jobs: jobs}), state}
  end

  defp public_job(job) do
    %{
      id: job.id,
      name: job.name,
      target: job.payload["target"],
      action: get_in(job.payload, ["message", "action"]),
      state: job.state,
      next_run_at: job.next_run_at,
      last_run_at: job.last_run_at,
      last_status: job.last_status,
      last_error: job.last_error
    }
  end

  defp persist_job(state, job) do
    store_call(state.store_mod, :save_cron_job, [job], :ok)
    state
  end

  defp arm_timer(%{auto_tick: false} = state, _now), do: state

  defp arm_timer(state, now) do
    state = disarm_timer(state)

    active_due =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.state == "active" and is_integer(&1.next_run_at)))
      |> Enum.map(& &1.next_run_at)

    delay =
      case active_due do
        [] -> state.tick_ms
        times -> max(Enum.min(times) - now, 0)
      end

    %{state | timer_ref: Process.send_after(self(), :tick, min(delay, state.tick_ms))}
  end

  defp disarm_timer(%{timer_ref: nil} = state), do: state

  defp disarm_timer(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp trusted?(from, state), do: MapSet.member?(state.trusted_sources, to_string(from))

  defp allowed_target_action?(target, action, state) do
    MapSet.member?(Map.get(state.allowed_targets.actions, target, MapSet.new()), action)
  end

  defp normalize_allowed_targets(targets) when is_map(targets) do
    Enum.reduce(targets, %{targets: %{}, actions: %{}}, fn {target, actions}, acc ->
      target_atom =
        if is_atom(target), do: target, else: String.to_existing_atom(to_string(target))

      target_text = to_string(target_atom)
      action_set = MapSet.new(Enum.map(actions, &to_string/1))

      %{
        targets: Map.put(acc.targets, target_text, target_atom),
        actions: Map.put(acc.actions, target_text, action_set)
      }
    end)
  end


  defp default_deliver_fn(swarm_name) do
    fn target, from, content ->
      ObjectServer.deliver_message(swarm_name, target, from, content)
      :ok
    end
  end

  defp normalize_loaded_job(%{id: id, state: state, data: data}) do
    atomized =
      data
      |> atomize_known()
      |> Map.put(:id, id)
      |> Map.put(:state, state || data["state"] || "active")

    atomized
  end

  defp atomize_known(data) when is_map(data) do
    %{
      id: to_id(data["id"]),
      name: data["name"],
      schedule: data["schedule"],
      next_run_at: data["next_run_at"],
      last_run_at: data["last_run_at"],
      last_status: data["last_status"],
      last_error: data["last_error"],
      state: data["state"] || "active",
      attempts: to_id(data["attempts"]) || 0,
      max_attempts: to_id(data["max_attempts"]) || 3,
      retry_backoff_ms: to_id(data["retry_backoff_ms"]) || 60_000,
      origin: data["origin"] || %{},
      payload: data["payload"] || %{},
      context_from: data["context_from"] || [],
      dedupe_key: data["dedupe_key"],
      created_by: data["created_by"],
      created_at: data["created_at"],
      updated_at: data["updated_at"]
    }
  end

  defp normalize_origin(origin, from) when is_map(origin),
    do:
      origin
      |> Map.take(["conversation_id", "user_id", "chat_id", "thread_id", "source"])
      |> Map.put_new("source", to_string(from))

  defp normalize_origin(_origin, from), do: %{"source" => to_string(from)}

  defp normalize_context_from(list) when is_list(list),
    do: list |> Enum.map(&to_id/1) |> Enum.filter(&is_integer/1) |> Enum.uniq()

  defp normalize_context_from(_), do: []

  defp recover_running_job(%{state: "running"} = job, now) do
    %{
      job
      | state: "active",
        next_run_at: now,
        last_status: "recovered",
        last_error: "scheduler restarted while job was running",
        updated_at: now
    }
  end

  defp recover_running_job(job, _now), do: job

  defp positive_int(value, default) do
    case to_id(value) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp nonnegative_int(value, default) do
    case to_id(value) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  defp safe_text(value, max) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
    |> String.trim()
    |> String.slice(0, max)
  end

  defp safe_optional(nil, _max), do: nil
  defp safe_optional(value, max), do: safe_text(value, max)

  defp next_memory_id(jobs) do
    case Map.keys(jobs) do
      [] -> 1
      ids -> Enum.max(ids) + 1
    end
  end

  defp to_id(id) when is_integer(id), do: id

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  # ── package seams ──────────────────────────────────────────────────────────
  # store_call/4: guarded durable-store call — a nil/partial store_mod degrades
  # to memory-only (jobs live in state; they just don't survive a restart).
  defp store_call(store_mod, fun, args, default) do
    if is_atom(store_mod) and not is_nil(store_mod) and Code.ensure_loaded?(store_mod) and
         function_exported?(store_mod, fun, length(args)) do
      apply(store_mod, fun, args)
    else
      default
    end
  end

  # emit_event/4: optional events_mod (exports object/4 — e.g. a LogStore
  # wrapper); absent -> Logger metadata line.
  defp emit_event(state, event_type, message, opts) do
    ev = Map.get(state, :events_mod)

    if is_atom(ev) and not is_nil(ev) and Code.ensure_loaded?(ev) and
         function_exported?(ev, :object, 4) do
      ev.object(:cron, event_type, message, opts)
    else
      Logger.info("[cron] #{event_type}: #{message} #{inspect(Keyword.get(opts, :metadata, %{}))}")
    end
  end

  # Module refs arrive as atoms (Elixir swarm defs) or strings (JSON IR).
  # Strings resolve via to_existing_atom — no atom minting; unknown -> nil.
  defp module_ref(nil), do: nil
  defp module_ref(mod) when is_atom(mod), do: mod

  defp module_ref(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp module_ref(_), do: nil
end

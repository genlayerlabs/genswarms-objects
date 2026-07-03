defmodule Genswarms.Cron do
  @moduledoc """
  Global deterministic scheduler object.

  This object is deliberately not market-scoped. A job is one schedule — a
  one-shot datetime, a fixed-rate `every_ms` interval, or a 5-field UTC cron
  expression — plus one stamped message to one allowlisted target. It owns timing, concurrency,
  persistence, and audit; target objects still own domain authority.
  """

  require Logger

  alias Genswarms.Objects.ObjectServer
  alias Genswarms.Cron.Schedule
  alias Genswarms.Cron.Job
  # Events seam: optional events_mod (exports object/4, e.g. a LogStore wrapper);
  # absent -> Logger. Injected via config, resolved in init.

  @terminal_states ~w(done deleted failed)
  @load_states ~w(active paused running)
  @default_max_message_bytes 65_536

  def init(config) do
    store_mod = module_ref(Map.get(config, :store_mod))
    now_fn = Map.get(config, :now_fn, &Schedule.now_ms/0)
    now = now_fn.()

    jobs =
      store_call(store_mod, :load_cron_jobs, [@load_states], [])
      |> Enum.map(&normalize_loaded_job/1)
      |> Enum.map(&Job.recover(&1, now))
      |> Enum.map(&Job.apply_load_misfire(&1, now))
      |> Map.new(fn job -> {job.id, job} end)

    max_store_id = to_id(store_call(store_mod, :max_cron_job_id, [], 0)) || 0

    state = %{
      name: Map.get(config, :name, :cron),
      swarm_name: Map.get(config, :swarm_name, "swarm"),
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
      max_message_bytes: Map.get(config, :max_message_bytes, @default_max_message_bytes),
      min_period_ms: Map.get(config, :min_period_ms, 60_000),
      breaker_threshold: Map.get(config, :breaker_threshold, 5),
      jobs: jobs,
      tasks: %{},
      next_id: max(max_store_id + 1, next_memory_id(jobs)),
      # Fail-closed defaults: with no configured allowlists NOBODY can create
      # jobs and NO target is deliverable — the host declares both (pure data).
      trusted_sources:
        MapSet.new(Map.get(config, :trusted_sources, []) |> Enum.map(&to_string/1)),
      allowed_targets: normalize_allowed_targets(Map.get(config, :allowed_targets, %{}))
    }

    if map_size(jobs) > 0 do
      Logger.info("[cron] loaded #{map_size(jobs)} active/paused/recovered job(s)")
    end

    state = apply_seeds(state, Map.get(config, :seed_jobs, []), now)

    {:ok, arm_timer(state, now)}
  end

  def interface do
    %{
      create_job: %{
        input:
          ~s({"action":"create_job","schedule":{"every_ms":300000},"target":"reporter","message":{"action":"run"},"dedupe_key":"reporter:run"}),
        output: ~s({"ok":true,"job_id":1,"next_run_at":1780982400000})
      },
      pause: %{
        input: ~s({"action":"pause","job_id":1}),
        output: ~s({"ok":true,"job_id":1,"state":"paused"})
      },
      resume: %{
        input: ~s({"action":"resume","job_id":1}),
        output: ~s({"ok":true,"job_id":1,"state":"active"})
      },
      delete: %{
        input: ~s({"action":"delete","job_id":1}),
        output: ~s({"ok":true,"job_id":1,"state":"deleted"})
      },
      tick: %{input: ~s({"action":"tick"}), output: ~s({"ok":true,"launched":1})},
      list: %{
        input: ~s({"action":"list","include_paused":true}),
        output: ~s({"ok":true,"jobs":[{"id":1,"target":"reporter","action":"run"}]})
      },
      status: %{
        input: ~s({"action":"status"}),
        output: ~s({"ok":true,"jobs":1,"running":0,"max_concurrency":16,"max_attempts":3})
      },
      run_now: %{
        input: ~s({"action":"run_now","job_id":1}),
        output: ~s({"ok":true,"job_id":1,"launched":1})
      }
    }
  end

  def handle_message(from, content, state) do
    if oversized_message?(content, state) do
      if trusted?(from, state),
        do: {:reply, Jason.encode!(%{ok: false, error: "message_too_large"}), state},
        else: {:noreply, state}
    else
      handle_decoded_message(from, Jason.decode(content), state)
    end
  end

  defp handle_decoded_message(from, decoded, state) do
    case decoded do
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

      {:ok, %{"action" => "run_now", "job_id" => id}} ->
        if trusted?(from, state), do: run_now_job(id, state), else: {:noreply, state}

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

      {:ok, _decoded} ->
        if trusted?(from, state),
          do: {:reply, Jason.encode!(%{ok: false, error: "unknown_action"}), state},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, state) do
    {_reply, state} = run_due_core(state)
    {:noreply, state}
  end

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

    # validate_create_fields must run BEFORE existing_dedupe_job/build_job:
    # both to_string message-derived fields, and a crafted map/list value
    # would raise Protocol.UndefinedError on the engine's rescue-less cast
    # path (ObjectServer crash). Reject, never coerce.
    #
    # F3: schedule normalization/floor and target/payload validation must
    # also run BEFORE the once-terminal-dedupe lookup — otherwise a garbage
    # schedule or a disallowed target on a once:true re-create with a
    # terminal dedupe_key would short-circuit straight to {ok:true,
    # deduped:true} instead of being rejected. Only the past-guard
    # (check_not_past, in create_live_job) stays AFTER the dedupe lookup —
    # skipped entirely on a dedupe hit, because a once:true re-create with a
    # now-past run_at must still no-op with deduped:true (load-bearing; see
    # checks/cron_kinds_test.exs).
    with :ok <- validate_create_fields(msg),
         {:ok, norm} <- Schedule.normalize(due_value(msg), now),
         :ok <- check_floor(norm, state),
         {:ok, _payload} <- normalize_payload(msg, state) do
      case once_terminal_dedupe_row(state, msg) do
        nil ->
          create_live_job(from, msg, norm, state, now)

        row ->
          {:reply, Jason.encode!(terminal_dedupe_reply(row)), arm_timer(state, now)}
      end
    else
      {:error, reason} ->
        {:reply, Jason.encode!(%{ok: false, error: reason}), state}
    end
  end

  defp create_live_job(from, msg, norm, state, now) do
    with :ok <- check_not_past(norm, now, state) do
      case existing_dedupe_job(state, msg["dedupe_key"]) do
        nil ->
          insert_created_job(from, msg, norm, state, now)

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

  defp insert_created_job(from, msg, norm, state, now) do
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
  end

  # Inbound create_job fields that flow into to_string/safe_text must be
  # scalar strings (or absent). Numbers/maps/lists are rejected with a clear
  # error — silent coercion would mint surprising names/keys, and non-scalars
  # would crash the object.
  defp validate_create_fields(msg) do
    cond do
      not string_or_nil?(msg["target"]) ->
        {:error, "target must be a string"}

      not (is_nil(msg["message"]) or is_map(msg["message"])) ->
        {:error, "message must be an object"}

      is_map(msg["message"]) and not string_or_nil?(msg["message"]["action"]) ->
        {:error, "message.action must be a string"}

      not string_or_nil?(msg["name"]) ->
        {:error, "name must be a string"}

      not string_or_nil?(msg["dedupe_key"]) ->
        {:error, "dedupe_key must be a string"}

      not string_or_nil?(msg["misfire"]) ->
        {:error, "misfire must be a string"}

      not (is_nil(msg["once"]) or is_boolean(msg["once"])) ->
        {:error, "once must be a boolean"}

      true ->
        :ok
    end
  end

  defp string_or_nil?(nil), do: true
  defp string_or_nil?(value), do: is_binary(value)

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

  defp once_terminal_dedupe_row(state, %{"once" => true, "dedupe_key" => dk})
       when is_binary(dk) and dk != "" do
    key = safe_optional(dk, 200)

    state.store_mod
    |> store_call(:load_cron_jobs, [@terminal_states], [])
    |> Enum.find(&(terminal_dedupe_key(&1) == key))
  end

  defp once_terminal_dedupe_row(_state, _msg), do: nil

  defp terminal_dedupe_reply(row) do
    row_id = row_value(row, :id)

    %{
      ok: true,
      job_id: to_id(row_id) || row_id,
      state: row_value(row, :state),
      deduped: true
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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
         breaker_threshold: positive_int(msg["breaker_threshold"], state.breaker_threshold),
         origin: normalize_origin(msg["origin"], from),
         payload: payload,
         dedupe_key: safe_optional(msg["dedupe_key"], 200),
         created_by: to_string(from),
         created_at: now,
         updated_at: now
       }}
    end
  end

  # Declarative config seeding: the host declares recurring (mostly) jobs in
  # config.seed_jobs; init upserts them by dedupe_key AFTER store load/recovery
  # so a seed can find (and update) a job that already persisted from a prior
  # boot. Seeds bypass trusted_sources (they're host config, not an inbound
  # message) but MUST still clear the allowed_targets allowlist. Any invalid
  # seed raises — a bad seed is a deploy-time config bug, not a runtime no-op.
  defp apply_seeds(state, [], _now), do: state

  defp apply_seeds(state, seeds, now) do
    # Terminal rows are not loaded (@load_states), so the in-memory dedupe
    # cannot see a one-shot seed that already ran to done/failed (or was
    # deleted) — it would be re-created with the past-guard skipped and fire
    # again on every boot, accreting duplicate rows. Consult the store once
    # for terminal dedupe_keys; a one-shot seed with a terminal row is a no-op.
    terminal_keys =
      store_call(state.store_mod, :load_cron_jobs, [@terminal_states], [])
      |> Enum.map(&terminal_dedupe_key/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reduce(seeds, state, fn seed, st -> apply_seed(st, seed, now, terminal_keys) end)
  end

  defp terminal_dedupe_key(%{data: %{"dedupe_key" => dk}}) when is_binary(dk) and dk != "",
    do: dk

  defp terminal_dedupe_key(row) do
    case row_value(row, :data) do
      %{"dedupe_key" => dk} when is_binary(dk) and dk != "" -> dk
      _ -> nil
    end
  end

  defp apply_seed(state, seed, now, terminal_keys) do
    dk = seed[:dedupe_key] || seed["dedupe_key"]

    if dk in [nil, ""] do
      raise ArgumentError, "cron seed #{inspect(seed[:name] || seed["name"])} needs dedupe_key"
    end

    msg = %{
      "name" => to_string(seed[:name] || seed["name"] || dk),
      "dedupe_key" => dk,
      "schedule" => jsonify(seed[:schedule] || seed["schedule"]),
      "target" => to_string(seed[:target] || seed["target"] || ""),
      "message" => jsonify(seed[:message] || seed["message"]),
      "misfire" => seed[:misfire] || seed["misfire"],
      "max_attempts" => seed[:max_attempts] || seed["max_attempts"],
      "breaker_threshold" => seed[:breaker_threshold] || seed["breaker_threshold"]
    }

    # Seeds are recurring (or one-shot future) config, not inbound runtime
    # requests: the every_ms floor still guards against a mistyped tiny
    # period, but the past-guard (which only ever matches kind "run_at")
    # would wrongly reject a seed pinned to a date that's already elapsed by
    # the time the box reboots — so it's deliberately not applied here.
    with {:ok, norm} <- Schedule.normalize(msg["schedule"], now),
         :ok <- check_floor(norm, state),
         {:ok, _payload} <- normalize_payload(msg, state) do
      upsert_seed(state, msg, norm, now, terminal_keys)
    else
      {:error, reason} ->
        raise ArgumentError, "invalid cron seed #{inspect(msg["name"])}: #{reason}"
    end
  end

  defp upsert_seed(state, msg, norm, now, terminal_keys) do
    case existing_dedupe_job(state, msg["dedupe_key"]) do
      nil ->
        # One-shot seed whose dedupe_key already has a terminal store row:
        # it ran (or was deleted) — never resurrect/re-fire it (I4). Recurring
        # seeds keep declarative semantics: the config says they should exist.
        if norm["kind"] == "run_at" and
             MapSet.member?(terminal_keys, safe_optional(msg["dedupe_key"], 200)) do
          state
        else
          insert_seed_job(state, msg, norm, now)
        end

      job ->
        update_seed_job(state, job, msg, norm, now)
    end
  end

  defp insert_seed_job(state, msg, norm, now) do
    case build_job("seed", msg, norm, state, now) do
      {:ok, job} ->
        %{
          state
          | jobs: Map.put(state.jobs, job.id, job),
            next_id: max(state.next_id, job.id + 1)
        }
        |> persist_job(job)

      {:error, reason} ->
        raise ArgumentError, "invalid cron seed #{inspect(msg["name"])}: #{reason}"
    end
  end

  defp update_seed_job(state, job, msg, norm, now) do
    case normalize_payload(msg, state) do
      {:ok, payload} ->
        misfire = normalize_misfire(msg["misfire"])
        max_attempts = positive_int(msg["max_attempts"], state.max_attempts)
        breaker_threshold = positive_int(msg["breaker_threshold"], state.breaker_threshold)
        schedule_changed? = job.schedule != norm

        changed? =
          schedule_changed? or job.payload != payload or job.max_attempts != max_attempts or
            job.misfire != misfire or job.breaker_threshold != breaker_threshold

        if changed? do
          next_run_at =
            if schedule_changed? do
              case Schedule.first_run_at(norm, now) do
                {:ok, first} -> first
                {:error, _} -> job.next_run_at
              end
            else
              job.next_run_at
            end

          updated = %{
            job
            | schedule: norm,
              payload: payload,
              max_attempts: max_attempts,
              misfire: misfire,
              breaker_threshold: breaker_threshold,
              next_run_at: next_run_at,
              updated_at: now
          }

          %{state | jobs: Map.put(state.jobs, job.id, updated)}
          |> persist_job(updated)
        else
          state
        end

      {:error, reason} ->
        raise ArgumentError, "invalid cron seed #{inspect(msg["name"])}: #{reason}"
    end
  end

  defp jsonify(nil), do: nil
  defp jsonify(value), do: value |> Jason.encode!() |> Jason.decode!()

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
    {reply, state} = run_due_core(state)
    {:reply, Jason.encode!(reply), state}
  end

  defp run_due_core(state) do
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

    {%{
       ok: true,
       launched: length(due),
       deferred: length(rest),
       running: map_size(state.tasks)
     }, state}
  end

  defp due?(%{state: "active", next_run_at: next_run_at, id: id}, now)
       when is_integer(next_run_at) do
    next_run_at <= now and id != nil
  end

  defp due?(_job, _now), do: false

  defp run_now_job(raw_id, state) do
    case job_id(raw_id) do
      {:ok, id} ->
        run_now_existing_job(id, Map.get(state.jobs, id), state)

      {:error, reason} ->
        {:reply, Jason.encode!(%{ok: false, error: reason}), state}
    end
  end

  defp run_now_existing_job(id, nil, state),
    do: {:reply, Jason.encode!(%{ok: false, error: "job not found", job_id: id}), state}

  defp run_now_existing_job(id, %{state: state_name}, state) when state_name in @terminal_states,
    do:
      {:reply, Jason.encode!(%{ok: false, error: "job terminal", job_id: id, state: state_name}),
       state}

  # F2: run_now bypassing max_concurrency would let a trusted caller launch
  # unbounded concurrent tasks regardless of the configured cap. At
  # saturation, reject rather than defer — run_now is an immediate-fire
  # request, not a schedulable one; there is no due-queue to defer it onto.
  defp run_now_existing_job(id, %{state: "active"} = job, state) do
    if map_size(state.tasks) >= state.max_concurrency do
      {:reply, Jason.encode!(%{ok: false, error: "at max concurrency", job_id: id}), state}
    else
      now = state.now_fn.()
      state = launch_job(job, state, now, now) |> arm_timer(now)

      {:reply,
       Jason.encode!(%{
         ok: true,
         job_id: id,
         launched: 1,
         running: map_size(state.tasks)
       }), state}
    end
  end

  defp run_now_existing_job(id, %{state: state_name}, state),
    do:
      {:reply,
       Jason.encode!(%{ok: false, error: "job not active", job_id: id, state: state_name}), state}

  defp launch_job(job, state, now, occurrence_due \\ nil) do
    {claimed, state} = claim_job(job, state, now, occurrence_due)

    if state.async? do
      Process.flag(:trap_exit, true)

      task =
        Task.async(fn ->
          {:cron_run_result, claimed.id, safe_run(claimed, state)}
        end)

      %{state | tasks: Map.put(state.tasks, task.ref, claimed.id)}
    else
      finish_run(claimed.id, safe_run(claimed, state), state)
    end
  end

  defp claim_job(job, state, now, nil) do
    job = Job.claim(job, now)
    state = persist_job(%{state | jobs: Map.put(state.jobs, job.id, job)}, job)
    {job, state}
  end

  defp claim_job(job, state, now, occurrence_due) do
    job = Job.claim(job, now, occurrence_due)
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
        # An operator pause that landed while this occurrence was in flight must
        # survive the task result: record the outcome, clear the claim, but do
        # NOT rebuild the job "active"/re-arm it (delete already survives — a
        # terminal job is removed from the map, so the nil clause above hits).
        # Job.finish/3 owns that pause-preserve branch (see job.ex).
        job = Job.finish(job, result, now)

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
            name: job.name,
            target: job.payload["target"],
            status: result.status,
            state: job.state,
            attempts: job.attempts
          }
        )

        if result.status != "ok" do
          emit_event(state, :job_run_failed, "Scheduled job run failed",
            swarm: state.swarm_name,
            metadata: %{
              job_id: job_id,
              name: job.name,
              target: job.payload["target"],
              error: result.error,
              state: job.state,
              attempts: job.attempts,
              consecutive_failures: job.consecutive_failures
            }
          )
        end

        if result.status != "ok" and job.state == "paused" and job.paused_by == "breaker" do
          emit_event(state, :job_breaker_paused, "Scheduled job paused by breaker",
            swarm: state.swarm_name,
            metadata: %{
              job_id: job_id,
              name: job.name,
              consecutive_failures: job.consecutive_failures
            }
          )
        end

        # Display story event (host events canvas) — one per completed run,
        # status carried so the host reducer can render failures as issue rows
        # and drop/dim ok-runs (they fire every few minutes). The breaker pause
        # is its own story beat: a job silently stopping IS the incident.
        emit_display(%{
          kind: :job_run,
          name: job.name,
          status: result.status,
          target: job.payload["target"]
        })

        if result.status != "ok" and job.state == "paused" and job.paused_by == "breaker" do
          emit_display(%{kind: :job_run, name: job.name, status: "breaker_paused"})
        end

        arm_timer(state, now)
    end
  end

  defp set_job_state(id, new_state, state) do
    case job_id(id) do
      {:ok, id} ->
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

      {:error, reason} ->
        {:reply, Jason.encode!(%{ok: false, error: reason}), state}
    end
  end

  defp resume_job(id, state) do
    case job_id(id) do
      {:ok, id} ->
        resume_existing_job(id, Map.get(state.jobs, id), state)

      {:error, reason} ->
        {:reply, Jason.encode!(%{ok: false, error: reason}), state}
    end
  end

  defp resume_existing_job(_id, nil, state),
    do: {:reply, Jason.encode!(%{ok: false, error: "job not found"}), state}

  # Resume only acts on paused jobs. Resuming a RUNNING job used to double-fire it
  # (running has next_run_at nil -> Job.resume's misfire pass read that as missed
  # and coalesce-armed `now` while the first occurrence was still in flight);
  # resuming an ACTIVE job is meaningless.
  defp resume_existing_job(id, %{state: other}, state) when other != "paused" do
    {:reply, Jason.encode!(%{ok: false, error: "job not paused", job_id: id, state: other}),
     state}
  end

  defp resume_existing_job(id, job, state) do
    now = state.now_fn.()
    job = Job.resume(job, now)

    if job.next_run_at do
      state = persist_job(%{state | jobs: Map.put(state.jobs, id, job)}, job)

      {:reply, Jason.encode!(%{ok: true, job_id: id, state: "active"}), arm_timer(state, now)}
    else
      {:reply, Jason.encode!(%{ok: false, error: "job has no future run_at"}), state}
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
      kind: job.schedule["kind"],
      schedule: job.schedule,
      dedupe_key: job.dedupe_key,
      next_run_at: job.next_run_at,
      last_run_at: job.last_run_at,
      last_status: job.last_status,
      last_error: job.last_error,
      paused_by: job.paused_by
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
      cond do
        map_size(state.tasks) >= state.max_concurrency ->
          state.tick_ms

        active_due == [] ->
          state.tick_ms

        true ->
          max(Enum.min(active_due) - now, 0)
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
      target_atom = allowed_target_atom(target)
      target_text = to_string(target_atom)
      action_set = MapSet.new(Enum.map(actions, &to_string/1))

      %{
        targets: Map.put(acc.targets, target_text, target_atom),
        actions: Map.put(acc.actions, target_text, action_set)
      }
    end)
  end

  defp allowed_target_atom(target) when is_atom(target), do: target

  defp allowed_target_atom(target) do
    text = to_string(target)
    existing_target_atom(text)
  end

  defp existing_target_atom(text) do
    String.to_existing_atom(text)
  rescue
    ArgumentError -> raise ArgumentError, "cron allowed_targets: unknown object :#{text}"
  end

  defp default_deliver_fn(swarm_name) do
    fn target, from, content ->
      ObjectServer.deliver_message(swarm_name, target, from, content)
      :ok
    end
  end

  defp normalize_loaded_job(%{id: id, state: state, data: data}) do
    id = to_id(id) || to_id(data["id"])

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
      schedule: upgrade_schedule(data["schedule"]),
      next_run_at: data["next_run_at"],
      last_run_at: data["last_run_at"],
      last_status: data["last_status"],
      last_error: data["last_error"],
      state: data["state"] || "active",
      misfire: data["misfire"] || "coalesce",
      consecutive_failures: to_id(data["consecutive_failures"]) || 0,
      paused_by: data["paused_by"],
      attempts: to_id(data["attempts"]) || 0,
      max_attempts: to_id(data["max_attempts"]) || 3,
      retry_backoff_ms: to_id(data["retry_backoff_ms"]) || 60_000,
      breaker_threshold: to_id(data["breaker_threshold"]) || 5,
      claimed_due: nil,
      origin: data["origin"] || %{},
      payload: data["payload"] || %{},
      dedupe_key: data["dedupe_key"],
      created_by: data["created_by"],
      created_at: data["created_at"],
      updated_at: data["updated_at"]
    }
  end

  # 0.1.1-era persisted jobs stored the due timestamp bare (`run_at_ms`, no
  # `kind`); everything from Task 6 on is kind-tagged and passes through
  # unchanged. Any other shape (nil, corrupt) is left as-is — first_run_at
  # will surface it as an invalid schedule rather than silently coercing it.
  defp upgrade_schedule(%{"kind" => _} = s), do: s
  defp upgrade_schedule(%{"run_at_ms" => ms}), do: %{"kind" => "run_at", "run_at_ms" => ms}
  defp upgrade_schedule(other), do: other

  defp normalize_origin(origin, from) when is_map(origin) do
    origin
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if scalar?(value), do: Map.put(acc, to_string(key), value), else: acc
    end)
    |> Map.put_new("source", to_string(from))
  end

  defp normalize_origin(_origin, from), do: %{"source" => to_string(from)}

  defp scalar?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp scalar?(_value), do: false

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
    case Enum.filter(Map.keys(jobs), &is_integer/1) do
      [] -> 1
      ids -> Enum.max(ids) + 1
    end
  end

  defp job_id(id) do
    case to_id(id) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, "invalid job_id"}
    end
  end

  defp to_id(id) when is_integer(id) and id >= 0, do: id
  defp to_id(id) when is_integer(id), do: nil

  defp to_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_id(_), do: nil

  defp oversized_message?(content, state) when is_binary(content),
    do: byte_size(content) > state.max_message_bytes

  defp oversized_message?(_content, _state), do: false

  defp row_value(row, key) when is_map(row), do: Map.get(row, key) || Map.get(row, to_string(key))
  defp row_value(_row, _key), do: nil

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
  # Display telemetry rides the shared genswarms-objects wire (same convention
  # as the browser and metrics packages): configurable app env, host overrides
  # it to its canvas wire. Never raises into the scheduler.
  defp emit_display(meta) do
    :telemetry.execute(
      Application.get_env(:genswarms_objects, :display_wire, [:genswarms, :display]),
      %{},
      meta
    )
  rescue
    _ -> :ok
  end

  @doc """
  Dashboard extension (probed data contract — the host's dashboard source calls
  this via `function_exported?`, never a compile dep). Reads the DURABLE job
  rows from the injected store, so the page renders even when the scheduler
  object is mid-restart: `dashboard_extension(store_mod: MyStore)`.

  Returns `%{"dashboard_pages" => [page]}` in the generic page schema
  (sections of `"metrics"` items + a `"table"`), or `%{}` without a store.
  """
  def dashboard_extension(opts \\ []) do
    store_mod = Keyword.get(opts, :store_mod)

    if is_nil(store_mod) do
      %{}
    else
      jobs = safe_load_jobs(store_mod)
      failing = Enum.count(jobs, &((&1[:last_status] || "ok") != "ok"))
      paused = Enum.count(jobs, &(&1[:state] == "paused"))

      %{
        "dashboard_pages" => [
          %{
            "id" => "cron-jobs",
            "label" => "Cron",
            "icon" => "hero-clock",
            "meta" => "#{length(jobs)} scheduled job(s)",
            "sections" => [
              %{
                "type" => "metrics",
                "title" => "Scheduler",
                "items" => [
                  %{"label" => "Jobs", "value" => length(jobs)},
                  %{"label" => "Paused", "value" => paused},
                  %{"label" => "Failing", "value" => failing}
                ]
              },
              %{
                "type" => "table",
                "title" => "Jobs",
                "meta" => "durable rows — survives a scheduler restart",
                "columns" => [
                  %{"key" => "name", "label" => "job"},
                  %{"key" => "schedule", "label" => "schedule", "mono" => true},
                  %{"key" => "target", "label" => "target", "mono" => true},
                  %{"key" => "state", "label" => "state"},
                  %{"key" => "next_run", "label" => "next run", "mono" => true},
                  %{"key" => "last_status", "label" => "last", "align" => "right"},
                  %{"key" => "failures", "label" => "consec fails", "align" => "right"}
                ],
                "rows" => Enum.map(jobs, &job_row/1)
              }
            ]
          }
        ]
      }
    end
  end

  defp safe_load_jobs(store_mod) do
    if Code.ensure_loaded?(store_mod) and function_exported?(store_mod, :load_cron_jobs, 1) do
      # Same normalization as boot: store rows are {id, state, data-json} wrappers;
      # normalize_loaded_job unwraps to the atom-keyed job map job_row reads.
      (store_mod.load_cron_jobs(@load_states) || [])
      |> Enum.map(&normalize_row_for_dashboard/1)
    else
      []
    end
  rescue
    _ -> []
  end

  # Rows may arrive as raw store wrappers (%{id, state, data}) or as already-flat
  # job maps (test stores) — normalize the former, pass the latter through.
  defp normalize_row_for_dashboard(%{data: %{} = _} = row), do: normalize_loaded_job(row)
  defp normalize_row_for_dashboard(row), do: row

  defp job_row(job) do
    %{
      "name" => to_string(job[:name] || "?"),
      "schedule" => describe_schedule(job[:schedule]),
      "target" => to_string(get_in(job, [:payload, "target"]) || "?"),
      "state" => to_string(job[:state] || "?"),
      "next_run" => format_run_at(job[:next_run_at]),
      "last_status" => to_string(job[:last_status] || "—"),
      "failures" => job[:consecutive_failures] || 0
    }
  end

  # canonical persisted shape first (Schedule.normalize/2 output), then the
  # pre-normalize input shapes (flat test stores hand those in)
  defp describe_schedule(%{"kind" => "cron", "expr" => expr}), do: "cron " <> to_string(expr)

  defp describe_schedule(%{"kind" => "every_ms", "every_ms" => ms}) when is_integer(ms),
    do: "every #{div(ms, 1000)}s"

  defp describe_schedule(%{"kind" => "run_at", "run_at_ms" => ms}), do: "once @ " <> format_run_at(ms)
  defp describe_schedule(%{"cron" => expr}), do: "cron " <> to_string(expr)
  defp describe_schedule(%{"every_ms" => ms}) when is_integer(ms), do: "every #{div(ms, 1000)}s"
  defp describe_schedule(%{"run_at" => at}), do: "once @ " <> format_run_at(at)
  defp describe_schedule(%{cron: expr}), do: "cron " <> to_string(expr)
  defp describe_schedule(%{every_ms: ms}) when is_integer(ms), do: "every #{div(ms, 1000)}s"
  defp describe_schedule(%{run_at: at}), do: "once @ " <> format_run_at(at)
  defp describe_schedule(_), do: "?"

  defp format_run_at(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%m-%d %H:%MZ")
  rescue
    _ -> "?"
  end

  defp format_run_at(_), do: "—"

  defp emit_event(state, event_type, message, opts) do
    ev = Map.get(state, :events_mod)

    if is_atom(ev) and not is_nil(ev) and Code.ensure_loaded?(ev) and
         function_exported?(ev, :object, 4) do
      ev.object(:cron, event_type, message, opts)
    else
      Logger.info(
        "[cron] #{event_type}: #{message} #{inspect(Keyword.get(opts, :metadata, %{}))}"
      )
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

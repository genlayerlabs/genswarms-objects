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
      |> Enum.map(&apply_load_misfire(&1, now))
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
      breaker_threshold: Map.get(config, :breaker_threshold, 5),
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

    state = apply_seeds(state, Map.get(config, :seed_jobs, []), now)

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

    # validate_create_fields must run BEFORE existing_dedupe_job/build_job:
    # both to_string message-derived fields, and a crafted map/list value
    # would raise Protocol.UndefinedError on the engine's rescue-less cast
    # path (ObjectServer crash). Reject, never coerce.
    with :ok <- validate_create_fields(msg),
         {:ok, norm} <- Schedule.normalize(due_value(msg), now),
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
         context_from: normalize_context_from(msg["context_from"]),
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

  defp terminal_dedupe_key(_row), do: nil

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
        # A retry claim's next_run_at is the backoff timestamp, not the occurrence's
        # true due point — keep the original due (set at the first claim of this
        # occurrence) alive across retry cycles so a later success re-arms off the
        # grid, not off the backoff time. Cleared on success/exhaustion (complete_job).
        claimed_due: job.claimed_due || job.next_run_at,
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
        # An operator pause that landed while this occurrence was in flight must
        # survive the task result: record the outcome, clear the claim, but do
        # NOT rebuild the job "active"/re-arm it (delete already survives — a
        # terminal job is removed from the map, so the nil clause above hits).
        job =
          if job.state == "paused" do
            %{
              job
              | claimed_due: nil,
                attempts: 0,
                last_status: result.status,
                last_error: result.error,
                updated_at: now
            }
          else
            complete_job(job, result, now)
          end

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

        no_next ->
          # :none or {:error, reason} (poisoned stored expr): no next
          # occurrence exists — terminal done, the schedule reason (if any)
          # kept visible in last_error.
          %{
            job
            | state: "done",
              next_run_at: nil,
              claimed_due: nil,
              last_status: result.status,
              last_error: schedule_error(no_next),
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
    if job.attempts < job.max_attempts do
      %{
        job
        | state: "active",
          next_run_at: now + retry_delay(job, job.attempts),
          last_status: result.status,
          last_error: result.error,
          updated_at: now
      }
    else
      exhausted(job, result, now)
    end
  end

  # Occurrence-scoped exhaustion (attempts hit max_attempts with no success).
  # Recurring: bump consecutive_failures; the breaker (>= breaker_threshold) pauses
  # the job (paused_by "breaker") instead of re-arming it. Below the breaker, the
  # occurrence still moves on to the next grid point (Schedule.next_after from the
  # ORIGINAL claimed_due, not `now` — the retry-grid fix in claim_job keeps that due
  # point stable across the whole retry cycle). One-shot: terminal "failed" (0.1.1).
  defp exhausted(job, result, now) do
    if Schedule.recurring?(job.schedule) do
      cf = (job.consecutive_failures || 0) + 1

      base = %{
        job
        | attempts: 0,
          consecutive_failures: cf,
          claimed_due: nil,
          last_status: result.status,
          last_error: result.error,
          updated_at: now
      }

      if cf >= job.breaker_threshold do
        %{base | state: "paused", paused_by: "breaker", next_run_at: nil}
      else
        case Schedule.next_after(job.schedule, job.claimed_due || now, now) do
          {:ok, next} ->
            %{base | state: "active", next_run_at: next}

          # :none or {:error, _}: no next occurrence — terminal failed; base
          # already carries the (more proximate) delivery error in last_error.
          _no_next ->
            %{base | state: "failed", next_run_at: nil}
        end
      end
    else
      %{
        job
        | state: "failed",
          next_run_at: nil,
          claimed_due: nil,
          last_status: result.status,
          last_error: result.error,
          updated_at: now
      }
    end
  end

  # Schedule.next_after on a corrupt/poisoned stored schedule returns
  # {:error, reason}; call sites treat it exactly like :none (no next
  # occurrence). Where a job map is in hand this keeps the reason visible.
  defp schedule_error(:none), do: nil
  defp schedule_error({:error, reason}), do: "schedule error: #{reason}"

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

      # Resume only acts on paused jobs. Resuming a RUNNING job used to
      # double-fire it (running has next_run_at nil -> apply_resume_misfire
      # read that as a missed occurrence and coalesce-armed `now` while the
      # first occurrence was still in flight); resuming an ACTIVE job is
      # meaningless. Contract: ok:false "job not paused" + the current state.
      %{state: other} = _job when other != "paused" ->
        {:reply, Jason.encode!(%{ok: false, error: "job not paused", job_id: id, state: other}),
         state}

      job ->
        now = state.now_fn.()

        job =
          %{job | state: "active", paused_by: nil, consecutive_failures: 0, updated_at: now}
          |> apply_resume_misfire(now)

        if job.next_run_at do
          state = persist_job(%{state | jobs: Map.put(state.jobs, id, job)}, job)

          {:reply, Jason.encode!(%{ok: true, job_id: id, state: "active"}), arm_timer(state, now)}
        else
          {:reply, Jason.encode!(%{ok: false, error: "job has no future run_at"}), state}
        end
    end
  end

  # Every resume clears the breaker (paused_by/consecutive_failures). For recurring
  # jobs whose due point was missed (next_run_at nil — e.g. breaker-paused — or now
  # in the past because the pause spanned occurrences), apply the job's misfire
  # policy: "skip" jumps to the next FUTURE grid point (no catch-up delivery);
  # otherwise ("coalesce") fires once, immediately. A recurring job whose next_run_at
  # is still in the future is left alone (resuming early shouldn't fire it early).
  # One-shot jobs with a nil next_run_at keep 0.1.1 behavior (untouched -> the
  # caller's "job has no future run_at" reply).
  defp apply_resume_misfire(job, now) do
    missed? = is_nil(job.next_run_at) or job.next_run_at <= now

    if missed? and Schedule.recurring?(job.schedule) do
      case job.misfire do
        "skip" ->
          case Schedule.next_after(job.schedule, job.last_run_at || job.created_at, now) do
            {:ok, next} -> %{job | next_run_at: next}
            # :none or {:error, _}: nothing to arm — the caller's
            # "job has no future run_at" reply surfaces it.
            _no_next -> %{job | next_run_at: nil}
          end

        _coalesce ->
          %{job | next_run_at: now}
      end
    else
      job
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
      context_from: data["context_from"] || [],
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

  defp normalize_origin(origin, from) when is_map(origin),
    do:
      origin
      |> Map.take(["conversation_id", "user_id", "chat_id", "thread_id", "source"])
      |> Map.put_new("source", to_string(from))

  defp normalize_origin(_origin, from), do: %{"source" => to_string(from)}

  defp normalize_context_from(list) when is_list(list),
    do: list |> Enum.map(&to_id/1) |> Enum.filter(&is_integer/1) |> Enum.uniq()

  defp normalize_context_from(_), do: []

  # Boot-time recovery: any job found "running" (crashed mid-claim) is re-armed.
  # One-shot: unchanged from 0.1.1 (fires again immediately). Recurring: apply the
  # same misfire policy as a manual resume (coalesce -> now, skip -> the next future
  # grid point) — atomize_known backfills :misfire ("coalesce" default) for every
  # loaded job, including 0.1.1-era rows that never had the field.
  defp recover_running_job(%{state: "running"} = job, now) do
    schedule = Map.get(job, :schedule)

    next_run_at =
      if Schedule.recurring?(schedule) do
        case job.misfire do
          "skip" ->
            case Schedule.next_after(schedule, job.last_run_at || job.created_at, now) do
              {:ok, next} -> next
              # :none or {:error, _} (poisoned stored expr): fall back to the
              # coalesce recovery point instead of crashing init — the run's
              # completion then parks the job terminal with the reason.
              _no_next -> now
            end

          _coalesce ->
            now
        end
      else
        now
      end

    %{
      job
      | state: "active",
        next_run_at: next_run_at,
        last_status: "recovered",
        last_error: "scheduler restarted while job was running",
        updated_at: now
    }
  end

  defp recover_running_job(job, _now), do: job

  # Load-time misfire pass for ORDINARY downtime: an ACTIVE recurring job whose
  # stored next_run_at is already past missed occurrences while the scheduler
  # simply wasn't running (no crash mid-run — recover_running_job handles that).
  # "skip" advances to the next FUTURE grid point (no catch-up delivery, same
  # grid base as the missed due); "coalesce" (default) leaves the past due in
  # place — exactly one catch-up, unchanged behavior. One-shots are untouched
  # (a past one-shot still fires its catch-up). Runs after recover_running_job,
  # which never leaves a strictly-past next_run_at, so the passes don't overlap.
  defp apply_load_misfire(%{state: "active", misfire: "skip", next_run_at: due} = job, now)
       when is_integer(due) and due < now do
    if Schedule.recurring?(Map.get(job, :schedule)) do
      case Schedule.next_after(job.schedule, due, now) do
        {:ok, next} -> %{job | next_run_at: next, updated_at: now}
        # :none or {:error, _}: nothing to arm — same shape as a skip resume.
        _no_next -> %{job | next_run_at: nil, updated_at: now}
      end
    else
      job
    end
  end

  defp apply_load_misfire(job, _now), do: job

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

defmodule Genswarms.Cron.Job do
  @moduledoc """
  Pure job-lifecycle state machine for `Genswarms.Cron`. No store, no
  Task/timer/process concerns, no event emission — every function takes a
  job map and an injected `now` (Unix milliseconds) and returns a plain job
  map. Schedule math is delegated to `Genswarms.Cron.Schedule` (also pure);
  everything else (persistence, timers, task execution, message decode,
  trust gating, event emission) stays in `Genswarms.Cron` — the shell.

  ## Data shape (job map)
  Only the lifecycle-relevant fields are touched here: `state`
  ("active" | "running" | "paused" | "done" | "deleted" | "failed"),
  `next_run_at`, `last_run_at`, `claimed_due`, `attempts`,
  `max_attempts`, `consecutive_failures`, `breaker_threshold`, `paused_by`,
  `last_status`, `last_error`, `updated_at`, `schedule`, `misfire`
  ("skip" | "coalesce"), `created_at`, `retry_backoff_ms`. See `cron.ex` for
  the full persisted job shape (payload, origin, dedupe_key, etc. — none of
  that is lifecycle).

  ## Lifecycle
      claim/2              — mark an occurrence "running" (bump attempts, stash claimed_due)
      finish/3             — apply a run result: paused-preserve, or dispatch to complete/3
      complete/3           — ok -> re-arm (recurring) or done (one-shot);
                              error -> retry, or exhaust (breaker pause / terminal failed)
      resume/2             — clear breaker state + apply the resume misfire policy
      recover/2            — boot-time recovery of a job stuck "running" (crash mid-claim)
      apply_load_misfire/2 — ordinary-downtime misfire pass at load (not a crash — recover/2 handles that)
  """

  alias Genswarms.Cron.Schedule

  @doc """
  Claim an occurrence: mark the job "running", bump attempts, and stash the
  due point for this occurrence into `claimed_due` — kept across retries so a
  later success re-arms off the original grid point, not off the backoff
  time. Cleared on success/exhaustion by `finish/3`.
  """
  def claim(job, now) do
    %{
      job
      | last_run_at: now,
        next_run_at: nil,
        # A retry claim's next_run_at is the backoff timestamp, not the occurrence's
        # true due point — keep the original due (set at the first claim of this
        # occurrence) alive across retry cycles so a later success re-arms off the
        # grid, not off the backoff time. Cleared on success/exhaustion (finish/3).
        claimed_due: job.claimed_due || job.next_run_at,
        state: "running",
        attempts: Map.get(job, :attempts, 0) + 1,
        updated_at: now
    }
  end

  @doc """
  Apply a run result to a claimed job. An operator pause that landed while
  this occurrence was in flight must survive the task result: record the
  outcome, clear the claim, but do NOT rebuild the job "active"/re-arm it
  (delete already survives — a terminal job is removed from the caller's job
  map before `finish/3` is ever reached).
  """
  def finish(job, result, now) do
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
      complete(job, result, now)
    end
  end

  @doc """
  Complete a claimed occurrence. `%{status: "ok"}` re-arms a recurring job
  from the grid (or parks it "done" once no next occurrence exists / it was
  one-shot); any other result either retries (attempts < max_attempts) or
  hands off to the exhaustion/breaker path.
  """
  def complete(job, %{status: "ok"} = result, now) do
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

  def complete(job, result, now) do
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
  # ORIGINAL claimed_due, not `now` — the retry-grid fix in claim/2 keeps that due
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

  @doc """
  Resume a paused job: clear the breaker (paused_by/consecutive_failures),
  then apply the misfire policy via `apply_resume_misfire/2`. Caller is
  responsible for the "only paused jobs may resume" guard — this function
  assumes the caller already validated `job.state == "paused"`.
  """
  def resume(job, now) do
    %{job | state: "active", paused_by: nil, consecutive_failures: 0, updated_at: now}
    |> apply_resume_misfire(now)
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

  # Boot-time recovery: any job found "running" (crashed mid-claim) is re-armed.
  # One-shot: unchanged from 0.1.1 (fires again immediately). Recurring: apply the
  # same misfire policy as a manual resume (coalesce -> now, skip -> the next future
  # grid point) — the caller backfills :misfire ("coalesce" default) for every
  # loaded job, including 0.1.1-era rows that never had the field.
  def recover(%{state: "running"} = job, now) do
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

  def recover(job, _now), do: job

  # Load-time misfire pass for ORDINARY downtime: an ACTIVE recurring job whose
  # stored next_run_at is already past missed occurrences while the scheduler
  # simply wasn't running (no crash mid-run — recover/2 handles that).
  # "skip" advances to the next FUTURE grid point (no catch-up delivery, same
  # grid base as the missed due); "coalesce" (default) leaves the past due in
  # place — exactly one catch-up, unchanged behavior. One-shots are untouched
  # (a past one-shot still fires its catch-up). Runs after recover/2, which
  # never leaves a strictly-past next_run_at, so the passes don't overlap.
  def apply_load_misfire(%{state: "active", misfire: "skip", next_run_at: due} = job, now)
      when is_integer(due) and due < now do
    if Schedule.recurring?(Map.get(job, :schedule)) do
      case Schedule.next_after(job.schedule, due, now) do
        {:ok, next} ->
          %{job | next_run_at: next, updated_at: now}

        # :none or {:error, _}: nothing to arm — same shape as a skip resume.
        # Record the schedule error to prevent silent-park; observable via last_error.
        _no_next ->
          %{
            job
            | next_run_at: nil,
              last_error: "schedule error: no next occurrence at load",
              updated_at: now
          }
      end
    else
      job
    end
  end

  def apply_load_misfire(job, _now), do: job
end

# Cron.Job core: pure job-lifecycle state machine (claim/complete/exhaust/
# misfire/recover) for Genswarms.Cron. Standalone — no store, no timers, no
# network, direct calls against the extracted module (arch review I-1):
#   mix run checks/cron_job_test.exs
ExUnit.start()

defmodule CronJobFixtures do
  @moduledoc false

  def base_job(overrides \\ %{}) do
    Map.merge(
      %{
        id: 1,
        state: "active",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        next_run_at: 1_000,
        last_run_at: nil,
        last_status: nil,
        last_error: nil,
        misfire: "coalesce",
        consecutive_failures: 0,
        paused_by: nil,
        claimed_due: nil,
        attempts: 0,
        max_attempts: 3,
        retry_backoff_ms: 60_000,
        breaker_threshold: 2,
        created_at: 0,
        updated_at: 0
      },
      overrides
    )
  end

  def every_5s, do: %{"kind" => "every_ms", "every_ms" => 5_000}

  # CronExpr.next returns :none within its search bound for an unsatisfiable
  # expression (Feb 30 never occurs) — mirrors checks/cron_expr_test.exs.
  def unsatisfiable_cron, do: %{"kind" => "cron", "expr" => "0 0 30 2 *"}

  # A stored expr that fails to parse — CronExpr.parse's {:error, _} propagates
  # through Schedule.next_after's `with`. Models a poisoned/corrupt store row.
  def poisoned_cron, do: %{"kind" => "cron", "expr" => "not a cron expression"}
end

defmodule CronJobClaimTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "claim/2 marks the job running, bumps attempts, stashes the occurrence's due point" do
    job = base_job(%{next_run_at: 5_000, claimed_due: nil, attempts: 0})
    claimed = Job.claim(job, 5_050)

    assert claimed.state == "running"
    assert claimed.attempts == 1
    assert claimed.last_run_at == 5_050
    assert claimed.next_run_at == nil
    assert claimed.claimed_due == 5_000
    assert claimed.updated_at == 5_050
  end

  test "claim/2 keeps the original claimed_due across a retry cycle (never overwritten by the backoff time)" do
    # Simulates the second claim of the same occurrence: next_run_at is now the
    # retry backoff timestamp, not the true due point — claimed_due (set on the
    # first claim) must survive untouched.
    job = base_job(%{next_run_at: 6_000, claimed_due: 5_000, attempts: 1})
    claimed = Job.claim(job, 6_100)

    assert claimed.claimed_due == 5_000
    assert claimed.attempts == 2
  end
end

defmodule CronJobCompleteHappyPathTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "complete/3 ok on a one-shot job parks it done" do
    job =
      base_job(%{
        state: "running",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        claimed_due: 1_000,
        attempts: 1
      })

    done = Job.complete(job, %{status: "ok", error: nil}, 1_050)

    assert done.state == "done"
    assert done.next_run_at == nil
    assert done.claimed_due == nil
    assert done.last_status == "ok"
    assert done.last_error == nil
  end

  test "complete/3 ok on a recurring job re-arms from claimed_due (not now) and resets attempts/breaker" do
    job =
      base_job(%{
        state: "running",
        schedule: every_5s(),
        claimed_due: 1_000,
        attempts: 2,
        consecutive_failures: 1
      })

    active = Job.complete(job, %{status: "ok", error: nil}, 1_200)

    assert active.state == "active"
    # grid rule from the claimed due point (1000), not the completion time (1200)
    assert active.next_run_at == 6_000
    assert active.claimed_due == nil
    assert active.attempts == 0
    assert active.consecutive_failures == 0
    assert active.last_error == nil
  end
end

defmodule CronJobRetryTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "complete/3 error below max_attempts retries with backoff, no breaker movement" do
    job =
      base_job(%{
        state: "running",
        schedule: every_5s(),
        claimed_due: 1_000,
        attempts: 1,
        max_attempts: 3,
        retry_backoff_ms: 1_000,
        consecutive_failures: 0
      })

    retried = Job.complete(job, %{status: "error", error: "boom"}, 1_050)

    assert retried.state == "active"
    assert retried.next_run_at == 1_050 + 1_000
    assert retried.last_status == "error"
    assert retried.last_error == "boom"
    # exhaustion/breaker machinery is untouched below max_attempts
    assert retried.consecutive_failures == 0
  end
end

defmodule CronJobBreakerTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "complete/3 error at max_attempts on a recurring job below breaker_threshold re-arms from the original grid" do
    job =
      base_job(%{
        state: "running",
        schedule: every_5s(),
        claimed_due: 1_000,
        attempts: 3,
        max_attempts: 3,
        breaker_threshold: 5,
        consecutive_failures: 1
      })

    exhausted = Job.complete(job, %{status: "error", error: "boom"}, 1_200)

    assert exhausted.state == "active"
    assert exhausted.consecutive_failures == 2
    assert exhausted.attempts == 0
    assert exhausted.next_run_at == 6_000
    assert exhausted.claimed_due == nil
  end

  test "complete/3 trips the breaker exactly at consecutive_failures == breaker_threshold" do
    job =
      base_job(%{
        state: "running",
        schedule: every_5s(),
        claimed_due: 1_000,
        attempts: 3,
        max_attempts: 3,
        breaker_threshold: 2,
        consecutive_failures: 1
      })

    paused = Job.complete(job, %{status: "error", error: "boom"}, 1_200)

    assert paused.state == "paused"
    assert paused.paused_by == "breaker"
    assert paused.next_run_at == nil
    assert paused.consecutive_failures == 2
  end

  test "complete/3 exhaustion on a one-shot job is always terminal failed — breaker never applies" do
    job =
      base_job(%{
        state: "running",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        claimed_due: 1_000,
        attempts: 3,
        max_attempts: 3,
        breaker_threshold: 1,
        consecutive_failures: 0
      })

    failed = Job.complete(job, %{status: "error", error: "boom"}, 1_200)

    assert failed.state == "failed"
    assert failed.next_run_at == nil
    assert failed.last_error == "boom"
    # one-shot exhaustion doesn't touch the breaker counter
    assert failed.consecutive_failures == 0
  end
end

defmodule CronJobTerminalGuardTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "complete/3 ok folds Schedule.next_after :none into terminal done with no last_error" do
    job =
      base_job(%{
        state: "running",
        schedule: unsatisfiable_cron(),
        claimed_due: 1_000,
        attempts: 1
      })

    done = Job.complete(job, %{status: "ok", error: nil}, 1_050)

    assert done.state == "done"
    assert done.next_run_at == nil
    assert done.last_error == nil
  end

  test "complete/3 ok folds Schedule.next_after {:error, _} (poisoned expr) into terminal done, reason kept in last_error" do
    job =
      base_job(%{
        state: "running",
        schedule: poisoned_cron(),
        claimed_due: 1_000,
        attempts: 1
      })

    done = Job.complete(job, %{status: "ok", error: nil}, 1_050)

    assert done.state == "done"
    assert done.next_run_at == nil
    assert done.last_error =~ "schedule error:"
  end

  test "complete/3 exhaustion folds a poisoned expr's no-next-occurrence into terminal failed" do
    job =
      base_job(%{
        state: "running",
        schedule: poisoned_cron(),
        claimed_due: 1_000,
        attempts: 3,
        max_attempts: 3,
        breaker_threshold: 5,
        consecutive_failures: 0
      })

    failed = Job.complete(job, %{status: "error", error: "boom"}, 1_050)

    assert failed.state == "failed"
    assert failed.next_run_at == nil
    # the more proximate delivery error wins over the schedule error here
    assert failed.last_error == "boom"
  end
end

defmodule CronJobFinishPauseTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "finish/3 preserves a pause that landed while the occurrence was in flight — no re-arm" do
    job =
      base_job(%{
        state: "paused",
        paused_by: "operator",
        schedule: every_5s(),
        claimed_due: 1_000,
        attempts: 1,
        next_run_at: nil
      })

    finished = Job.finish(job, %{status: "ok", error: nil}, 1_050)

    assert finished.state == "paused"
    assert finished.paused_by == "operator"
    assert finished.claimed_due == nil
    assert finished.attempts == 0
    assert finished.last_status == "ok"
    assert finished.next_run_at == nil
  end

  test "finish/3 dispatches a non-paused job through complete/3" do
    job =
      base_job(%{
        state: "running",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        claimed_due: 1_000,
        attempts: 1
      })

    finished = Job.finish(job, %{status: "ok", error: nil}, 1_050)
    assert finished.state == "done"
  end
end

defmodule CronJobResumeTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "resume/2 clears the breaker and, for a recurring job with a missed due point, coalesces to now by default" do
    job =
      base_job(%{
        state: "paused",
        paused_by: "breaker",
        schedule: every_5s(),
        misfire: "coalesce",
        next_run_at: nil,
        consecutive_failures: 3
      })

    resumed = Job.resume(job, 9_000)

    assert resumed.state == "active"
    assert resumed.paused_by == nil
    assert resumed.consecutive_failures == 0
    assert resumed.next_run_at == 9_000
  end

  test "resume/2 with misfire \"skip\" jumps to the next FUTURE grid point instead of firing immediately" do
    job =
      base_job(%{
        state: "paused",
        paused_by: "breaker",
        schedule: every_5s(),
        misfire: "skip",
        next_run_at: nil,
        last_run_at: 1_000,
        created_at: 0
      })

    resumed = Job.resume(job, 9_000)

    # grid from last_run_at (1000), step 5000: ...,6000,11000,... — smallest strictly after 9000 is 11000
    assert resumed.next_run_at == 11_000
  end

  test "resume/2 leaves a still-future next_run_at alone (resuming early shouldn't fire early)" do
    job =
      base_job(%{
        state: "paused",
        schedule: every_5s(),
        misfire: "coalesce",
        next_run_at: 50_000
      })

    resumed = Job.resume(job, 9_000)
    assert resumed.next_run_at == 50_000
  end

  test "resume/2 on a one-shot job with no future run_at leaves next_run_at nil (unchanged 0.1.1 behavior)" do
    job =
      base_job(%{
        state: "paused",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        misfire: "coalesce",
        next_run_at: nil
      })

    resumed = Job.resume(job, 9_000)
    assert resumed.next_run_at == nil
  end
end

defmodule CronJobRecoverTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "recover/2 on a job stuck \"running\" (one-shot) re-arms to fire again immediately" do
    job =
      base_job(%{
        state: "running",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000}
      })

    recovered = Job.recover(job, 9_000)

    assert recovered.state == "active"
    assert recovered.next_run_at == 9_000
    assert recovered.last_status == "recovered"
    assert recovered.last_error == "scheduler restarted while job was running"
  end

  test "recover/2 on a recurring job defaults to coalesce (fires now)" do
    job = base_job(%{state: "running", schedule: every_5s(), misfire: "coalesce"})
    recovered = Job.recover(job, 9_000)
    assert recovered.next_run_at == 9_000
  end

  test "recover/2 with misfire \"skip\" advances to the next future grid point" do
    job =
      base_job(%{
        state: "running",
        schedule: every_5s(),
        misfire: "skip",
        last_run_at: 1_000,
        created_at: 0
      })

    recovered = Job.recover(job, 9_000)
    assert recovered.next_run_at == 11_000
  end

  test "recover/2 falls back to the coalesce recovery point instead of crashing on a poisoned skip expr (boot-crash guard)" do
    job =
      base_job(%{
        state: "running",
        schedule: poisoned_cron(),
        misfire: "skip",
        last_run_at: 1_000,
        created_at: 0
      })

    recovered = Job.recover(job, 9_000)
    assert recovered.state == "active"
    assert recovered.next_run_at == 9_000
  end

  test "recover/2 leaves a non-\"running\" job untouched" do
    job = base_job(%{state: "active", next_run_at: 1_234})
    assert Job.recover(job, 9_000) == job
  end
end

defmodule CronJobLoadMisfireTest do
  use ExUnit.Case, async: false
  alias Genswarms.Cron.Job
  import CronJobFixtures

  test "apply_load_misfire/2 skip advances a past-due recurring job to the next future grid point" do
    job =
      base_job(%{
        state: "active",
        schedule: every_5s(),
        misfire: "skip",
        next_run_at: 1_000
      })

    advanced = Job.apply_load_misfire(job, 9_000)
    assert advanced.next_run_at == 11_000
  end

  test "apply_load_misfire/2 coalesce (default) leaves the past due in place — exactly one catch-up" do
    job =
      base_job(%{
        state: "active",
        schedule: every_5s(),
        misfire: "coalesce",
        next_run_at: 1_000
      })

    assert Job.apply_load_misfire(job, 9_000) == job
  end

  test "apply_load_misfire/2 skip on a one-shot job is untouched — the past one-shot still fires its catch-up" do
    job =
      base_job(%{
        state: "active",
        schedule: %{"kind" => "run_at", "run_at_ms" => 1_000},
        misfire: "skip",
        next_run_at: 1_000
      })

    assert Job.apply_load_misfire(job, 9_000) == job
  end

  test "apply_load_misfire/2 skip with no next occurrence records the schedule error instead of silently parking" do
    job =
      base_job(%{
        state: "active",
        schedule: unsatisfiable_cron(),
        misfire: "skip",
        next_run_at: 1_000
      })

    parked = Job.apply_load_misfire(job, 9_000)
    assert parked.next_run_at == nil
    assert parked.last_error == "schedule error: no next occurrence at load"
  end

  test "apply_load_misfire/2 leaves a non-active job (e.g. paused) untouched" do
    job = base_job(%{state: "paused", schedule: every_5s(), misfire: "skip", next_run_at: 1_000})
    assert Job.apply_load_misfire(job, 9_000) == job
  end
end

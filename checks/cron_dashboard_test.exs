# Cron dashboard surface (display story events + probed extension).
#
#   mix run checks/cron_dashboard_test.exs
#
# Pins:
#   * dashboard_extension/1 without a store is inert (%{});
#   * with a store it renders the durable jobs table in the generic page schema
#     (the host probes this via function_exported? — no compile dep either way);
#   * emit-site source contract: the job-finish path carries a :job_run display
#     emit (status included) and the breaker pause emits its own story beat —
#     the scheduler was a black box on the events canvas before these.
ExUnit.start()

defmodule Genswarms.CronDashboardStore do
  def load_cron_jobs(_states) do
    [
      %{
        name: "tips",
        state: "active",
        schedule: %{"cron" => "0 10 * * *"},
        payload: %{"target" => "proactive"},
        next_run_at: 1_783_150_000_000,
        last_status: "ok",
        consecutive_failures: 0
      },
      %{
        name: "outreach",
        state: "paused",
        schedule: %{"every_ms" => 300_000},
        payload: %{"target" => "proactive"},
        next_run_at: nil,
        last_status: "error",
        consecutive_failures: 3
      }
    ]
  end
end

defmodule Genswarms.CronDashboardTest do
  use ExUnit.Case

  @source File.read!(Path.join([__DIR__, "..", "packages", "cron", "cron.ex"]))

  test "no store -> inert extension" do
    assert Genswarms.Cron.dashboard_extension([]) == %{}
  end

  test "with a store -> generic page schema with the jobs table" do
    %{"dashboard_pages" => [page]} =
      Genswarms.Cron.dashboard_extension(store_mod: Genswarms.CronDashboardStore)

    assert page["id"] == "cron-jobs"
    [metrics, table] = page["sections"]
    assert metrics["type"] == "metrics"

    assert %{"label" => "Paused", "value" => 1} =
             Enum.find(metrics["items"], &(&1["label"] == "Paused"))

    assert %{"label" => "Failing", "value" => 1} =
             Enum.find(metrics["items"], &(&1["label"] == "Failing"))

    assert table["type"] == "table"
    [tips_row, outreach_row] = table["rows"]
    assert tips_row["schedule"] == "cron 0 10 * * *"
    assert tips_row["target"] == "proactive"
    assert outreach_row["schedule"] == "every 300s"
    assert outreach_row["failures"] == 3
    assert outreach_row["next_run"] == "—"
  end

  test "raw store wrapper rows ({id, state, data-json}) normalize like boot does" do
    defmodule WrapperStore do
      def load_cron_jobs(_states) do
        [
          %{
            id: 7,
            state: "active",
            data: %{
              "id" => 7,
              "name" => "tips",
              "state" => "active",
              "schedule" => %{"kind" => "cron", "expr" => "0 10 * * *"},
              "payload" => %{"target" => "proactive"},
              "next_run_at" => 1_783_150_000_000,
              "last_status" => "ok",
              "consecutive_failures" => 0
            }
          }
        ]
      end
    end

    %{"dashboard_pages" => [page]} = Genswarms.Cron.dashboard_extension(store_mod: WrapperStore)
    [_, table] = page["sections"]
    assert [row] = table["rows"]
    assert row["name"] == "tips"
    assert row["schedule"] == "cron 0 10 * * *"
    assert row["target"] == "proactive"
    assert row["last_status"] == "ok"
  end

  test "a dead store never raises out of the extension" do
    assert %{"dashboard_pages" => [page]} =
             Genswarms.Cron.dashboard_extension(store_mod: NoSuchStoreModule)

    assert [%{"items" => items} | _] = page["sections"]
    assert %{"label" => "Jobs", "value" => 0} = Enum.find(items, &(&1["label"] == "Jobs"))
  end

  test "without a store the machine block is absent too (still %{})" do
    assert Genswarms.Cron.dashboard_extension([]) == %{}
  end

  test "with a store -> \"cron\" machine block (v1) alongside unchanged dashboard_pages" do
    extension = Genswarms.Cron.dashboard_extension(store_mod: Genswarms.CronDashboardStore)

    assert %{"dashboard_pages" => [page], "cron" => cron} = extension
    assert cron["v"] == 1

    assert [tips_job, outreach_job] = cron["jobs"]

    assert tips_job == %{
             "name" => "tips",
             "next_run_at_ms" => 1_783_150_000_000,
             "last_run_at_ms" => nil,
             "state" => "active",
             "consec_failures" => 0
           }

    assert outreach_job == %{
             "name" => "outreach",
             "next_run_at_ms" => nil,
             "last_run_at_ms" => nil,
             "state" => "paused",
             "consec_failures" => 3
           }

    assert cron["health_rules"] == [
             %{
               "id" => "missed_tick",
               "severity" => "warn",
               "card" => "cron job {name} did not run (overdue past grace)",
               "each" => "jobs",
               "where" => %{
                 "op" => "eq",
                 "lhs" => %{"path" => "state"},
                 "rhs" => %{"lit" => "active"}
               },
               "when" => %{
                 "op" => "gt",
                 "lhs" => "now",
                 "rhs" => %{"add" => [%{"path" => "next_run_at_ms"}, 1_800_000]}
               }
             },
             %{
               "id" => "job_failing",
               "severity" => "warn",
               "card" => "cron job {name} failing repeatedly ({consec_failures} consecutive)",
               "each" => "jobs",
               "when" => %{"op" => "gte", "lhs" => %{"path" => "consec_failures"}, "rhs" => 5}
             }
           ]

    # dashboard_pages stays byte-identical to the pre-existing shape.
    assert page["id"] == "cron-jobs"
    [metrics, table] = page["sections"]
    assert metrics["type"] == "metrics"
    assert table["type"] == "table"
  end

  test "a job with a non-integer next_run_at/last_run_at passes through as nil (int_or_nil)" do
    defmodule WeirdTimesStore do
      def load_cron_jobs(_states) do
        [
          %{
            name: "weird",
            state: "running",
            next_run_at: "not-a-time",
            last_run_at: 1_700_000_000_000,
            consecutive_failures: 1
          }
        ]
      end
    end

    %{"cron" => cron} = Genswarms.Cron.dashboard_extension(store_mod: WeirdTimesStore)

    assert cron["jobs"] == [
             %{
               "name" => "weird",
               "next_run_at_ms" => nil,
               "last_run_at_ms" => 1_700_000_000_000,
               "state" => "running",
               "consec_failures" => 1
             }
           ]
  end

  test "emit-site contract: job finish emits :job_run with status; breaker pause is its own beat" do
    assert @source =~ "kind: :job_run"
    [_, after_finish] = String.split(@source, "Scheduled job run finished", parts: 2)
    window = String.slice(after_finish, 0, 2000)
    assert window =~ "emit_display(%{"
    assert window =~ "status: result.status"
    assert window =~ "status: \"breaker_paused\""
  end
end

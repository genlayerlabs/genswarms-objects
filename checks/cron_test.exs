# Global cron object: datetime wakeup + deterministic dispatch.
#
#   mix run tests/ops/cron_test.exs

alias Genswarms.Cron
alias Genswarms.Cron.Schedule, as: CronSchedule

{:ok, fails} = Agent.start_link(fn -> [] end)

check = fn name, cond ->
  if cond do
    IO.puts("  \e[32m✓\e[0m #{name}")
  else
    IO.puts("  \e[31m✗ #{name}\e[0m")
    Agent.update(fails, &[name | &1])
  end
end

IO.puts("\n══ Global cron scheduler (datetime wakeup + target message) ══\n")

ms = fn iso ->
  {:ok, dt, _} = DateTime.from_iso8601(iso)
  DateTime.to_unix(dt, :millisecond)
end

cron_now = ms.("2026-06-09T06:50:00Z")
{:ok, exact_ms} = CronSchedule.parse("2026-06-09T07:00:00Z")
{:ok, date_ms} = CronSchedule.parse("2026-06-09")
{:ok, integer_ms} = CronSchedule.parse(div(cron_now, 1000))

check.(
  "cron schedule is one datetime, not a cron-expression language",
  exact_ms == ms.("2026-06-09T07:00:00Z") and date_ms == ms.("2026-06-09T00:00:00Z") and
    integer_ms == cron_now and match?({:error, _}, CronSchedule.parse("0 9 * * *")) and
    match?({:error, _}, CronSchedule.parse("every 15m"))
)

{:ok, cron_clock} = Agent.start_link(fn -> cron_now end)
{:ok, cron_sink} = Agent.start_link(fn -> [] end)

cron_deliver = fn target, from, content ->
  Agent.update(cron_sink, &[{target, from, Jason.decode!(content)} | &1])
  :ok
end

cron_messages = fn -> Agent.get(cron_sink, &Enum.reverse(&1)) end

{:ok, cron_state} =
  Cron.init(%{
    name: :cron,
    swarm_name: "test",
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(cron_clock, & &1) end,
    deliver_fn: cron_deliver,
    trusted_sources: [:tg_ingress],
    allowed_targets: %{test_sink: ["do_work"]}
  })

{:reply, cron_create_reply, cron_state} =
  Cron.handle_message(
    :tg_ingress,
    Jason.encode!(%{
      action: "create_job",
      name: "target message smoke",
      run_at: cron_now,
      target: "test_sink",
      message: %{"action" => "do_work", "value" => 42}
    }),
    cron_state
  )

cron_created = Jason.decode!(cron_create_reply)

check.(
  "cron create_job accepts one allowlisted target message",
  cron_created["ok"] == true and cron_created["job_id"] == 1
)

{:reply, cron_dedupe_reply_1, cron_state} =
  Cron.handle_message(
    :tg_ingress,
    Jason.encode!(%{
      action: "create_job",
      run_at: cron_now + 60_000,
      target: "test_sink",
      message: %{action: "do_work", value: 43},
      dedupe_key: "same-future-job"
    }),
    cron_state
  )

{:reply, cron_dedupe_reply_2, cron_state} =
  Cron.handle_message(
    :tg_ingress,
    Jason.encode!(%{
      action: "create_job",
      run_at: cron_now + 60_000,
      target: "test_sink",
      message: %{action: "do_work", value: 43},
      dedupe_key: "same-future-job"
    }),
    cron_state
  )

cron_dedupe_1 = Jason.decode!(cron_dedupe_reply_1)
cron_dedupe_2 = Jason.decode!(cron_dedupe_reply_2)

check.(
  "cron create_job dedupes active jobs by dedupe_key",
  cron_dedupe_1["ok"] == true and cron_dedupe_2["deduped"] == true and
    cron_dedupe_2["job_id"] == cron_dedupe_1["job_id"] and map_size(cron_state.jobs) == 2
)

interface_actions = Cron.interface() |> Map.keys() |> Enum.sort()

check.(
  "cron interface declares every public action including run_now with neutral examples",
  interface_actions == [:create_job, :delete, :list, :pause, :resume, :run_now, :status, :tick] and
    String.contains?(Cron.interface().create_job.input, "\"target\":\"reporter\"") and
    String.contains?(Cron.interface().run_now.input, "\"action\":\"run_now\"")
)

{:reply, unknown_trusted_reply, _cron_state_after_unknown} =
  Cron.handle_message(:tg_ingress, Jason.encode!(%{action: "typo"}), cron_state)

{:noreply, _cron_state_after_untrusted_unknown} =
  Cron.handle_message(:agent_0, Jason.encode!(%{action: "typo"}), cron_state)

check.(
  "trusted decoded unknown actions reply unknown_action; untrusted unknown actions stay silent",
  Jason.decode!(unknown_trusted_reply) == %{"ok" => false, "error" => "unknown_action"}
)

{:ok, cap_state} =
  Cron.init(%{
    name: :cron,
    swarm_name: "test",
    auto_tick: false,
    async?: false,
    max_message_bytes: 120,
    now_fn: fn -> Agent.get(cron_clock, & &1) end,
    deliver_fn: cron_deliver,
    trusted_sources: [:tg_ingress],
    allowed_targets: %{test_sink: ["do_work"]}
  })

oversized_create =
  Jason.encode!(%{
    action: "create_job",
    run_at: cron_now,
    target: "test_sink",
    message: %{"action" => "do_work", "blob" => String.duplicate("x", 200)}
  })

{:reply, oversized_reply, _cap_state} =
  Cron.handle_message(:tg_ingress, oversized_create, cap_state)

check.(
  "oversized trusted create_job payloads are rejected ok:false before decode/work",
  Jason.decode!(oversized_reply) == %{"ok" => false, "error" => "message_too_large"}
)

{:reply, cron_tick_reply, cron_state} =
  Cron.handle_message(:tg_ingress, Jason.encode!(%{action: "tick"}), cron_state)

check.(
  "cron tick launches a due datetime job",
  Jason.decode!(cron_tick_reply)["launched"] == 1 and
    cron_messages.() == [{:test_sink, :cron, %{"action" => "do_work", "value" => 42}}]
)

{:ok, retry_attempts} = Agent.start_link(fn -> 0 end)

retry_deliver = fn _target, _from, _content ->
  attempt = Agent.get_and_update(retry_attempts, &{&1 + 1, &1 + 1})
  if attempt == 1, do: {:error, "temporary outage"}, else: :ok
end

{:ok, retry_state} =
  Cron.init(%{
    name: :cron,
    swarm_name: "test",
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(cron_clock, & &1) end,
    deliver_fn: retry_deliver,
    trusted_sources: [:tg_ingress],
    allowed_targets: %{test_sink: ["do_work"]},
    retry_backoff_ms: 1_000,
    max_attempts: 2
  })

{:reply, retry_create_reply, retry_state} =
  Cron.handle_message(
    :tg_ingress,
    Jason.encode!(%{
      action: "create_job",
      name: "retry smoke",
      run_at: cron_now,
      target: "test_sink",
      message: %{"action" => "do_work"}
    }),
    retry_state
  )

retry_job_id = Jason.decode!(retry_create_reply)["job_id"]

{:reply, retry_tick_reply, retry_state} =
  Cron.handle_message(:tg_ingress, Jason.encode!(%{action: "tick"}), retry_state)

retry_job_after_error = Map.fetch!(retry_state.jobs, retry_job_id)

check.(
  "cron failed dispatch stays active with bounded retry instead of being lost",
  Jason.decode!(retry_tick_reply)["launched"] == 1 and retry_job_after_error.state == "active" and
    retry_job_after_error.attempts == 1 and retry_job_after_error.next_run_at == cron_now + 1_000 and
    retry_job_after_error.last_error == "temporary outage"
)

Agent.update(cron_clock, fn _ -> cron_now + 1_000 end)

{:reply, retry_success_reply, retry_state} =
  Cron.handle_message(:tg_ingress, Jason.encode!(%{action: "tick"}), retry_state)

check.(
  "cron removes one-shot jobs only after successful target handoff",
  Jason.decode!(retry_success_reply)["launched"] == 1 and
    not Map.has_key?(retry_state.jobs, retry_job_id) and Agent.get(retry_attempts, & &1) == 2
)

Agent.update(cron_clock, fn _ -> cron_now end)

{:reply, denied_reply, _cron_state} =
  Cron.handle_message(
    :tg_ingress,
    Jason.encode!(%{
      action: "create_job",
      run_at: cron_now,
      target: "test_sink",
      message: %{"action" => "not_allowed"}
    }),
    cron_state
  )

check.(
  "cron rejects non-allowlisted target actions",
  Jason.decode!(denied_reply)["ok"] == false
)

Agent.update(cron_sink, fn _ -> [] end)

{:noreply, cron_state_after_agent_forge} =
  Cron.handle_message(
    :agent_0,
    Jason.encode!(%{
      action: "create_job",
      run_at: cron_now,
      target: "test_sink",
      message: %{"action" => "do_work", "value" => 99}
    }),
    cron_state
  )

{:reply, forged_tick_reply, _cron_state_after_forged_tick} =
  Cron.handle_message(:tg_ingress, Jason.encode!(%{action: "tick"}), cron_state_after_agent_forge)

check.(
  "cron ignores create_job messages from agent slots even if the payload looks valid",
  Jason.decode!(forged_tick_reply)["launched"] == 0 and cron_messages.() == []
)

Agent.update(cron_sink, fn _ -> [] end)

{:ok, turn_state} =
  Cron.init(%{
    name: :cron,
    swarm_name: "test",
    auto_tick: false,
    async?: false,
    now_fn: fn -> Agent.get(cron_clock, & &1) end,
    deliver_fn: cron_deliver,
    trusted_sources: [:telegram_conversation_runtime],
    allowed_targets: %{telegram_conversation_runtime: ["scheduled_turn"]}
  })

{:reply, turn_create_reply, turn_state} =
  Cron.handle_message(
    :telegram_conversation_runtime,
    Jason.encode!(%{
      action: "create_job",
      name: "morning markets",
      run_at: cron_now,
      target: "telegram_conversation_runtime",
      message: %{
        "action" => "scheduled_turn",
        "conversation_id" => "tg:903489662:0",
        "prompt" => "Summarize my active markets.",
        "context" => %{"source" => "cron-test"}
      }
    }),
    turn_state
  )

{:reply, _turn_tick_reply, _turn_state} =
  Cron.handle_message(
    :telegram_conversation_runtime,
    Jason.encode!(%{action: "tick"}),
    turn_state
  )

[{turn_target, turn_from, turn_msg}] = cron_messages.()

check.(
  "cron scheduled conversation work is just an allowlisted runtime message",
  Jason.decode!(turn_create_reply)["ok"] == true and turn_target == :telegram_conversation_runtime and
    turn_from == :cron and turn_msg["action"] == "scheduled_turn" and
    turn_msg["conversation_id"] == "tg:903489662:0"
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRON: ALL PASS")
else
  IO.puts("\nCRON FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

{:ok, fails} = Agent.start_link(fn -> [] end)

check = fn name, cond ->
  if cond do
    IO.puts("  \e[32m✓\e[0m #{name}")
  else
    IO.puts("  \e[31m✗ #{name}\e[0m")
    Agent.update(fails, &[name | &1])
  end
end

alias Genswarms.Cron.Schedule

ms = fn iso ->
  {:ok, dt, _} = DateTime.from_iso8601(iso)
  DateTime.to_unix(dt, :millisecond)
end

now = ms.("2026-07-06T14:17:00Z")

IO.puts("\n══ Schedule kinds — normalize / first fire / grid rule ══\n")

check.(
  "normalize: run_at shapes (map, bare string, legacy keys)",
  Schedule.normalize(%{"run_at" => "2026-07-07T10:00:00Z"}, now) ==
    {:ok, %{"kind" => "run_at", "run_at_ms" => ms.("2026-07-07T10:00:00Z")}} and
    Schedule.normalize("2026-07-07T10:00:00Z", now) ==
      {:ok, %{"kind" => "run_at", "run_at_ms" => ms.("2026-07-07T10:00:00Z")}} and
    match?({:ok, %{"kind" => "run_at"}}, Schedule.normalize(%{"at" => "2026-07-07"}, now))
)

check.(
  "normalize: every_ms and cron kinds",
  Schedule.normalize(%{"every_ms" => 300_000}, now) ==
    {:ok, %{"kind" => "every_ms", "every_ms" => 300_000}} and
    Schedule.normalize(%{"cron" => "0 * * * *"}, now) ==
      {:ok, %{"kind" => "cron", "expr" => "0 * * * *"}}
)

check.(
  "normalize rejects: bad every_ms, invalid expr, UNSATISFIABLE expr, junk",
  match?({:error, _}, Schedule.normalize(%{"every_ms" => 0}, now)) and
    match?({:error, _}, Schedule.normalize(%{"cron" => "not an expr"}, now)) and
    match?({:error, _}, Schedule.normalize(%{"cron" => "0 0 30 2 *"}, now)) and
    match?({:error, _}, Schedule.normalize(%{"neither" => 1}, now))
)

{:ok, every5} = Schedule.normalize(%{"every_ms" => 300_000}, now)
{:ok, hourly} = Schedule.normalize(%{"cron" => "0 * * * *"}, now)
{:ok, oneshot} = Schedule.normalize(%{"run_at" => "2026-07-07T10:00:00Z"}, now)

check.(
  "first fire: every_ms = created + period, never immediate",
  Schedule.first_run_at(every5, now) == {:ok, now + 300_000}
)

check.(
  "first fire: cron = next match after created",
  Schedule.first_run_at(hourly, now) == {:ok, ms.("2026-07-06T15:00:00Z")}
)

check.(
  "grid rule: normal cadence advances one period",
  Schedule.next_after(every5, now, now + 1_000) == {:ok, now + 300_000}
)

check.(
  "grid rule: exactly-now boundary advances to the next occurrence, never refires the same point",
  Schedule.next_after(every5, now, now) == {:ok, now + 300_000}
)

check.(
  "grid rule: downtime of 3.5 periods → EXACTLY ONE catch-up, next strictly future",
  Schedule.next_after(every5, now, now + 1_050_000) == {:ok, now + 1_200_000}
)

check.(
  "grid rule REGRESSION: never max(now, due+period) double-fire",
  (fn ->
     {:ok, n} = Schedule.next_after(every5, now, now + 1_050_000)
     n > now + 1_050_000
   end).()
)

check.(
  "grid rule: cron next is after max(due, now)",
  Schedule.next_after(hourly, ms.("2026-07-06T15:00:00Z"), ms.("2026-07-06T18:30:00Z")) ==
    {:ok, ms.("2026-07-06T19:00:00Z")}
)

check.(
  "one-shots have no next; recurring? flags kinds",
  Schedule.next_after(oneshot, now, now) == :none and
    not Schedule.recurring?(oneshot) and Schedule.recurring?(every5) and
    Schedule.recurring?(hourly)
)

check.(
  "degenerate persisted every_ms never crashes or fires into the past",
  Schedule.next_after(%{"kind" => "every_ms", "every_ms" => 0}, now, now + 1) == :none and
    Schedule.next_after(%{"kind" => "every_ms", "every_ms" => -5}, now, now + 1) == :none and
    Schedule.first_run_at(%{"kind" => "every_ms", "every_ms" => 0}, now) ==
      {:error, "invalid schedule"}
)

check.(
  "legacy datetime parse/1 still rejects cron strings (0.1.1 vector holds)",
  match?({:error, _}, Schedule.parse("0 9 * * *"))
)

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nSCHEDULE_KINDS: ALL PASS")
else
  IO.puts("\nSCHEDULE_KINDS FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

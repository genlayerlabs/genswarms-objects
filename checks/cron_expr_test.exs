{:ok, fails} = Agent.start_link(fn -> [] end)

check = fn name, cond ->
  if cond do
    IO.puts("  \e[32m✓\e[0m #{name}")
  else
    IO.puts("  \e[31m✗ #{name}\e[0m")
    Agent.update(fails, &[name | &1])
  end
end

alias Genswarms.Cron.CronExpr

ms = fn iso -> {:ok, dt, _} = DateTime.from_iso8601(iso); DateTime.to_unix(dt, :millisecond) end

IO.puts("\n══ CronExpr — 5-field vixie parser/matcher (UTC, numeric-only) ══\n")

{:ok, hourly} = CronExpr.parse("0 * * * *")
{:ok, quarter} = CronExpr.parse("15,45 * * * *")
{:ok, daily8} = CronExpr.parse("0 8 * * *")
{:ok, steps} = CronExpr.parse("*/15 9-17 * * *")
{:ok, dowj} = CronExpr.parse("0 0 1 * 1")          # DOM=1 OR DOW=Monday (the POSIX quirk)
{:ok, sun7} = CronExpr.parse("0 0 * * 7")           # 7 == Sunday == 0

check.("basic shapes parse",
  match?({:ok, _}, CronExpr.parse("5 * * * *")) and match?({:ok, _}, CronExpr.parse("0 0 * 2 *")))

check.("names, tz, wrong arity, out-of-range are rejected",
  match?({:error, _}, CronExpr.parse("0 0 * JAN *")) and
  match?({:error, _}, CronExpr.parse("0 0 * * MON")) and
  match?({:error, _}, CronExpr.parse("0 0 * *")) and
  match?({:error, _}, CronExpr.parse("60 * * * *")) and
  match?({:error, _}, CronExpr.parse("* 24 * * *")) and
  match?({:error, _}, CronExpr.parse("*/0 * * * *")))

check.("hourly matches :00 only",
  CronExpr.match?(hourly, ms.("2026-07-06T14:00:00Z")) and
  not CronExpr.match?(hourly, ms.("2026-07-06T14:01:00Z")))

check.("lists and steps",
  CronExpr.match?(quarter, ms.("2026-07-06T14:45:00Z")) and
  CronExpr.match?(steps, ms.("2026-07-06T09:30:00Z")) and
  not CronExpr.match?(steps, ms.("2026-07-06T08:45:00Z")))

check.("DOM/DOW both restricted match as OR",
  CronExpr.match?(dowj, ms.("2026-07-06T00:00:00Z")) and   # Monday, DOM=6 → DOW arm
  CronExpr.match?(dowj, ms.("2026-07-01T00:00:00Z")) and   # DOM=1, Wednesday → DOM arm
  not CronExpr.match?(dowj, ms.("2026-07-02T00:00:00Z")))  # DOM=2, Thursday → neither

check.("DOW 7 is Sunday",
  CronExpr.match?(sun7, ms.("2026-07-05T00:00:00Z")))       # 2026-07-05 is a Sunday

check.("daily8 only at 08:00",
  CronExpr.match?(daily8, ms.("2026-07-06T08:00:00Z")) and
  not CronExpr.match?(daily8, ms.("2026-07-06T20:00:00Z")))

failures = Agent.get(fails, &Enum.reverse/1)

if failures == [] do
  IO.puts("\nCRONEXPR: ALL PASS")
else
  IO.puts("\nCRONEXPR FAILURES:")
  Enum.each(failures, &IO.puts(" - #{&1}"))
  System.halt(1)
end

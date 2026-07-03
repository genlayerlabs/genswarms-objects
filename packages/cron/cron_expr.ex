defmodule Genswarms.Cron.CronExpr do
  @moduledoc """
  5-field cron expression parser/matcher. UTC, minute resolution, numeric-only
  (month/day names and `tz` are rejected — reserved). Vixie semantics:
  `minute hour day-of-month month day-of-week`; `*`, lists, ranges, `*/step`;
  DOW 0 and 7 are both Sunday; when BOTH DOM and DOW are restricted the day
  match is their OR (the POSIX quirk).
  """

  def parse(text) when is_binary(text) do
    case String.split(String.trim(text), ~r/\s+/) do
      [min, hour, dom, month, dow] ->
        with {:ok, minutes} <- field(min, 0, 59),
             {:ok, hours} <- field(hour, 0, 23),
             {:ok, doms} <- field(dom, 1, 31),
             {:ok, months} <- field(month, 1, 12),
             {:ok, dows_raw} <- field(dow, 0, 7) do
          dows = dows_raw |> Enum.map(&if(&1 == 7, do: 0, else: &1)) |> MapSet.new()

          {:ok,
           %{
             minutes: MapSet.new(minutes),
             hours: MapSet.new(hours),
             dom: MapSet.new(doms),
             months: MapSet.new(months),
             dow: dows,
             dom_restricted?: dom != "*",
             dow_restricted?: dow != "*",
             tod: for(h <- Enum.sort(hours), m <- Enum.sort(minutes), do: h * 60 + m)
           }}
        end

      _ ->
        {:error, "cron expression needs exactly 5 fields"}
    end
  end

  def parse(_), do: {:error, "cron expression must be a string"}

  # A field is a comma list of *, N, A-B, */S, A-B/S — numeric only.
  defp field(text, lo, hi) do
    text
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case part(part, lo, hi) do
        {:ok, vals} -> {:cont, {:ok, acc ++ vals}}
        {:error, r} -> {:halt, {:error, r}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "empty cron field"}
      other -> other
    end
  end

  defp part(p, lo, hi) do
    case Regex.run(~r/^(\*|\d+|\d+-\d+)(?:\/(\d+))?$/, p) do
      [_, base] -> expand(base, lo, hi, 1)
      [_, base, step] -> expand(base, lo, hi, String.to_integer(step))
      nil -> {:error, "invalid cron field part #{inspect(p)} (numeric only)"}
    end
  end

  defp expand(_base, _lo, _hi, step) when step < 1, do: {:error, "cron step must be >= 1"}

  defp expand("*", lo, hi, step), do: {:ok, Enum.take_every(lo..hi, step)}

  defp expand(base, lo, hi, step) do
    {a, b} =
      case String.split(base, "-") do
        [n] -> {String.to_integer(n), if(step == 1, do: String.to_integer(n), else: hi)}
        [x, y] -> {String.to_integer(x), String.to_integer(y)}
      end

    if a < lo or b > hi or a > b,
      do: {:error, "cron value out of range #{a}-#{b} (allowed #{lo}-#{hi})"},
      else: {:ok, Enum.take_every(a..b, step)}
  end

  def match?(expr, ms) when is_integer(ms) do
    dt = DateTime.from_unix!(div(ms, 60_000) * 60, :second)

    MapSet.member?(expr.minutes, dt.minute) and MapSet.member?(expr.hours, dt.hour) and
      MapSet.member?(expr.months, dt.month) and day_match?(expr, dt)
  end

  @search_days 1830  # ~5 years; an expression with no match in this window is unsatisfiable

  @doc "Smallest match strictly greater than from_ms, or :none within the search bound."
  def next(expr, from_ms) when is_integer(from_ms) do
    from_min = div(from_ms, 60_000)
    start = DateTime.from_unix!((from_min + 1) * 60, :second)

    Enum.reduce_while(0..@search_days, :none, fn d, _ ->
      date = Date.add(DateTime.to_date(start), d)

      if MapSet.member?(expr.months, date.month) and day_match?(expr, date) do
        floor_tod = if d == 0, do: start.hour * 60 + start.minute, else: 0

        case Enum.find(expr.tod, &(&1 >= floor_tod)) do
          nil -> {:cont, :none}
          tod ->
            {:ok, dt} = DateTime.new(date, Time.new!(div(tod, 60), rem(tod, 60), 0), "Etc/UTC")
            {:halt, {:ok, DateTime.to_unix(dt, :millisecond)}}
        end
      else
        {:cont, :none}
      end
    end)
  end

  defp day_match?(expr, d) do
    dom_ok = MapSet.member?(expr.dom, d.day)
    dow_ok = MapSet.member?(expr.dow, Date.day_of_week(d) |> rem(7))

    case {expr.dom_restricted?, expr.dow_restricted?} do
      {true, true} -> dom_ok or dow_ok
      {true, false} -> dom_ok
      {false, true} -> dow_ok
      {false, false} -> true
    end
  end
end

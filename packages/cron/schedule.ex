defmodule Genswarms.Cron.Schedule do
  @moduledoc """
  Schedule kinds for the genswarms cron scheduler package.

  A schedule normalizes to one of three JSON-pure kind maps (persisted
  verbatim): a one-shot `run_at` (Unix milliseconds), a fixed-rate `every_ms`
  interval, or a 5-field UTC `cron` expression. The scheduler wakes a job when
  `next_run_at <= now`; `next_after/3` implements the grid rule — the smallest
  scheduled point strictly after now.
  """

  @doc """
  Parse a due time from a schedule map, ISO8601 string, date-only string, or Unix
  integer. Integers below 10_000_000_000 are seconds; larger integers are ms.
  """
  def parse(value)

  def parse(%{} = schedule) do
    due =
      schedule["run_at"] ||
        schedule[:run_at] ||
        schedule["at"] ||
        schedule[:at] ||
        schedule["next_run_at"] ||
        schedule[:next_run_at]

    parse(due)
  end

  def parse(value) when is_integer(value) and value > 0 do
    if value < 10_000_000_000, do: {:ok, value * 1000}, else: {:ok, value}
  end

  def parse(value) when is_binary(value) do
    text = String.trim(value)

    cond do
      String.contains?(text, "T") ->
        case DateTime.from_iso8601(text) do
          {:ok, dt, _offset} -> {:ok, DateTime.to_unix(dt, :millisecond)}
          {:error, _} -> {:error, "run_at must be ISO8601 with timezone offset"}
        end

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, text) ->
        with {:ok, date} <- Date.from_iso8601(text),
             {:ok, dt} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
          {:ok, DateTime.to_unix(dt, :millisecond)}
        else
          _ -> {:error, "invalid run_at date"}
        end

      true ->
        {:error, "run_at must be an ISO8601 datetime, YYYY-MM-DD date, or Unix timestamp"}
    end
  end

  def parse(_value), do: {:error, "run_at is required"}

  def now_ms, do: System.system_time(:millisecond)

  alias Genswarms.Cron.CronExpr

  @doc """
  Normalize a schedule value into its kind map (JSON-pure, persisted verbatim):
  run_at / every_ms / cron. Cron expressions are validated AND satisfiability-
  checked (a bounded next-match from now must exist).
  """
  def normalize(%{} = m, now_ms) do
    cond do
      every = m["every_ms"] || m[:every_ms] ->
        if is_integer(every) and every > 0,
          do: {:ok, %{"kind" => "every_ms", "every_ms" => every}},
          else: {:error, "every_ms must be a positive integer"}

      expr = m["cron"] || m[:cron] ->
        with {:ok, parsed} <- CronExpr.parse(expr),
             {:ok, _} <- satisfiable(parsed, now_ms) do
          {:ok, %{"kind" => "cron", "expr" => expr}}
        end

      due = m["run_at"] || m[:run_at] || m["at"] || m[:at] || m["next_run_at"] || m[:next_run_at] ->
        with {:ok, ms} <- parse(due), do: {:ok, %{"kind" => "run_at", "run_at_ms" => ms}}

      true ->
        {:error, "schedule needs run_at, every_ms, or cron"}
    end
  end

  def normalize(value, _now_ms) when is_binary(value) or is_integer(value) do
    with {:ok, ms} <- parse(value), do: {:ok, %{"kind" => "run_at", "run_at_ms" => ms}}
  end

  def normalize(_value, _now_ms), do: {:error, "schedule is required"}

  defp satisfiable(parsed, now_ms) do
    case CronExpr.next(parsed, now_ms) do
      {:ok, ms} -> {:ok, ms}
      :none -> {:error, "cron expression is unsatisfiable"}
    end
  end

  def recurring?(%{"kind" => k}), do: k in ["every_ms", "cron"]
  def recurring?(_), do: false

  def first_run_at(%{"kind" => "run_at", "run_at_ms" => ms}, _created), do: {:ok, ms}
  def first_run_at(%{"kind" => "every_ms", "every_ms" => n}, created)
      when is_integer(n) and n > 0 and is_integer(created),
      do: {:ok, created + n}

  def first_run_at(%{"kind" => "cron", "expr" => expr}, created) do
    with {:ok, parsed} <- CronExpr.parse(expr), do: satisfiable(parsed, created)
  end

  def first_run_at(_norm, _created), do: {:error, "invalid schedule"}

  @doc "The grid rule: smallest scheduled point strictly after now (spec-pinned)."
  def next_after(%{"kind" => "every_ms", "every_ms" => n}, due, now)
      when is_integer(due) and is_integer(now) and is_integer(n) and n > 0 do
    {:ok, due + (div(max(now - due, 0), n) + 1) * n}
  end

  def next_after(%{"kind" => "cron", "expr" => expr}, due, now) do
    with {:ok, parsed} <- CronExpr.parse(expr) do
      case CronExpr.next(parsed, max(due, now)) do
        {:ok, ms} -> {:ok, ms}
        :none -> :none
      end
    end
  end

  def next_after(_norm, _due, _now), do: :none
end

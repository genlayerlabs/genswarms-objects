defmodule Genswarms.Cron.Schedule do
  @moduledoc """
  Datetime parsing for the global cron object.

  Micro Markets cron jobs are not a generic cron-expression language. A job has
  one due timestamp, stored as Unix milliseconds, and the scheduler wakes it
  when `next_run_at <= now`.
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
end

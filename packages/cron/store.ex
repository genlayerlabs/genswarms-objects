defmodule Genswarms.Cron.Store do
  @moduledoc """
  Documentation-only behaviour for the `Genswarms.Cron` store seam.

  Nothing in `Genswarms.Cron` requires or checks `@behaviour
  Genswarms.Cron.Store` — the object calls these functions by name via
  `function_exported?/3` (guarded: a nil `store_mod`, or a module missing a
  given function, both degrade to memory-only for that call — jobs still
  run, they just don't survive a restart). Adopters may `@behaviour` this
  module purely to get compiler warnings on drift between their store and
  the seam; it changes no runtime behavior and adds no coupling.

  See the "Store seam contract" section in SKILL.md / README.md for the
  full narrative: the atom-vs-string key split, the no-raise requirement,
  the JSON round-trip, and why `claimed_due` never survives a reload.
  """

  @typedoc """
  A loaded job row, as returned by `c:load_cron_jobs/1`.

  `id` and `state` are ATOM keys on the row itself (`%{id: ..., state: ...,
  data: ...}`); a row shaped with string keys instead (`%{"id" => ...}`)
  crashes `Genswarms.Cron.init/1` with a `FunctionClauseError` — there is no
  fallback clause. `data` is the string-keyed JSON round-trip of the job map
  handed to `c:save_cron_job/1` (i.e. `job |> Jason.encode!() |>
  Jason.decode!()`), NOT the raw atom-keyed job map.
  """
  @type job_row :: %{id: integer() | String.t(), state: String.t(), data: map()}

  @typedoc "The full job map as built/updated by `Genswarms.Cron` (atom keys at the top level; string keys inside the nested `schedule`/`payload`/`origin` maps)."
  @type job :: map()

  @typedoc "A single run outcome, as passed to `c:save_cron_run/2`."
  @type run_result :: %{
          status: String.t(),
          started_at: integer(),
          finished_at: integer(),
          error: String.t() | nil
        }

  @doc """
  Load persisted jobs whose `state` is in `states` — a list of STRING state
  names. `Genswarms.Cron` calls this with `["active", "paused", "running"]`
  at boot (recovery) and with `["done", "deleted", "failed"]` for terminal
  dedupe lookups (`once: true` on `create_job`, and one-shot `seed_jobs`
  re-fire guards).

  MUST return a list of `t:job_row/0`. MUST NOT raise — guarded calls do not
  catch exceptions, so a raise here reaches the engine as an uncovered
  `init/1` crash (see the boot-abort note in SKILL.md). Return `[]` when
  nothing matches.
  """
  @callback load_cron_jobs(states :: [String.t()]) :: [job_row()]

  @doc """
  Return the highest job id ever persisted. Used only to seed the in-memory
  id counter above whatever the loaded jobs already imply. Accepts an
  integer or a numeric string (`Genswarms.Cron` coerces via its own
  `to_id/1`); a missing/invalid value defaults to `0`. MUST NOT raise.
  """
  @callback max_cron_job_id() :: integer() | String.t() | nil

  @doc """
  Persist (upsert) a job. `job` is the full atom-keyed job map described by
  `t:job/0`. Called after every state transition (create, claim, finish,
  pause/resume/delete, seed upsert) — expect frequent calls. Return value is
  ignored; MUST NOT raise.
  """
  @callback save_cron_job(job :: job()) :: any()

  @doc """
  Record one run outcome for audit/history. `job` is the already-updated job
  map (post-completion); `result` is the raw run result. Return value is
  ignored; MUST NOT raise.
  """
  @callback save_cron_run(job :: job(), result :: run_result()) :: any()

  @optional_callbacks load_cron_jobs: 1, max_cron_job_id: 0, save_cron_job: 1, save_cron_run: 2
end

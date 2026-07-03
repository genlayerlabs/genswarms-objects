defmodule Genswarms.Tips do
  @moduledoc """
  Tips — a generic rotating-content dispenser.

  Fragment pools (e.g. openers / bodies / closers) are assembled per recipient
  by a configurable slot template: `rotate: true` slots are seen-tracked and
  never repeat within a pool cycle; `rotate: false` slots are weighted random
  dressing. `draw` is a seeded PURE read (same recipient+date => same message —
  crash-safe retries) and echoes `recipient_id` and `date` in the reply;
  `commit` records delivery, handles exhaustion reshuffle, and echoes `recipient_id`.
  Content lifecycle: `add_fragments` lands `"pending"`,
  `promote` -> `"live"` (the only drawable status), `retire` -> `"retired"`
  (never deleted; a retired id stays in seen-state).

  The object makes NO trust decisions: recipient selection, consent, and rate
  limits belong to the caller (in wingston: roster). Wire it behind the swarm
  topology, not agent-callable.

  ## Config
    - `template` — ordered slot list `[%{kind: "opener", rotate: false}, ...]`
      (string or atom keys); default opener/body(rotate)/closer.
    - `salt` — seed component, default "tips-v1". Change to reshuffle everyone.
    - `reshuffle_guard` — ids kept on exhaustion reshuffle (default 20).
    - `store` — optional module (atom or string, resolved without atom
      minting). Memory-only without one — the documented dev mode.

  ## Store seam (every callback optional; guarded by function_exported?)
      load_fragments() :: [fragment_map]           # full pool at boot
      load_seen()      :: %{recipient => [id]}     # oldest-first per recipient
      save_fragment(fragment_map) :: any           # upsert by :id
      save_fragment_status(id, status) :: any
      add_seen(recipient_id, ids) :: any           # upsert rows at now()
      replace_seen(recipient_id, keep_ids) :: any  # reshuffle: delete the rest
  """

  alias Genswarms.Tips.Core

  @default_template [
    %{kind: "opener", rotate: false},
    %{kind: "body", rotate: true},
    %{kind: "closer", rotate: false}
  ]
  @default_salt "tips-v1"
  @default_guard 20

  def init(config) do
    store = module_ref(Map.get(config, :store))

    {:ok,
     %{
       store: store,
       template: normalize_template(Map.get(config, :template)),
       salt: Map.get(config, :salt, @default_salt),
       guard: normalize_guard(Map.get(config, :reshuffle_guard, @default_guard)),
       fragments: load_fragments(store),
       seen: load_seen(store)
     }}
  end

  def interface do
    %{
      draw: %{
        input: ~s({"action":"draw","recipient_id":"tg:1:0","date":"2026-07-03"}),
        output: ~s({"ok":true,"text":"...","fragment_ids":["a1b2..."],"recipient_id":"tg:1:0","date":"2026-07-03"})
      },
      commit: %{
        input: ~s({"action":"commit","recipient_id":"tg:1:0","fragment_ids":["a1b2..."]}),
        output: ~s({"ok":true,"reshuffled":false,"recipient_id":"tg:1:0"})
      },
      add_fragments: %{
        input:
          ~s({"action":"add_fragments","fragments":[{"kind":"body","text":"...","category":"hooks","weight":1}]}),
        output: ~s({"ok":true,"count":1,"ids":["a1b2..."]})
      },
      promote: %{input: ~s({"action":"promote","ids":["a1b2..."]}), output: ~s({"ok":true,"count":1})},
      retire: %{input: ~s({"action":"retire","ids":["a1b2..."]}), output: ~s({"ok":true,"count":1})},
      stats: %{
        input: ~s({"action":"stats"}),
        output: ~s({"ok":true,"fragments":{"body/live":100},"recipients":42})
      }
    }
  end

  def handle_message(_from, content, state) do
    case Jason.decode(content) do
      {:ok, %{"action" => "draw", "recipient_id" => r, "date" => d}}
      when is_binary(r) and is_binary(d) ->
        case Core.draw(state.fragments, state.seen, state.template, r, d, state.salt, state.guard) do
          {:ok, %{text: text, rotating_ids: ids}} ->
            {:reply, Jason.encode!(%{ok: true, text: text, fragment_ids: ids, recipient_id: r, date: d}), state}

          {:error, :empty_pool} ->
            {:reply, Jason.encode!(%{ok: false, error: "empty_pool", recipient_id: r}), state}
        end

      {:ok, %{"action" => "commit", "recipient_id" => r, "fragment_ids" => ids}}
      when is_binary(r) and is_list(ids) ->
        ids = Enum.filter(ids, &is_binary/1)
        seen_list = Map.get(state.seen, r, [])
        {seen_list, reshuffled} = Core.commit(state.fragments, state.template, seen_list, ids, state.guard)
        state = %{state | seen: Map.put(state.seen, r, seen_list)}

        if reshuffled,
          do: store_call(state.store, :replace_seen, [r, seen_list]),
          else: store_call(state.store, :add_seen, [r, ids])

        {:reply, Jason.encode!(%{ok: true, reshuffled: reshuffled, recipient_id: r}), state}

      {:ok, %{"action" => "add_fragments", "fragments" => frags}} when is_list(frags) ->
        add_fragments(frags, state)

      {:ok, %{"action" => "promote", "ids" => ids}} when is_list(ids) ->
        set_status(ids, "live", state)

      {:ok, %{"action" => "retire", "ids" => ids}} when is_list(ids) ->
        set_status(ids, "retired", state)

      {:ok, %{"action" => "stats"}} ->
        by_kind =
          Enum.reduce(state.fragments, %{}, fn f, acc ->
            Map.update(acc, "#{f.kind}/#{f.status}", 1, &(&1 + 1))
          end)

        {:reply, Jason.encode!(%{ok: true, fragments: by_kind, recipients: map_size(state.seen)}),
         state}

      _ ->
        {:reply, Jason.encode!(%{ok: false, error: "bad_request"}), state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── actions ────────────────────────────────────────────────────────────────

  defp add_fragments(frags, state) do
    built =
      for f <- frags,
          is_map(f),
          is_binary(f["kind"]),
          is_binary(f["text"]) do
        Core.fragment(f["kind"], f["text"],
          category: if(is_binary(f["category"]), do: f["category"]),
          weight:
            case f["weight"] do
              w when is_integer(w) and w >= 0 -> w
              _ -> 1
            end,
          source: if(is_binary(f["source"]), do: f["source"], else: "generated"),
          # ALWAYS pending — promotion is a separate, deliberate act
          status: "pending"
        )
      end

    existing = MapSet.new(state.fragments, & &1.id)
    new = built |> Enum.uniq_by(& &1.id) |> Enum.reject(&MapSet.member?(existing, &1.id))
    state = %{state | fragments: state.fragments ++ new}
    Enum.each(new, &store_call(state.store, :save_fragment, [&1]))

    {:reply, Jason.encode!(%{ok: true, count: length(new), ids: Enum.map(new, & &1.id)}), state}
  end

  # promote is pending->live ONLY; retire hits any status. Never deletes.
  defp set_status(ids, to, state) do
    idset = MapSet.new(Enum.filter(ids, &is_binary/1))

    {fragments, changed} =
      Enum.map_reduce(state.fragments, [], fn f, acc ->
        eligible = if to == "live", do: f.status == "pending", else: f.status != "retired"

        if MapSet.member?(idset, f.id) and eligible do
          {%{f | status: to}, [f.id | acc]}
        else
          {f, acc}
        end
      end)

    Enum.each(changed, &store_call(state.store, :save_fragment_status, [&1, to]))
    {:reply, Jason.encode!(%{ok: true, count: length(changed)}),
     %{state | fragments: fragments}}
  end

  # ── config + store seams (metrics idiom) ──────────────────────────────────

  defp normalize_template(nil), do: @default_template

  defp normalize_template(list) when is_list(list) do
    t =
      for e <- list, is_map(e), k = e[:kind] || e["kind"], is_binary(k) do
        %{kind: k, rotate: (e[:rotate] || e["rotate"]) == true}
      end

    if t == [], do: @default_template, else: t
  end

  defp normalize_template(_), do: @default_template

  defp normalize_guard(g) when is_integer(g) and g >= 0, do: g
  defp normalize_guard(_), do: @default_guard

  @doc """
  Dashboard extension (probed data contract — the host's dashboard source calls
  this via `function_exported?`, never a compile dep). Reads the durable
  fragment/seen tables from the injected store:
  `dashboard_extension(store: MyStore)`. Returns `%{"dashboard_pages" => [page]}`
  in the generic page schema, or `%{}` without a store.
  """
  def dashboard_extension(opts \\ []) do
    store = Keyword.get(opts, :store)

    if is_nil(store) do
      %{}
    else
      fragments = safe(fn -> load_fragments(store) end, [])
      seen = safe(fn -> load_seen(store) end, %{})
      by_kind = Enum.frequencies_by(fragments, &(&1[:kind] || &1["kind"] || "?"))
      seen_marks = seen |> Map.values() |> Enum.map(&length(List.wrap(&1))) |> Enum.sum()

      %{
        "dashboard_pages" => [
          %{
            "id" => "tips-pool",
            "label" => "Tips",
            "icon" => "hero-light-bulb",
            "meta" => "#{length(fragments)} fragment(s)",
            "sections" => [
              %{
                "type" => "metrics",
                "title" => "Pool",
                "items" =>
                  [
                    %{"label" => "Fragments", "value" => length(fragments)},
                    %{"label" => "Recipients", "value" => map_size(seen)},
                    %{"label" => "Seen marks", "value" => seen_marks}
                  ] ++
                    Enum.map(Enum.sort(by_kind), fn {kind, n} ->
                      %{"label" => to_string(kind), "value" => n}
                    end)
              }
            ]
          }
        ]
      }
    end
  end

  defp safe(fun, fallback) do
    fun.() || fallback
  rescue
    _ -> fallback
  end

  defp load_fragments(store) do
    if store?(store, :load_fragments, 0), do: store.load_fragments(), else: []
  end

  defp load_seen(store) do
    if store?(store, :load_seen, 0), do: store.load_seen(), else: %{}
  end

  defp store_call(store, fun, args) do
    if store?(store, fun, length(args)), do: apply(store, fun, args)
  end

  defp store?(store, fun, arity) do
    is_atom(store) and not is_nil(store) and Code.ensure_loaded?(store) and
      function_exported?(store, fun, arity)
  end

  # Module refs arrive as atoms (Elixir swarm defs) or strings (JSON IR).
  # Strings resolve via to_existing_atom — no atom minting; unknown -> nil.
  defp module_ref(nil), do: nil
  defp module_ref(mod) when is_atom(mod), do: mod

  defp module_ref(name) when is_binary(name) do
    String.to_existing_atom("Elixir." <> String.trim_leading(name, "Elixir."))
  rescue
    ArgumentError -> nil
  end

  defp module_ref(_), do: nil
end

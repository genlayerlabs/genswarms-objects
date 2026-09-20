defmodule Genswarms.GenLayer do
  @moduledoc "GenLayer wallet object. Routed sender selects custody; config contains secret paths, never keys."
  @schema File.read!(Path.join(__DIR__, "schema.json")) |> Jason.decode!()
  @runtime Path.join(__DIR__, "runtime.mjs")

  def interface,
    do:
      @schema["actions"]
      |> Map.put("result", %{
        "description" => "Fetch a completed object request by request_id; sender-scoped."
      })

  def init(config) do
    config = Map.new(config, fn {k, v} -> {to_string(k), v} end)

    with node when is_binary(node) <- System.find_executable("node"),
         true <- File.regular?(@runtime),
         agents when is_list(agents) <- config["agents"],
         true <- Enum.all?(agents, &is_binary/1) do
      port =
        Port.open({:spawn_executable, node}, [
          :binary,
          :exit_status,
          {:line, 65_536},
          args: [@runtime]
        ])

      Port.command(port, Jason.encode!(%{action: "init", config: config}) <> "\n")

      {:ok,
       %{
         port: port,
         ready: false,
         agents: MapSet.new(agents),
         pending: %{},
         results: %{},
         order: []
       }}
    else
      _ -> {:error, :invalid_genlayer_config_or_runtime}
    end
  end

  def handle_message(from, content, state) do
    sender = to_string(from)

    with true <- MapSet.member?(state.agents, sender),
         true <- is_binary(content) and byte_size(content) <= 16_384,
         {:ok, message} when is_map(message) <- Jason.decode(content) do
      cond do
        message["action"] == "result" ->
          response =
            case state.results[message["request_id"]] do
              {^sender, result} -> result
              _ -> %{ok: false, error: %{code: "unknown_or_pending_request"}}
            end

          {:reply, Jason.encode!(response), state}

        not state.ready ->
          reply_error("runtime_unavailable", state)

        map_size(state.pending) >= 64 ->
          reply_error("object_busy", state)

        true ->
          id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

          Port.command(
            state.port,
            Jason.encode!(%{id: id, sender: sender, message: message}) <> "\n"
          )

          Process.send_after(self(), {:genlayer_timeout, id}, 60_000)

          {:reply, Jason.encode!(%{ok: true, status: "accepted", request_id: id}),
           %{state | pending: Map.put(state.pending, id, from)}}
      end
    else
      _ -> reply_error("invalid_request_or_sender", state)
    end
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"ready" => true}} -> {:noreply, %{state | ready: true}}
      {:ok, %{"id" => id} = result} -> complete(id, result, state)
      _ -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) do
    # Do not recreate runtime automatically while transaction outcomes are unknown.
    messages =
      Enum.map(state.pending, fn {id, from} ->
        {:send, from,
         Jason.encode!(%{
           request_id: id,
           ok: false,
           error: %{
             code: "runtime_lost",
             guidance: "Query durable transaction status after object restart."
           }
         })}
      end)

    {:multi, messages, %{state | ready: false, pending: %{}}}
  end

  def handle_info({:genlayer_timeout, id}, state),
    do:
      complete(
        id,
        %{
          "id" => id,
          "ok" => false,
          "error" => %{
            "code" => "request_timeout",
            "guidance" => "Outcome unknown; query execution status, do not duplicate submission."
          }
        },
        state
      )

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp complete(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        order = Enum.take([id | state.order], 256)
        results = state.results |> Map.put(id, {to_string(from), result}) |> Map.take(order)

        {:send, from, Jason.encode!(result),
         %{state | pending: pending, results: results, order: order}}
    end
  end

  defp reply_error(code, state),
    do: {:reply, Jason.encode!(%{ok: false, error: %{code: code}}), state}
end

defmodule S2.SSE do
  defstruct event: nil, data: nil, id: nil

  def stream(%S2.Client{} = client, basin, stream_name, opts \\ []) do
    params =
      opts
      |> Keyword.take([:seq_num, :timestamp])
      |> Enum.into(%{})

    url = "#{client.config.base_url}/v1/streams/#{stream_name}/records"

    headers =
      %{
        "accept" => "text/event-stream",
        "s2-basin" => basin
      }
      |> maybe_put_auth(client.config)

    # Use an ETS table as a message relay so any process can consume events
    table = :ets.new(:sse_events, [:ordered_set, :public])
    ref = make_ref()
    caller = self()

    _pid =
      spawn_link(fn ->
        resp =
          Req.get!(url,
            headers: headers,
            params: params,
            into: :self,
            receive_timeout: :infinity
          )

        case resp.status do
          200 ->
            send(caller, {ref, :connected})
            sse_loop(table, resp, "", 0)

          _other ->
            send(caller, {ref, :connected})
            body = collect_body(resp)

            parsed =
              case Jason.decode(body) do
                {:ok, map} -> map
                _ -> body
              end

            push_event(table, %__MODULE__{event: "error", data: Jason.encode!(parsed)}, 0)
            push_event(table, :done, 1)
        end
      end)

    receive do
      {^ref, :connected} ->
        event_stream =
          Stream.resource(
            fn -> {table, 0} end,
            fn {table, idx} ->
              poll_event(table, idx, 100, 300)
            end,
            fn {table, _idx} ->
              :ets.delete(table)
            end
          )

        {:ok, event_stream}
    after
      10_000 ->
        {:error, :timeout}
    end
  end

  defp push_event(table, event, idx) do
    :ets.insert(table, {idx, event})
  end

  defp poll_event(table, idx, delay_ms, retries) when retries > 0 do
    case :ets.lookup(table, idx) do
      [{^idx, :done}] ->
        {:halt, {table, idx}}

      [{^idx, event}] ->
        {[event], {table, idx + 1}}

      [] ->
        Process.sleep(delay_ms)
        poll_event(table, idx, delay_ms, retries - 1)
    end
  end

  defp poll_event(table, idx, _delay_ms, 0) do
    {:halt, {table, idx}}
  end

  defp sse_loop(table, resp, buffer, idx) do
    receive do
      {_ref, {:data, chunk}} ->
        buffer = buffer <> chunk
        {events, remaining} = parse_events(buffer)

        idx =
          Enum.reduce(events, idx, fn event, i ->
            push_event(table, event, i)
            i + 1
          end)

        sse_loop(table, resp, remaining, idx)

      {_ref, :done} ->
        {events, _} = parse_events(buffer)

        idx =
          Enum.reduce(events, idx, fn event, i ->
            push_event(table, event, i)
            i + 1
          end)

        push_event(table, :done, idx)

      {_ref, {:error, _reason}} ->
        push_event(table, :done, idx)
    end
  end

  defp parse_events(buffer) do
    case String.split(buffer, "\n\n", parts: :infinity) do
      [incomplete] ->
        {[], incomplete}

      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)

        events =
          complete
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&parse_event/1)

        {events, remaining}
    end
  end

  defp parse_event(raw) do
    lines = String.split(raw, "\n")

    Enum.reduce(lines, %__MODULE__{}, fn line, acc ->
      cond do
        String.starts_with?(line, "event: ") ->
          %{acc | event: String.trim_leading(line, "event: ")}

        String.starts_with?(line, "data: ") ->
          %{acc | data: String.trim_leading(line, "data: ")}

        String.starts_with?(line, "id: ") ->
          %{acc | id: String.trim_leading(line, "id: ")}

        true ->
          acc
      end
    end)
  end

  defp collect_body(resp) do
    collect_body_loop(resp, "")
  end

  defp collect_body_loop(_resp, acc) do
    receive do
      {_ref, {:data, chunk}} ->
        collect_body_loop(nil, acc <> chunk)

      {_ref, :done} ->
        acc
    after
      5_000 ->
        acc
    end
  end

  defp maybe_put_auth(headers, %S2.Config{token: nil}), do: headers

  defp maybe_put_auth(headers, %S2.Config{token: token}) do
    Map.put(headers, "authorization", "Bearer #{token}")
  end
end

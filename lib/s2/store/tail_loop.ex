defmodule S2.Store.TailLoop do
  @moduledoc false

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.Connector

  @doc false
  def run(session, serializer, callback, config \\ nil, reader \\ Serialization.reader()) do
    connector =
      if config do
        Connector.new(base_delay: config.base_delay, max_retries: config.max_retries)
        |> Connector.connected()
      end

    do_loop(session, serializer, callback, config, reader, connector, 0)
  end

  defp do_loop(session, serializer, callback, config, reader, connector, seq_num) do
    case S2.S2S.ReadSession.next_batch(session) do
      {:ok, batch, session} ->
        {results, reader} = Serialization.decode(reader, batch.records, serializer)

        Enum.each(results, fn
          {:error, reason} ->
            Logger.warning("S2 decode error: #{inspect(reason)}")
            :telemetry.execute([:s2, :store, :decode_error], %{count: 1}, %{reason: reason})

          message ->
            callback.(message)
        end)

        next_seq = next_seq_num(batch.records, seq_num)
        # Reset connector on successful batch (connection is healthy)
        connector = if connector, do: Connector.connected(connector), else: nil
        do_loop(session, serializer, callback, config, reader, connector, next_seq)

      {:error, :end_of_stream, _session} ->
        :ok

      {:error, _reason, _session} when connector != nil ->
        case reconnect_with_backoff(config, connector, seq_num) do
          {:ok, session, connector} ->
            do_loop(session, serializer, callback, config, reader, connector, seq_num)

          {:error, reason} ->
            Logger.error(
              "S2 listener giving up after max retries stream=#{config.stream} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, _reason, _session} ->
        :ok
    end
  end

  defp reconnect_with_backoff(config, connector, seq_num) do
    case Connector.begin_reconnect(connector) do
      {:error, :max_retries_exceeded} ->
        {:error, :max_retries_exceeded}

      {:retry, delay, connector} ->
        Process.sleep(delay)
        metadata = %{stream: config.stream, component: :listener, attempt: connector.attempt}

        result =
          :telemetry.span([:s2, :store, :reconnect], metadata, fn ->
            case reconnect(config, seq_num) do
              {:ok, session} -> {{:ok, session}, metadata}
              {:error, reason} -> {{:error, reason}, Map.put(metadata, :error, :connect_failed)}
            end
          end)

        case result do
          {:ok, session} ->
            {:ok, session, Connector.connected(connector)}

          {:error, _reason} ->
            reconnect_with_backoff(config, connector, seq_num)
        end
    end
  end

  defp reconnect(config, seq_num) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <-
           S2.S2S.ReadSession.open(conn, config.basin, config.stream,
             seq_num: seq_num,
             token: config.token,
             recv_timeout: config.recv_timeout
           ) do
      {:ok, session}
    else
      {:error, reason, _conn} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_seq_num([], seq_num), do: seq_num

  defp next_seq_num(records, _seq_num) do
    last = List.last(records)
    last.seq_num + 1
  end
end

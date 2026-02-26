defmodule S2.Store.TailLoop do
  @moduledoc false

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.Connector

  @doc "Build a TailLoop config map from a store config and stream name."
  @spec build_config(map(), String.t()) :: map()
  def build_config(store_config, stream) do
    store_config
    |> Map.take([:base_url, :token, :basin, :max_retries, :base_delay, :recv_timeout])
    |> Map.put(:stream, stream)
  end

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
            try do
              callback.(message)
            rescue
              e ->
                Logger.error("S2 listener callback crashed: #{Exception.message(e)}")

                :telemetry.execute([:s2, :store, :callback_error], %{count: 1}, %{
                  exception: e,
                  stacktrace: __STACKTRACE__
                })
            end
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

      {:error, reason, _session} ->
        Logger.warning("S2 listener stopped due to error: #{inspect(reason)}")
        {:error, reason}
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
    S2.S2S.Shared.open_session(config.base_url, [token: config.token], fn conn ->
      S2.S2S.ReadSession.open(conn, config.basin, config.stream,
        seq_num: seq_num,
        token: config.token,
        recv_timeout: config.recv_timeout
      )
    end)
  end

  @doc false
  def next_seq_num([], seq_num), do: seq_num

  def next_seq_num(records, _seq_num) do
    last = List.last(records)
    last.seq_num + 1
  end
end

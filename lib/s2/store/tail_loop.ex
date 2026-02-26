defmodule S2.Store.TailLoop do
  @moduledoc false

  require Logger

  alias S2.Patterns.Serialization

  @max_backoff 30_000

  @doc false
  def run(session, serializer, callback, config \\ nil, reader \\ Serialization.reader()) do
    do_loop(session, serializer, callback, config, reader, 0)
  end

  defp do_loop(session, serializer, callback, config, reader, seq_num) do
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
        do_loop(session, serializer, callback, config, reader, next_seq)

      {:error, :end_of_stream, _session} ->
        :ok

      {:error, _reason, _session} when config != nil ->
        case reconnect_with_backoff(config, seq_num, 1) do
          {:ok, session} ->
            do_loop(session, serializer, callback, config, reader, seq_num)

          {:error, _reason} ->
            :ok
        end

      {:error, _reason, _session} ->
        :ok
    end
  end

  defp reconnect_with_backoff(config, seq_num, attempt) do
    max = config.max_retries

    if max != :infinity and attempt > max do
      {:error, :max_retries_exceeded}
    else
      metadata = %{stream: config.stream, component: :listener, attempt: attempt}

      result =
        :telemetry.span([:s2, :store, :reconnect], metadata, fn ->
          case reconnect(config, seq_num) do
            {:ok, session} -> {{:ok, session}, metadata}
            {:error, reason} -> {{:error, reason}, Map.put(metadata, :error, :connect_failed)}
          end
        end)

      case result do
        {:ok, session} ->
          {:ok, session}

        {:error, _reason} ->
          backoff(config.base_delay, attempt)
          reconnect_with_backoff(config, seq_num, attempt + 1)
      end
    end
  end

  defp reconnect(config, seq_num) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.ReadSession.open(conn, config.basin, config.stream,
           seq_num: seq_num, token: config.token, recv_timeout: config.recv_timeout) do
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

  defp backoff(base_delay, attempt) do
    delay = min(base_delay * Integer.pow(2, attempt - 1), @max_backoff)
    jitter = :rand.uniform(max(div(delay, 2), 1))
    Process.sleep(delay + jitter)
  end
end

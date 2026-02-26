defmodule S2.Store.StreamWorker do
  @moduledoc false
  use GenServer

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.Telemetry

  def start_link({config, stream}) do
    name = S2.Store.Supervisor.stream_worker_name(config.store, stream)
    GenServer.start_link(__MODULE__, {config, stream}, name: name)
  end

  def append(store, stream, message, serializer) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append, message, serializer})
  end

  @impl true
  def init({config, stream}) do
    {:ok, conn} = S2.S2S.Connection.open(config.base_url, token: config.token)
    {:ok, session} = S2.S2S.AppendSession.open(conn, config.basin, stream, token: config.token)

    {:ok, %{
      config: config,
      stream: stream,
      session: session,
      writer: Serialization.writer()
    }}
  end

  @impl true
  def terminate(_reason, state) do
    S2.S2S.AppendSession.close(state.session)
    :ok
  end

  @impl true
  def handle_call({:append, message, serializer}, _from, state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len > state.config.max_queue_size do
      {:reply, {:error, :overloaded}, state}
    else
      do_append(message, serializer, state)
    end
  end

  defp do_append(message, serializer, state) do
    metadata = %{stream: state.stream}

    case safe_prepare(state.writer, message, serializer) do
      {:error, reason} ->
        {:reply, {:error, {:serialization_error, reason}}, state}

      {:ok, input, writer} ->
        Telemetry.event([:s2, :store, :append, :start], %{system_time: System.system_time()}, metadata)
        start_time = System.monotonic_time()

        case append_with_reconnect(state, input) do
          {:ok, ack, session} ->
            duration = System.monotonic_time() - start_time
            Telemetry.event([:s2, :store, :append, :stop], %{duration: duration}, metadata)
            {:reply, {:ok, ack}, %{state | session: session, writer: writer}}

          {:error, reason, session} ->
            duration = System.monotonic_time() - start_time
            Telemetry.event([:s2, :store, :append, :exception], %{duration: duration}, Map.put(metadata, :reason, reason))
            {:reply, {:error, reason}, %{state | session: session, writer: writer}}
        end
    end
  end

  defp safe_prepare(writer, message, serializer) do
    {input, writer} = Serialization.prepare(writer, message, serializer)
    {:ok, input, writer}
  rescue
    e -> {:error, e}
  end

  defp append_with_reconnect(state, input) do
    case S2.S2S.AppendSession.append(state.session, input) do
      {:ok, _ack, _session} = ok ->
        ok

      {:error, _reason, _session} ->
        reconnect_and_retry(state, input, 1)
    end
  end

  defp reconnect_and_retry(state, input, attempt) do
    max = state.config.max_retries

    if max != :infinity and attempt > max do
      {:error, :max_retries_exceeded, state.session}
    else
      metadata = %{stream: state.stream, component: :writer, attempt: attempt}
      Telemetry.event([:s2, :store, :reconnect, :start], %{system_time: System.system_time()}, metadata)
      start_time = System.monotonic_time()

      # Best-effort close of old session before reconnecting
      S2.S2S.AppendSession.close(state.session)

      case reconnect(state.config, state.stream) do
        {:ok, session} ->
          duration = System.monotonic_time() - start_time
          Telemetry.event([:s2, :store, :reconnect, :stop], %{duration: duration}, metadata)

          case S2.S2S.AppendSession.append(session, input) do
            {:ok, _ack, _session} = ok -> ok
            {:error, _reason, _session} ->
              backoff(state.config.base_delay, attempt)
              reconnect_and_retry(%{state | session: session}, input, attempt + 1)
          end

        {:error, _reason} ->
          duration = System.monotonic_time() - start_time
          Telemetry.event([:s2, :store, :reconnect, :exception], %{duration: duration}, Map.put(metadata, :reason, :connect_failed))
          backoff(state.config.base_delay, attempt)
          reconnect_and_retry(state, input, attempt + 1)
      end
    end
  end

  defp reconnect(config, stream) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.AppendSession.open(conn, config.basin, stream, token: config.token) do
      {:ok, session}
    end
  end

  def tail_loop(session, serializer, callback, config \\ nil, reader \\ Serialization.reader()) do
    do_tail_loop(session, serializer, callback, config, reader, 0)
  end

  defp do_tail_loop(session, serializer, callback, config, reader, seq_num) do
    case S2.S2S.ReadSession.next_batch(session) do
      {:ok, batch, session} ->
        {messages, reader} = Serialization.decode(reader, batch.records, serializer)
        Enum.each(messages, callback)
        next_seq = next_seq_num(batch.records, seq_num)
        do_tail_loop(session, serializer, callback, config, reader, next_seq)

      {:error, :end_of_stream, _session} ->
        :ok

      {:error, _reason, _session} when config != nil ->
        case reconnect_reader_with_backoff(config, seq_num, 1) do
          {:ok, session} ->
            do_tail_loop(session, serializer, callback, config, reader, seq_num)

          {:error, _reason} ->
            :ok
        end

      {:error, _reason, _session} ->
        :ok
    end
  end

  defp reconnect_reader_with_backoff(config, seq_num, attempt) do
    max = config.max_retries

    if max != :infinity and attempt > max do
      {:error, :max_retries_exceeded}
    else
      metadata = %{stream: config.stream, component: :listener, attempt: attempt}
      Telemetry.event([:s2, :store, :reconnect, :start], %{system_time: System.system_time()}, metadata)
      start_time = System.monotonic_time()

      case reconnect_reader(config, seq_num) do
        {:ok, session} ->
          duration = System.monotonic_time() - start_time
          Telemetry.event([:s2, :store, :reconnect, :stop], %{duration: duration}, metadata)
          {:ok, session}

        {:error, _reason} ->
          duration = System.monotonic_time() - start_time
          Telemetry.event([:s2, :store, :reconnect, :exception], %{duration: duration}, Map.put(metadata, :reason, :connect_failed))
          backoff(config.base_delay, attempt)
          reconnect_reader_with_backoff(config, seq_num, attempt + 1)
      end
    end
  end

  defp reconnect_reader(config, seq_num) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.ReadSession.open(conn, config.basin, config.stream, seq_num: seq_num, token: config.token) do
      {:ok, session}
    end
  end

  defp next_seq_num([], seq_num), do: seq_num

  defp next_seq_num(records, _seq_num) do
    last = List.last(records)
    last.seq_num + 1
  end

  defp backoff(base_delay, attempt) do
    delay = min(base_delay * Integer.pow(2, attempt - 1), 300_000)
    jitter = :rand.uniform(max(div(delay, 2), 1))
    Process.sleep(delay + jitter)
  end
end

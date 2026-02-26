defmodule S2.Store.StreamWorker do
  @moduledoc false
  use GenServer

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.Telemetry

  @max_backoff 30_000

  def start_link({config, stream}) do
    name = S2.Store.Supervisor.stream_worker_name(config.store, stream)
    GenServer.start_link(__MODULE__, {config, stream}, name: name)
  end

  def append(store, stream, message, serializer) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append, message, serializer})
  end

  def append_batch(store, stream, messages, serializer) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append_batch, messages, serializer})
  end

  @impl true
  def init({config, stream}) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.AppendSession.open(conn, config.basin, stream, token: config.token, recv_timeout: config.recv_timeout, compression: config.compression) do
      {:ok, %{
        config: config,
        stream: stream,
        session: session,
        writer: Serialization.writer()
      }}
    else
      {:error, reason, _conn} -> {:stop, {:connect_failed, reason}}
      {:error, reason} -> {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    S2.S2S.AppendSession.close(state.session)
    :ok
  end

  @impl true
  def handle_call({:append, message, serializer}, _from, state) do
    with :ok <- check_backpressure(state) do
      case safe_prepare(state.writer, message, serializer) do
        {:error, reason} ->
          {:reply, {:error, {:serialization_error, reason}}, state}

        {:ok, input, writer} ->
          run_append(state, input, writer, %{stream: state.stream})
      end
    end
  end

  def handle_call({:append_batch, messages, serializer}, _from, state) do
    with :ok <- check_backpressure(state) do
      case safe_prepare_batch(state.writer, messages, serializer) do
        {:error, reason} ->
          {:reply, {:error, {:serialization_error, reason}}, state}

        {:ok, input, writer} ->
          run_append(state, input, writer, %{stream: state.stream, count: length(messages)})
      end
    end
  end

  # Shared append execution: serialize -> telemetry span -> append with reconnect
  defp run_append(state, input, writer, metadata) do
    result =
      Telemetry.span([:s2, :store, :append], metadata, fn ->
        case append_with_reconnect(state, input) do
          {:ok, _ack, _session} = ok -> {ok, metadata}
          {:error, reason, _session} = err -> {err, Map.put(metadata, :error, reason)}
        end
      end)

    case result do
      {:ok, ack, session} ->
        {:reply, {:ok, ack}, %{state | session: session, writer: writer}}

      {:error, reason, session} ->
        {:reply, {:error, reason}, %{state | session: session, writer: writer}}
    end
  end

  defp check_backpressure(state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len > state.config.max_queue_size do
      {:reply, {:error, :overloaded}, state}
    else
      :ok
    end
  end

  defp safe_prepare_batch(writer, messages, serializer) do
    {all_records, writer} =
      Enum.flat_map_reduce(messages, writer, fn msg, w ->
        {input, w} = Serialization.prepare(w, msg, serializer)
        {input.records, w}
      end)

    {:ok, %S2.V1.AppendInput{records: all_records}, writer}
  rescue
    e -> {:error, e}
  end

  defp safe_prepare(writer, message, serializer) do
    {input, writer} = Serialization.prepare(writer, message, serializer)
    {:ok, input, writer}
  rescue
    e -> {:error, e}
  end

  defp append_with_reconnect(state, input) do
    case S2.S2S.AppendSession.append(state.session, input) do
      {:ok, _ack, _session} = ok -> ok
      {:error, _reason, _session} -> reconnect_and_retry(state, input, 1)
    end
  end

  defp reconnect_and_retry(state, input, attempt) do
    max = state.config.max_retries

    if max != :infinity and attempt > max do
      {:error, :max_retries_exceeded, state.session}
    else
      metadata = %{stream: state.stream, component: :writer, attempt: attempt}

      # Best-effort close of old session before reconnecting
      S2.S2S.AppendSession.close(state.session)

      result =
        Telemetry.span([:s2, :store, :reconnect], metadata, fn ->
          case reconnect(state.config, state.stream) do
            {:ok, session} -> {{:ok, session}, metadata}
            {:error, reason} -> {{:error, reason}, Map.put(metadata, :error, :connect_failed)}
          end
        end)

      case result do
        {:ok, session} ->
          case S2.S2S.AppendSession.append(session, input) do
            {:ok, _ack, _session} = ok -> ok
            {:error, _reason, _session} ->
              backoff(state.config.base_delay, attempt)
              reconnect_and_retry(%{state | session: session}, input, attempt + 1)
          end

        {:error, _reason} ->
          backoff(state.config.base_delay, attempt)
          reconnect_and_retry(state, input, attempt + 1)
      end
    end
  end

  defp reconnect(config, stream) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.AppendSession.open(conn, config.basin, stream,
           token: config.token, recv_timeout: config.recv_timeout, compression: config.compression) do
      {:ok, session}
    else
      {:error, reason, _conn} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp backoff(base_delay, attempt) do
    delay = min(base_delay * Integer.pow(2, attempt - 1), @max_backoff)
    jitter = :rand.uniform(max(div(delay, 2), 1))
    Process.sleep(delay + jitter)
  end
end

defmodule S2.Store.StreamWorker do
  @moduledoc false
  use GenServer

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.{Connector, Telemetry}

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

  # --- Callbacks ---

  @impl true
  def init({config, stream}) do
    connector = Connector.new(base_delay: config.base_delay, max_retries: config.max_retries)

    case open_session(config, stream) do
      {:ok, session} ->
        {:ok, %{
          config: config,
          stream: stream,
          session: session,
          writer: Serialization.writer(),
          connector: Connector.connected(connector)
        }}

      {:error, reason} ->
        {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{session: nil}), do: :ok

  def terminate(_reason, state) do
    S2.S2S.AppendSession.close(state.session)
    :ok
  end

  @impl true
  def handle_call(_msg, _from, %{connector: %{status: status}} = state)
      when status in [:reconnecting, :failed] do
    {:reply, {:error, :reconnecting}, state}
  end

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

  @impl true
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

  @impl true
  def handle_info({:reconnected, session}, state) do
    Logger.debug("S2 StreamWorker reconnected stream=#{state.stream}")
    {:noreply, %{state | session: session, connector: Connector.connected(state.connector)}}
  end

  def handle_info({:reconnect_failed, _reason}, state) do
    schedule_reconnect(state)
  end

  def handle_info(:reconnect, state) do
    spawn_reconnect_task(state)
    {:noreply, state}
  end

  # --- Private ---

  # Shared append execution: serialize -> telemetry span -> append or trigger reconnect
  defp run_append(state, input, writer, metadata) do
    result =
      Telemetry.span([:s2, :store, :append], metadata, fn ->
        case S2.S2S.AppendSession.append(state.session, input) do
          {:ok, _ack, _session} = ok -> {ok, metadata}
          {:error, reason, _session} = err -> {err, Map.put(metadata, :error, reason)}
        end
      end)

    case result do
      {:ok, ack, session} ->
        {:reply, {:ok, ack}, %{state | session: session, writer: writer}}

      {:error, reason, _session} ->
        # Append failed — trigger async reconnect and return error immediately
        state = %{state | writer: writer}
        {_, new_state} = begin_reconnect(state)
        {:reply, {:error, reason}, new_state}
    end
  end

  defp begin_reconnect(state) do
    # Best-effort close of old session
    if state.session, do: S2.S2S.AppendSession.close(state.session)

    case Connector.begin_reconnect(state.connector) do
      {:retry, delay, connector} ->
        Process.send_after(self(), :reconnect, delay)
        {:reconnecting, %{state | session: nil, connector: connector}}

      {:error, :max_retries_exceeded} ->
        Logger.error("S2 StreamWorker max retries exceeded stream=#{state.stream}")
        connector = %{state.connector | status: :failed}
        {:failed, %{state | session: nil, connector: connector}}
    end
  end

  defp schedule_reconnect(state) do
    case begin_reconnect(state) do
      {:reconnecting, state} -> {:noreply, state}
      {:failed, state} -> {:noreply, state}
    end
  end

  # Spawn a Task that opens a new connection + session in its own process,
  # then transfers the Mint connection to this GenServer. This avoids
  # Mint's receive-based protocol stealing GenServer messages from our mailbox.
  defp spawn_reconnect_task(state) do
    parent = self()
    config = state.config
    stream = state.stream

    metadata = %{stream: stream, component: :writer, attempt: state.connector.attempt}

    Task.start(fn ->
      result =
        Telemetry.span([:s2, :store, :reconnect], metadata, fn ->
          case open_session(config, stream) do
            {:ok, session} ->
              case Mint.HTTP2.controlling_process(session.conn, parent) do
                {:ok, new_conn} ->
                  session = %{session | conn: new_conn, owner_pid: parent}
                  {{:ok, session}, metadata}

                {:error, reason} ->
                  {{:error, reason}, Map.put(metadata, :error, :transfer_failed)}
              end

            {:error, reason} ->
              {{:error, reason}, Map.put(metadata, :error, :connect_failed)}
          end
        end)

      case result do
        {:ok, session} -> send(parent, {:reconnected, session})
        {:error, reason} -> send(parent, {:reconnect_failed, reason})
      end
    end)
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

  defp open_session(config, stream) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.AppendSession.open(conn, config.basin, stream,
           token: config.token, recv_timeout: config.recv_timeout, compression: config.compression) do
      {:ok, session}
    else
      {:error, reason, _conn} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end

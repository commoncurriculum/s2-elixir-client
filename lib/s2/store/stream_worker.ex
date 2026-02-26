defmodule S2.Store.StreamWorker do
  @moduledoc false
  use GenServer

  require Logger

  alias S2.Patterns.Serialization
  alias S2.Store.Connector

  def start_link({config, stream}) do
    name = S2.Store.Supervisor.stream_worker_name(config.store, stream)
    GenServer.start_link(__MODULE__, {config, stream}, name: name)
  end

  def append(store, stream, message, serializer, call_timeout \\ 5_000) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append, message, serializer}, call_timeout)
  end

  def append_batch(store, stream, messages, serializer, call_timeout \\ 5_000) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append_batch, messages, serializer}, call_timeout)
  end

  # --- Callbacks ---

  @impl true
  def init({config, stream}) do
    connector = Connector.new(base_delay: config.base_delay, max_retries: config.max_retries)

    case open_session(config, stream) do
      {:ok, session} ->
        {:ok,
         %{
           config: config,
           stream: stream,
           session: session,
           writer: Serialization.writer(),
           connector: Connector.connected(connector),
           reconnect_ref: nil
         }}

      {:error, reason} ->
        {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{session: nil}), do: :ok

  def terminate(_reason, %{session: %S2.S2S.AppendSession{}} = state) do
    S2.S2S.AppendSession.close(state.session)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_call(_msg, _from, %{connector: %{status: :reconnecting}} = state) do
    {:reply, {:error, :reconnecting}, state}
  end

  def handle_call(_msg, _from, %{connector: %{status: :failed}} = state) do
    {:reply, {:error, :connection_failed}, state}
  end

  def handle_call({:append, message, serializer}, _from, state) do
    do_append(state, fn -> safe_prepare(state.writer, message, serializer) end, %{
      stream: state.stream
    })
  end

  @impl true
  def handle_call({:append_batch, messages, serializer}, _from, state) do
    do_append(state, fn -> safe_prepare_batch(state.writer, messages, serializer) end, %{
      stream: state.stream,
      count: length(messages)
    })
  end

  @impl true
  def handle_info({:reconnected, session}, state) do
    Logger.debug("S2 StreamWorker reconnected stream=#{state.stream}")

    {:noreply,
     %{
       state
       | session: session,
         reconnect_ref: nil,
         connector: Connector.connected(state.connector)
     }}
  end

  def handle_info({:reconnect_failed, _reason}, state) do
    schedule_reconnect(%{state | reconnect_ref: nil})
  end

  def handle_info(:reconnect, state) do
    ref = spawn_reconnect_task(state)
    {:noreply, %{state | reconnect_ref: ref}}
  end

  # Reconnect task crashed without sending a message — treat as failed reconnect
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reconnect_ref: ref} = state) do
    schedule_reconnect(%{state | reconnect_ref: nil})
  end

  # Discard stale Mint TCP messages from previous connections
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp do_append(state, prepare_fn, metadata) do
    case check_backpressure(state) do
      {:error, :overloaded} ->
        {:reply, {:error, :overloaded}, state}

      :ok ->
        case prepare_fn.() do
          {:error, reason} ->
            {:reply, {:error, {:serialization_error, reason}}, state}

          {:ok, input, writer} ->
            run_append(state, input, writer, metadata)
        end
    end
  end

  # Serialize -> telemetry span -> append or trigger reconnect
  defp run_append(state, input, writer, metadata) do
    result =
      :telemetry.span([:s2, :store, :append], metadata, fn ->
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

    {:ok, pid} =
      Task.start(fn ->
        result =
          :telemetry.span([:s2, :store, :reconnect], metadata, fn ->
            case open_session(config, stream) do
              {:ok, session} ->
                case Mint.HTTP2.controlling_process(session.conn, parent) do
                  {:ok, new_conn} ->
                    session = %{session | conn: new_conn, owner_pid: parent}
                    {{:ok, session}, metadata}

                  {:error, reason} ->
                    # Close the session to avoid leaking the connection
                    S2.S2S.AppendSession.close(session)
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

    Process.monitor(pid)
  end

  @doc false
  def check_backpressure(state) do
    {:message_queue_len, queue_len} = Process.info(self(), :message_queue_len)

    if queue_len > state.config.max_queue_size do
      {:error, :overloaded}
    else
      :ok
    end
  end

  @doc false
  def safe_prepare_batch(writer, messages, serializer) do
    {all_records, writer} =
      Enum.flat_map_reduce(messages, writer, fn msg, w ->
        {input, w} = Serialization.prepare(w, msg, serializer)
        {input.records, w}
      end)

    {:ok, %S2.V1.AppendInput{records: all_records}, writer}
  rescue
    e -> {:error, e}
  end

  @doc false
  def safe_prepare(writer, message, serializer) do
    {input, writer} = Serialization.prepare(writer, message, serializer)
    {:ok, input, writer}
  rescue
    e -> {:error, e}
  end

  defp open_session(config, stream) do
    S2.S2S.Shared.open_session(config.base_url, [token: config.token], fn conn ->
      S2.S2S.AppendSession.open(conn, config.basin, stream,
        token: config.token,
        recv_timeout: config.recv_timeout,
        compression: config.compression
      )
    end)
  end
end

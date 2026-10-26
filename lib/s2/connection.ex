defmodule S2.Connection do
  @moduledoc """
  One HTTP/2 connection to a basin, and every stream's appends and reads on
  it. Callers never touch the socket: they call this process, and it handles
  the socket's messages in `handle_info/2`, the way Finch does.

  Appends: each stream's calls queue in an `S2.AppendStream` and go out on
  that stream's append session, batched and pipelined. A session that fails,
  or that S2 asks to drain, ends; its unacknowledged batches are sent again,
  byte for byte, on the next one. A caller only sees an error when its own
  timeout passes or S2 refuses its records for good. A session with nothing
  to send for `idle_after` milliseconds is closed.

  Reads: a listener's read session sends its records to the listener as
  messages. One that ends, or that S2 asks to reconnect, is opened again
  from the next sequence number.

  Any frame, heartbeats included, shows a session is alive. A read session
  silent for `heartbeat_deadline` milliseconds, or an append unacknowledged
  that long, drops the connection. When the connection drops, everything
  waits for the next one, which is tried with backoff from 100 ms to 5 s.
  """

  use GenServer

  require Logger

  alias S2.{AppendStream, Framing}

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: config.connection)

  @impl true
  def init(config) do
    endpoint = String.replace(config.basin_endpoint, "{basin}", config.basin)
    uri = URI.parse(endpoint)

    headers =
      if(String.contains?(config.basin_endpoint, "{basin}"),
        do: [],
        else: [{"s2-basin", config.basin}]
      ) ++
        if(config.token, do: [{"authorization", "Bearer #{config.token}"}], else: [])

    state = %{
      config: config,
      uri: uri,
      headers: headers,
      conn: nil,
      delay: 100,
      # stream => %{queue:, request:, buffer:, outgoing:, draining:, status:, seen_at:, delay:}
      appends: %{},
      # Streams with work and no session, waiting for a request to end.
      waiting: MapSet.new(),
      # listener (its pid's monitor) => %{pid:, stream:, from:, request:, buffer:, status:, seen_at:, delay:}
      listeners: %{},
      # request => {:append, stream} | {:listen, listener} | {:read | :tail, from}
      requests: %{},
      # request => %{status:, data:} for :read and :tail
      replies: %{}
    }

    Process.send_after(self(), :check, div(config.heartbeat_deadline, 2))
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    scheme = if state.uri.scheme == "https", do: :https, else: :http
    port = state.uri.port || if(scheme == :https, do: 443, else: 80)

    case Mint.HTTP2.connect(scheme, state.uri.host, port,
           mode: :active,
           transport_opts: [timeout: state.config.connect_timeout] ++ state.config.transport_opts
         ) do
      {:ok, conn} ->
        state = %{state | conn: conn, delay: 100}
        state = Enum.reduce(Map.keys(state.listeners), state, &open_read(&2, &1))
        {:noreply, Enum.reduce(Map.keys(state.appends), state, &send_appends(&2, &1))}

      {:error, error} ->
        Logger.warning(
          "connecting to S2 failed, retrying in #{state.delay} ms: #{inspect(error)}"
        )

        Process.send_after(self(), :connect, state.delay)
        {:noreply, %{state | delay: min(state.delay * 2, 5_000)}}
    end
  end

  @impl true
  def handle_call({:append, stream, records, deadline}, from, state) do
    entry =
      Map.get(state.appends, stream, %{
        queue: AppendStream.new(),
        request: nil,
        buffer: "",
        outgoing: "",
        draining: false,
        status: nil,
        seen_at: now(),
        delay: 100
      })

    case AppendStream.push(entry.queue, from, records, deadline) do
      {:ok, queue} ->
        state = put_in(state.appends[stream], %{entry | queue: queue})
        {:noreply, send_appends(state, stream)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read, stream, query}, from, state),
    do: request(state, from, :read, records_path(stream) <> query)

  def handle_call({:check_tail, stream}, from, state),
    do: request(state, from, :tail, records_path(stream) <> "/tail")

  def handle_call({:listen, stream, pid, from_position}, _from, state) do
    listener = Process.monitor(pid)

    entry = %{
      pid: pid,
      stream: stream,
      from: from_position,
      request: nil,
      buffer: "",
      status: nil,
      seen_at: now(),
      delay: 100
    }

    {:reply, {:ok, listener}, open_read(put_in(state.listeners[listener], entry), listener)}
  end

  def handle_call({:stop_listener, listener}, _from, state) do
    case state.listeners[listener] do
      nil ->
        {:reply, {:error, :not_found}, state}

      _entry ->
        Process.demonitor(listener, [:flush])
        {:reply, :ok, close_read(state, listener)}
    end
  end

  @impl true
  def handle_info(:connect, state), do: handle_continue(:connect, state)

  def handle_info({:send_appends, stream}, state), do: {:noreply, send_appends(state, stream)}

  def handle_info({:open_read, listener}, state) do
    if Map.has_key?(state.listeners, listener) and state.listeners[listener].request == nil,
      do: {:noreply, open_read(state, listener)},
      else: {:noreply, state}
  end

  # Closes an append session that has had nothing to send since `request`.
  def handle_info({:idle, stream, request}, state) do
    case state.appends[stream] do
      %{request: ^request, outgoing: ""} = entry ->
        if AppendStream.idle?(entry.queue),
          do: {:noreply, close_append(state, stream)},
          else: {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  # A read session silent past the deadline, or an append waiting that long
  # for its ack, means the connection is gone without a close (a dead peer
  # or a black hole), so it's dropped and made again.
  def handle_info(:check, state) do
    Process.send_after(self(), :check, div(state.config.heartbeat_deadline, 2))
    deadline = now() - state.config.heartbeat_deadline

    silent =
      Enum.any?(state.listeners, fn {_listener, entry} ->
        entry.request != nil and entry.seen_at < deadline
      end) or
        Enum.any?(state.appends, fn {_stream, entry} ->
          AppendStream.sent?(entry.queue) and entry.seen_at < deadline
        end)

    if silent and state.conn != nil,
      do: {:noreply, lost(state, :silent)},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, listener, :process, _pid, _reason}, state) do
    if Map.has_key?(state.listeners, listener),
      do: {:noreply, close_read(state, listener)},
      else: {:noreply, state}
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.HTTP2.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &respond(&2, &1))

        # A stream's own acks send its next batches as they're read. Beyond
        # that, a window update may free bytes waiting to go out, and an ended
        # request room for a stream waiting to open its session.
        blocked =
          state.appends
          |> Enum.filter(fn {_stream, entry} -> entry.outgoing != "" end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.concat(state.waiting)

        state = %{state | waiting: MapSet.new()}
        {:noreply, Enum.reduce(blocked, state, &send_appends(&2, &1))}

      {:error, conn, error, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &respond(&2, &1))

        if Mint.HTTP.open?(conn),
          do: {:noreply, state},
          else: {:noreply, lost(state, error)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Requests

  defp request(%{conn: nil} = state, _from, _kind, _path),
    do: {:reply, {:error, %S2.Error{message: "not connected to S2"}}, state}

  defp request(state, from, kind, path) do
    # A read asking for protobuf is unary, and waits as long as its `wait`;
    # the tail comes as JSON.
    headers =
      if kind == :read,
        do: [{"accept", "application/protobuf"} | state.headers],
        else: state.headers

    state = make_room(state)

    case Mint.HTTP2.request(state.conn, "GET", path, headers, nil) do
      {:ok, conn, request} ->
        {:noreply,
         %{
           state
           | conn: conn,
             requests: Map.put(state.requests, request, {kind, from}),
             replies: Map.put(state.replies, request, %{status: nil, data: ""})
         }}

      {:error, conn, error} ->
        state = %{state | conn: conn}
        state = if Mint.HTTP.open?(conn), do: state, else: lost(state, error)
        {:reply, {:error, %S2.Error{message: inspect(error)}}, state}
    end
  end

  defp respond(state, {:status, request, status}) do
    case state.requests[request] do
      {:append, stream} -> put_in(state.appends[stream].status, status)
      {:listen, listener} -> put_in(state.listeners[listener].status, status)
      {_kind, _from} -> put_in(state.replies[request].status, status)
      nil -> state
    end
  end

  defp respond(state, {:headers, _request, _headers}), do: state

  defp respond(state, {:data, request, data}) do
    case state.requests[request] do
      {:append, stream} ->
        state = update_in(state.appends[stream].buffer, &(&1 <> data))
        if state.appends[stream].status == 200, do: append_frames(state, stream), else: state

      {:listen, listener} ->
        state = update_in(state.listeners[listener].buffer, &(&1 <> data))
        if state.listeners[listener].status == 200, do: read_frames(state, listener), else: state

      {_kind, _from} ->
        update_in(state.replies[request].data, &(&1 <> data))

      nil ->
        state
    end
  end

  defp respond(state, {:done, request}), do: finished(state, request, :done)

  defp respond(state, {:error, request, error}), do: finished(state, request, error)

  defp respond(state, _response), do: state

  # A request ended: `how` is :done, or the stream's error.
  defp finished(state, request, how) do
    case Map.pop(state.requests, request) do
      {nil, _requests} ->
        state

      {{:append, stream}, requests} ->
        append_ended(%{state | requests: requests}, stream, request, how)

      {{:listen, listener}, requests} ->
        read_ended(%{state | requests: requests}, listener, how)

      {{kind, from}, requests} ->
        {reply, replies} = Map.pop(state.replies, request)
        GenServer.reply(from, unary(kind, reply, how))
        %{state | requests: requests, replies: replies}
    end
  end

  defp unary(_kind, _reply, how) when how != :done,
    do: {:error, %S2.Error{message: inspect(how)}}

  defp unary(:read, %{status: 200, data: data}, :done), do: Protox.decode(data, S2.V1.ReadBatch)

  defp unary(:tail, %{status: 200, data: data}, :done) do
    case Jason.decode(data) do
      {:ok, %{"tail" => %{"seq_num" => seq_num, "timestamp" => timestamp}}} ->
        {:ok, %S2.V1.StreamPosition{seq_num: seq_num, timestamp: timestamp}}

      _other ->
        {:error, %S2.Error{message: "unexpected tail response: #{inspect(data)}"}}
    end
  end

  defp unary(_kind, %{status: status, data: data}, :done),
    do: {:error, S2.Error.from_http(status, data)}

  ## Appends

  # Opens the stream's session if it has work and none is open, then sends.
  defp send_appends(%{conn: nil} = state, _stream), do: state

  defp send_appends(state, stream) do
    entry = state.appends[stream]

    cond do
      entry == nil ->
        state

      entry.request == nil and not AppendStream.idle?(entry.queue) ->
        open_append(make_room(state), stream)

      entry.request != nil and not entry.draining ->
        {frames, queue} = AppendStream.take(entry.queue, now(), state.config.max_sent_bytes)
        # The wait for an ack starts with the first batch out.
        seen_at = if AppendStream.sent?(entry.queue), do: entry.seen_at, else: now()

        entry = %{
          entry
          | queue: queue,
            outgoing: entry.outgoing <> IO.iodata_to_binary(frames),
            seen_at: seen_at
        }

        flush(put_in(state.appends[stream], entry), stream)

      true ->
        state
    end
  end

  # With the connection at its request limit, the stream waits for a request
  # to end.
  defp open_append(state, stream) do
    if full?(state) do
      %{state | waiting: MapSet.put(state.waiting, stream)}
    else
      case Mint.HTTP2.request(
             state.conn,
             "POST",
             records_path(stream),
             [{"content-type", "s2s/proto"} | state.headers],
             :stream
           ) do
        {:ok, conn, request} ->
          entry =
            Map.merge(state.appends[stream], %{
              request: request,
              buffer: "",
              outgoing: "",
              status: nil,
              draining: false
            })

          state = %{
            state
            | conn: conn,
              appends: Map.put(state.appends, stream, entry),
              requests: Map.put(state.requests, request, {:append, stream})
          }

          send_appends(state, stream)

        {:error, conn, error} ->
          if Mint.HTTP.open?(conn),
            do: retry_appends(%{state | conn: conn}, stream, error),
            else: lost(%{state | conn: conn}, error)
      end
    end
  end

  defp full?(state),
    do:
      Mint.HTTP2.open_request_count(state.conn) >=
        Mint.HTTP2.get_server_setting(state.conn, :max_concurrent_streams)

  # At the connection's request limit, closes an append session with nothing
  # to send or acknowledge, if there is one.
  defp make_room(state) do
    idle =
      full?(state) &&
        Enum.find(state.appends, fn {_stream, entry} ->
          entry.request != nil and entry.outgoing == "" and AppendStream.idle?(entry.queue)
        end)

    case idle do
      {stream, _entry} -> close_append(state, stream)
      _room_or_none_idle -> state
    end
  end

  defp close_append(state, stream) do
    state = cancel(state, state.appends[stream].request)
    %{state | appends: Map.delete(state.appends, stream)}
  end

  # Sends as much of the session's outgoing bytes as HTTP/2 flow control
  # allows; the rest waits for a window update.
  defp flush(state, stream) do
    entry = state.appends[stream]

    if entry != nil and entry.request != nil and entry.outgoing != "" do
      window =
        min(
          Mint.HTTP2.get_window_size(state.conn, :connection),
          Mint.HTTP2.get_window_size(state.conn, {:request, entry.request})
        )

      size = min(window, byte_size(entry.outgoing))
      <<chunk::binary-size(size), rest::binary>> = entry.outgoing

      if size == 0 do
        state
      else
        case Mint.HTTP2.stream_request_body(state.conn, entry.request, chunk) do
          {:ok, conn} ->
            state = put_in(%{state | conn: conn}.appends[stream].outgoing, rest)
            if entry.draining and rest == "", do: finish(state, entry.request), else: state

          {:error, conn, error} ->
            if Mint.HTTP.open?(conn) do
              state = cancel(%{state | conn: conn}, entry.request)
              append_ended(state, stream, entry.request, error)
            else
              lost(%{state | conn: conn}, error)
            end
        end
      end
    else
      state
    end
  end

  defp append_frames(state, stream) do
    entry = state.appends[stream]

    case Framing.decode(entry.buffer) do
      {:ok, %{terminal: false, body: body} = frame, rest} ->
        {:ok, ack} = Protox.decode(body, S2.V1.AppendAck)
        {replies, queue} = AppendStream.ack(entry.queue, ack)
        Enum.each(replies, fn {from, ack} -> GenServer.reply(from, {:ok, ack}) end)
        entry = %{entry | queue: queue, buffer: rest, delay: 100, seen_at: now()}

        if AppendStream.idle?(queue),
          do: Process.send_after(self(), {:idle, stream, entry.request}, state.config.idle_after)

        # S2 asks to move to a new session: send nothing more on this one,
        # and half-close it once what's out is sent.
        entry = if frame.reconnect, do: %{entry | draining: true}, else: entry
        state = put_in(state.appends[stream], entry)

        state =
          if frame.reconnect and entry.outgoing == "",
            do: finish(state, entry.request),
            else: state

        append_frames(state, stream)

      {:ok, %{terminal: true, body: body}, _rest} ->
        state = cancel(state, entry.request)
        append_ended(state, stream, entry.request, S2.Error.from_terminal(body))

      {:error, error} ->
        state = cancel(state, entry.request)
        append_ended(state, stream, entry.request, %S2.Error{message: inspect(error)})

      # Every whole frame is read: the acks may have freed the next batches.
      :incomplete ->
        send_appends(state, stream)
    end
  end

  # The session is over. A refusal for good fails the oldest batch's calls;
  # anything else sends every unacknowledged batch again, after a backoff when
  # the session failed.
  defp append_ended(state, stream, request, how) do
    entry = state.appends[stream]
    state = %{state | requests: Map.delete(state.requests, request)}

    if entry == nil or entry.request != request do
      state
    else
      error =
        case how do
          :done when entry.status == 200 -> nil
          :done -> S2.Error.from_http(entry.status, entry.buffer)
          %S2.Error{} = error -> error
          error -> %S2.Error{message: inspect(error)}
        end

      entry = %{entry | request: nil, buffer: "", outgoing: ""}

      cond do
        error == nil ->
          state =
            put_in(state.appends[stream], %{entry | queue: AppendStream.requeue(entry.queue)})

          send_appends(state, stream)

        # With no batch out, there's none to blame: the session is retried.
        S2.Error.retryable?(error) or not AppendStream.sent?(entry.queue) ->
          state =
            put_in(state.appends[stream], %{entry | queue: AppendStream.requeue(entry.queue)})

          retry_appends(state, stream, error)

        true ->
          {callers, queue} = AppendStream.refuse(entry.queue)
          Enum.each(callers, &GenServer.reply(&1, {:error, error}))
          send_appends(put_in(state.appends[stream], %{entry | queue: queue}), stream)
      end
    end
  end

  defp retry_appends(state, stream, error) do
    entry = state.appends[stream]

    Logger.warning(
      "S2 append session on #{stream} failed, retrying in #{entry.delay} ms: #{inspect(error)}"
    )

    Process.send_after(self(), {:send_appends, stream}, entry.delay)
    put_in(state.appends[stream].delay, min(entry.delay * 2, 5_000))
  end

  ## Reads

  defp open_read(%{conn: nil} = state, _listener), do: state

  defp open_read(state, listener) do
    state = make_room(state)
    entry = state.listeners[listener]

    query =
      case entry.from do
        :tail -> "?tail_offset=0"
        seq_num -> "?seq_num=#{seq_num}"
      end

    case Mint.HTTP2.request(
           state.conn,
           "GET",
           records_path(entry.stream) <> query,
           [{"content-type", "s2s/proto"} | state.headers],
           nil
         ) do
      {:ok, conn, request} ->
        entry = Map.merge(entry, %{request: request, buffer: "", status: nil, seen_at: now()})

        %{
          state
          | conn: conn,
            listeners: Map.put(state.listeners, listener, entry),
            requests: Map.put(state.requests, request, {:listen, listener})
        }

      {:error, conn, error} ->
        if Mint.HTTP.open?(conn),
          do: read_ended(%{state | conn: conn}, listener, error),
          else: lost(%{state | conn: conn}, error)
    end
  end

  defp read_frames(state, listener) do
    entry = %{state.listeners[listener] | seen_at: now()}
    state = put_in(state.listeners[listener], entry)

    case Framing.decode(entry.buffer) do
      {:ok, %{terminal: false, body: body} = frame, rest} ->
        {:ok, batch} = Protox.decode(body, S2.V1.ReadBatch)

        entry =
          cond do
            batch.records != [] ->
              send(entry.pid, {S2, listener, {:records, batch.records}})
              %{entry | from: List.last(batch.records).seq_num + 1, delay: 100}

            # A listener from the tail learns where that was from its first
            # frame, so a reopened session doesn't skip what came meanwhile.
            entry.from == :tail and batch.tail != nil ->
              %{entry | from: batch.tail.seq_num}

            true ->
              entry
          end

        state = put_in(state.listeners[listener], %{entry | buffer: rest})

        if frame.reconnect do
          state = cancel(state, entry.request)
          open_read(put_in(state.listeners[listener].request, nil), listener)
        else
          read_frames(state, listener)
        end

      {:ok, %{terminal: true, body: body}, _rest} ->
        state = cancel(state, entry.request)
        read_ended(state, listener, S2.Error.from_terminal(body))

      {:error, error} ->
        state = cancel(state, entry.request)
        read_ended(state, listener, %S2.Error{message: inspect(error)})

      :incomplete ->
        state
    end
  end

  # The read session is over: open it again, or tell the listener S2 refused it.
  defp read_ended(state, listener, how) do
    case state.listeners[listener] do
      nil ->
        state

      entry ->
        error =
          case how do
            :done when entry.status == 200 -> %S2.Error{message: "read session ended"}
            :done -> S2.Error.from_http(entry.status, entry.buffer)
            %S2.Error{} = error -> error
            error -> %S2.Error{message: inspect(error)}
          end

        state = %{state | requests: Map.delete(state.requests, entry.request)}

        if S2.Error.retryable?(error) do
          Logger.warning(
            "S2 read session on #{entry.stream} ended, reopening in #{entry.delay} ms: #{inspect(error)}"
          )

          Process.send_after(self(), {:open_read, listener}, entry.delay)

          put_in(state.listeners[listener], %{
            entry
            | request: nil,
              delay: min(entry.delay * 2, 5_000)
          })
        else
          send(entry.pid, {S2, listener, {:error, error}})
          Process.demonitor(listener, [:flush])
          %{state | listeners: Map.delete(state.listeners, listener)}
        end
    end
  end

  defp close_read(state, listener) do
    {entry, listeners} = Map.pop(state.listeners, listener)
    state = %{state | listeners: listeners}
    if entry.request, do: cancel(state, entry.request), else: state
  end

  ## Connection

  # Half-closes a request: S2 still answers what was sent on it.
  defp finish(%{conn: nil} = state, _request), do: state

  defp finish(state, request) do
    case Mint.HTTP2.stream_request_body(state.conn, request, :eof) do
      {:ok, conn} -> %{state | conn: conn}
      {:error, conn, _error} -> %{state | conn: conn}
    end
  end

  # Resets a request, and forgets it.
  defp cancel(state, request) do
    state = %{
      state
      | requests: Map.delete(state.requests, request),
        replies: Map.delete(state.replies, request)
    }

    case state.conn && Mint.HTTP2.cancel_request(state.conn, request) do
      nil -> state
      {:ok, conn} -> %{state | conn: conn}
      {:error, conn, _error} -> %{state | conn: conn}
    end
  end

  # Every session waits for the next connection, and unary calls fail.
  defp lost(state, error) do
    Logger.warning("S2 connection lost, reconnecting: #{inspect(error)}")

    Enum.each(state.requests, fn
      {_request, {kind, from}} when kind in [:read, :tail] ->
        GenServer.reply(from, {:error, %S2.Error{message: inspect(error)}})

      _session ->
        :ok
    end)

    appends =
      Map.new(state.appends, fn {stream, entry} ->
        {stream,
         %{
           entry
           | request: nil,
             buffer: "",
             outgoing: "",
             queue: AppendStream.requeue(entry.queue)
         }}
      end)

    listeners =
      Map.new(state.listeners, fn {listener, entry} -> {listener, %{entry | request: nil}} end)

    Mint.HTTP.close(state.conn)
    send(self(), :connect)

    %{
      state
      | conn: nil,
        appends: appends,
        waiting: MapSet.new(),
        listeners: listeners,
        requests: %{},
        replies: %{}
    }
  end

  defp records_path(stream), do: "/v1/streams/#{URI.encode_www_form(stream)}/records"

  defp now, do: System.monotonic_time(:millisecond)
end

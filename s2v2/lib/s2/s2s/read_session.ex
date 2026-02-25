defmodule S2.S2S.ReadSession do
  @moduledoc """
  Unidirectional streaming read session.

  Opens a streaming GET to `/v1/streams/{stream}/records` with `Content-Type: s2s/proto`.
  Call `next_batch/1` repeatedly to receive `ReadBatch` messages. Heartbeat frames
  (empty ReadBatch) are skipped automatically.

  Sessions are NOT safe to share across processes — the underlying Mint connection
  delivers messages to the owning process's mailbox.
  """

  alias S2.S2S.{Framing, Shared}

  @recv_timeout 10_000

  defstruct [:conn, :request_ref, closed: false, data: <<>>]

  @doc """
  Open a new streaming read session.

  Accepts the same query opts as unary read: `:seq_num`, `:count`, `:wait`, etc.
  Returns `{:ok, session}` on success or `{:error, reason}` on failure.
  """
  def open(conn, basin, stream, opts \\ []) do
    query = Shared.build_read_query(opts)
    path = "/v1/streams/#{stream}/records" <> query

    headers = [
      {"content-type", "s2s/proto"},
      {"s2-basin", basin}
    ]

    case Mint.HTTP2.request(conn, "GET", path, headers, nil) do
      {:ok, conn, request_ref} ->
        session = %__MODULE__{conn: conn, request_ref: request_ref}
        wait_for_headers(session)

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end

  @doc """
  Receive the next batch of records from the session.

  Returns:
  - `{:ok, %ReadBatch{}, session}` — a batch with records
  - `{:error, :end_of_stream, session}` — server closed the stream normally
  - `{:error, reason, session}` — an error occurred
  """
  def next_batch(%__MODULE__{closed: true} = session) do
    {:error, :session_closed, session}
  end

  def next_batch(%__MODULE__{} = session) do
    case try_decode_batch(session.data) do
      {:ok, batch, rest} ->
        {:ok, batch, %{session | data: rest}}

      :incomplete ->
        receive_batch(session)

      {:error, reason} ->
        {:error, reason, close_session(session)}
    end
  end

  @doc """
  Close the read session. After closing, `next_batch/1` will return `{:error, :session_closed}`.
  """
  def close(%__MODULE__{closed: true} = session), do: {:ok, session}

  def close(%__MODULE__{} = session) do
    {:ok, %{session | closed: true}}
  end

  defp wait_for_headers(session) do
    receive do
      message ->
        case Mint.HTTP2.stream(session.conn, message) do
          {:ok, conn, responses} ->
            session = %{session | conn: conn}
            {status, data} = extract_status_and_data(responses, session.request_ref)

            cond do
              status == 200 ->
                {:ok, %{session | data: data}}

              status != nil ->
                {:error, {:unexpected_status, status}}

              true ->
                wait_for_headers(session)
            end

          {:error, _conn, _error, _responses} ->
            {:error, :stream_error}

          :unknown ->
            wait_for_headers(session)
        end
    after
      @recv_timeout -> {:error, :timeout}
    end
  end

  defp extract_status_and_data(responses, request_ref) do
    Enum.reduce(responses, {nil, <<>>}, fn
      {:status, ^request_ref, status}, {_s, d} -> {status, d}
      {:data, ^request_ref, data}, {s, d} -> {s, d <> data}
      _, acc -> acc
    end)
  end

  defp receive_batch(session) do
    receive do
      message ->
        case Mint.HTTP2.stream(session.conn, message) do
          {:ok, conn, responses} ->
            session = %{session | conn: conn}
            new_data = Shared.extract_data(responses, session.request_ref)
            all_data = session.data <> new_data

            # Check if server closed the stream
            done? = Enum.any?(responses, &match?({:done, _}, &1))

            case try_decode_batch(all_data) do
              {:ok, batch, rest} ->
                {:ok, batch, %{session | data: rest}}

              :incomplete when done? ->
                {:error, :end_of_stream, close_session(session)}

              :incomplete ->
                receive_batch(%{session | data: all_data})

              {:error, reason} ->
                {:error, reason, close_session(session)}
            end

          {:error, conn, _error, _responses} ->
            {:error, :stream_error, close_session(session, conn)}

          :unknown ->
            receive_batch(session)
        end
    after
      @recv_timeout -> {:error, :timeout, session}
    end
  end

  defp try_decode_batch(data) do
    case Framing.decode(data) do
      {:ok, %{terminal: false, body: body}, rest} ->
        case Protox.decode(body, S2.V1.ReadBatch) do
          {:ok, %{records: []} = _heartbeat} ->
            try_decode_batch(rest)

          {:ok, batch} ->
            {:ok, batch, rest}

          {:error, reason} ->
            {:error, {:decode_error, reason}}
        end

      {:ok, %{terminal: true, body: body}, _rest} ->
        {:error, Shared.parse_terminal_error(body)}

      :incomplete ->
        :incomplete
    end
  end

  defp close_session(session, conn \\ nil) do
    %{session | conn: conn || session.conn, closed: true}
  end
end

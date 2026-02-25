defmodule S2.S2S.AppendSession do
  @moduledoc """
  Bidirectional streaming append session.

  Opens a streaming POST to `/v1/streams/{stream}/records` with `Content-Type: s2s/proto`.
  Supports multiple sequential `append/2` calls on the same session, each sending a framed
  `AppendInput` and receiving a framed `AppendAck`.

  ## Process affinity

  Sessions are NOT safe to share across processes. The underlying Mint connection
  delivers TCP messages to the owning process's mailbox. Creating a session in one
  process and calling `append/2` from another will not work — the receiving process
  won't see the TCP data.
  """

  require Logger

  alias S2.S2S.Shared

  @recv_timeout 5_000

  @typedoc "An open append session."
  @type t :: %__MODULE__{}

  defstruct [:conn, :request_ref, :basin, :stream, :owner_pid, closed: false, data: <<>>]

  @doc """
  Open a new streaming append session.

  Returns `{:ok, session}` on success or `{:error, reason}` on failure.
  On `Mint.HTTP2.request/5` failure, returns `{:error, reason, conn}` so the
  caller can still manage the connection.
  """
  @spec open(Mint.HTTP2.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()} | {:error, term(), Mint.HTTP2.t()}
  def open(conn, basin, stream) do
    Logger.debug("S2S.AppendSession.open basin=#{basin} stream=#{stream}")
    path = "/v1/streams/#{URI.encode(stream)}/records"

    headers = [
      {"content-type", "s2s/proto"},
      {"s2-basin", basin}
    ]

    case Mint.HTTP2.request(conn, "POST", path, headers, :stream) do
      {:ok, conn, request_ref} ->
        session = %__MODULE__{
          conn: conn,
          request_ref: request_ref,
          basin: basin,
          stream: stream,
          owner_pid: self()
        }

        wait_for_headers(session)

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end

  @doc """
  Append a batch of records to the session.

  Returns `{:ok, ack, session}` on success or `{:error, reason, session}` on failure.
  The session is marked as closed on error and cannot be reused.
  """
  @spec append(t(), S2.V1.AppendInput.t()) ::
          {:ok, S2.V1.AppendAck.t(), t()} | {:error, term(), t()}
  def append(%__MODULE__{closed: true} = session, _input) do
    {:error, :session_closed, session}
  end

  def append(%__MODULE__{} = session, %S2.V1.AppendInput{} = input) do
    check_owner!(session)
    body = Shared.encode_framed(input)

    case Mint.HTTP2.stream_request_body(session.conn, session.request_ref, body) do
      {:ok, conn} ->
        session = %{session | conn: conn}
        receive_ack(session)

      {:error, conn, reason} ->
        {:error, reason, close_session(session, conn)}
    end
  end

  @doc """
  Close the append session gracefully by sending EOF on the request body.

  Returns `{:ok, session}` or `{:error, reason, session}`.
  """
  @spec close(t()) :: {:ok, t()} | {:error, term(), t()}
  def close(%__MODULE__{closed: true} = session), do: {:ok, session}

  def close(%__MODULE__{} = session) do
    case Mint.HTTP2.stream_request_body(session.conn, session.request_ref, :eof) do
      {:ok, conn} ->
        session = %{session | conn: conn, closed: true}
        drain_final_response(session)

      {:error, conn, reason} ->
        {:error, reason, close_session(session, conn)}
    end
  end

  # Wait for the server to respond with 200 headers, establishing the session.
  # Returns {:ok, session} or {:error, reason, conn} on failure so the caller
  # can always recover the connection.
  defp wait_for_headers(session) do
    receive do
      message ->
        case Mint.HTTP2.stream(session.conn, message) do
          {:ok, conn, responses} ->
            session = %{session | conn: conn}

            case check_session_status(responses, session.request_ref) do
              {:ok, 200} -> {:ok, session}
              {:ok, status} -> {:error, {:unexpected_status, status}, session.conn}
              :continue -> wait_for_headers(session)
            end

          {:error, conn, _error, _responses} ->
            {:error, :stream_error, conn}

          :unknown ->
            wait_for_headers(session)
        end
    after
      @recv_timeout -> {:error, :timeout, session.conn}
    end
  end

  defp check_session_status(responses, request_ref) do
    Enum.reduce_while(responses, :continue, fn
      {:status, ^request_ref, status}, _acc -> {:halt, {:ok, status}}
      _, acc -> {:cont, acc}
    end)
  end

  defp receive_ack(session) do
    all_data = session.data

    case Shared.decode_frame(all_data, S2.V1.AppendAck) do
      {:ok, ack, rest} ->
        {:ok, ack, %{session | data: rest}}

      {:error, reason} ->
        {:error, reason, close_session(session)}

      :incomplete ->
        do_receive_ack(%{session | data: <<>>}, all_data)
    end
  end

  defp do_receive_ack(session, acc) do
    receive do
      message ->
        case Mint.HTTP2.stream(session.conn, message) do
          {:ok, conn, responses} ->
            session = %{session | conn: conn}
            new_data = Shared.extract_data(responses, session.request_ref)
            all_data = acc <> new_data

            case Shared.check_buffer_size(all_data) do
              {:error, :buffer_overflow} ->
                {:error, :buffer_overflow, close_session(session)}

              :ok ->
                done? = Shared.done?(responses)

                case Shared.decode_frame(all_data, S2.V1.AppendAck) do
                  {:ok, ack, rest} ->
                    {:ok, ack, %{session | data: rest}}

                  {:error, reason} ->
                    {:error, reason, close_session(session)}

                  :incomplete when done? ->
                    {:error, :incomplete_frame, close_session(session)}

                  :incomplete ->
                    do_receive_ack(session, all_data)
                end
            end

          {:error, conn, _error, _responses} ->
            {:error, :stream_error, close_session(session, conn)}

          :unknown ->
            do_receive_ack(session, acc)
        end
    after
      @recv_timeout -> {:error, :timeout, close_session(session)}
    end
  end

  # After sending EOF, drain the server's final response (status/headers/done)
  # so the HTTP/2 stream is fully closed. Best-effort: if it times out or errors,
  # we still return the closed session.
  defp drain_final_response(session) do
    receive do
      message ->
        case Mint.HTTP2.stream(session.conn, message) do
          {:ok, conn, responses} ->
            session = %{session | conn: conn}

            if Shared.done?(responses) do
              {:ok, session}
            else
              drain_final_response(session)
            end

          {:error, conn, _error, _responses} ->
            {:ok, %{session | conn: conn}}

          :unknown ->
            drain_final_response(session)
        end
    after
      @recv_timeout -> {:ok, session}
    end
  end

  defp check_owner!(%__MODULE__{owner_pid: pid}) do
    if pid != self() do
      raise ArgumentError,
        "AppendSession must be used from the process that created it " <>
          "(owner: #{inspect(pid)}, caller: #{inspect(self())})"
    end
  end

  defp close_session(session, conn \\ nil) do
    %{session | conn: conn || session.conn, closed: true}
  end
end

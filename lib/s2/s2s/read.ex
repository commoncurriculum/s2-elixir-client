defmodule S2.S2S.Read do
  @moduledoc """
  Unary read — sends a single read request and receives the first `ReadBatch`.

  This opens an S2S session (streaming), so it decodes frames as data arrives
  rather than waiting for the HTTP stream to close. Heartbeat frames (empty
  ReadBatch) are skipped automatically.
  """

  require Logger

  alias S2.S2S.Shared

  @doc """
  Read a single batch of records from a stream.

  ## Options

    * `:seq_num` — Starting sequence number (default: 0).
    * `:count` — Maximum number of records to return.
    * `:wait` — Wait for records if none are available.
    * `:until` — Read until this sequence number.
    * `:clamp` — Clamp to the stream's tail if seq_num is past the end.
    * `:tail_offset` — Read from this offset before the tail.
    * `:token` — Bearer token for authentication.
    * `:recv_timeout` — Timeout in milliseconds for receiving the response (default: 5000).
  """
  @spec call(Mint.HTTP2.t(), String.t(), String.t(), keyword()) ::
          {:ok, S2.V1.ReadBatch.t(), Mint.HTTP2.t()}
          | {:error, term(), Mint.HTTP2.t()}
  def call(conn, basin, stream, opts \\ []) do
    Logger.debug(
      "S2S.Read basin=#{basin} stream=#{stream} opts=#{inspect(Keyword.delete(opts, :token))}"
    )

    query = Shared.build_read_query(opts)
    path = Shared.records_path(stream) <> query
    token = Keyword.get(opts, :token)
    headers = Shared.build_headers(basin, token)
    recv_timeout = Keyword.get(opts, :recv_timeout, Shared.default_timeout())

    case Mint.HTTP2.request(conn, "GET", path, headers, nil) do
      {:ok, conn, request_ref} ->
        dl = Shared.deadline(recv_timeout)
        receive_first_batch(conn, request_ref, %{status: nil, data: <<>>}, dl)

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end

  @doc false
  def handle_first_batch_response({:ok, conn, responses}, request_ref, acc) do
    acc = Shared.process_responses(responses, request_ref, acc)

    cond do
      acc[:done] ->
        handle_complete_response(acc, conn)

      acc[:status] != nil and acc[:status] != 200 ->
        {:continue, conn, acc}

      acc[:status] == 200 ->
        case Shared.check_buffer_size(acc.data) do
          {:error, :buffer_overflow} ->
            {:error, :buffer_overflow, conn}

          :ok ->
            case Shared.decode_read_batch(acc.data) do
              {:ok, batch, _rest} -> {:ok_cancel, batch, conn, request_ref}
              :incomplete -> {:continue, conn, acc}
              {:error, reason} -> {:error, reason, conn}
            end
        end

      true ->
        {:continue, conn, acc}
    end
  end

  def handle_first_batch_response({:error, conn, _error, _responses}, _request_ref, _acc) do
    {:error, :stream_error, conn}
  end

  def handle_first_batch_response(:unknown, conn, acc) do
    {:continue, conn, acc}
  end

  defp receive_first_batch(conn, request_ref, acc, dl) do
    receive do
      message ->
        case handle_first_batch_response(
               Mint.HTTP2.stream(conn, message),
               request_ref,
               acc
             ) do
          {:continue, conn, acc} -> receive_first_batch(conn, request_ref, acc, dl)
          {:ok_cancel, batch, conn, ref} -> cancel_and_return(conn, ref, batch)
          result -> result
        end
    after
      Shared.remaining(dl) -> {:error, :timeout, conn}
    end
  end

  # Cancel the streaming request to prevent orphaned HTTP/2 frames from
  # accumulating in the caller's mailbox after we return.
  defp cancel_and_return(conn, request_ref, batch) do
    case Mint.HTTP2.cancel_request(conn, request_ref) do
      {:ok, conn} -> {:ok, batch, conn}
      {:error, conn, _reason} -> {:ok, batch, conn}
    end
  end

  defp handle_complete_response(%{status: 200, data: data}, conn) do
    case Shared.decode_read_batch(data) do
      {:ok, batch, _rest} -> {:ok, batch, conn}
      {:error, reason} -> {:error, reason, conn}
      :incomplete -> {:error, :incomplete_frame, conn}
    end
  end

  defp handle_complete_response(%{status: status, data: data}, conn) do
    {:error, Shared.parse_http_error(status, data), conn}
  end
end

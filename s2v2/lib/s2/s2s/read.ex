defmodule S2.S2S.Read do
  @moduledoc """
  Unary read — sends a single read request and receives the first `ReadBatch`.

  This opens an S2S session (streaming), so it decodes frames as data arrives
  rather than waiting for the HTTP stream to close. Heartbeat frames (empty
  ReadBatch) are skipped automatically.
  """

  alias S2.S2S.{Framing, Shared}

  @recv_timeout 5_000

  def call(conn, basin, stream, opts \\ []) do
    query = Shared.build_read_query(opts)
    path = "/v1/streams/#{stream}/records" <> query

    headers = [
      {"content-type", "s2s/proto"},
      {"s2-basin", basin}
    ]

    case Mint.HTTP2.request(conn, "GET", path, headers, nil) do
      {:ok, conn, request_ref} ->
        receive_first_batch(conn, request_ref, %{status: nil, data: <<>>})

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end

  defp receive_first_batch(conn, request_ref, acc) do
    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, responses} ->
            acc = Shared.process_responses(responses, request_ref, acc)

            cond do
              acc[:done] ->
                handle_complete_response(acc, conn)

              acc[:status] != nil and acc[:status] != 200 ->
                receive_first_batch(conn, request_ref, acc)

              acc[:status] == 200 ->
                case try_decode_batch(acc.data) do
                  {:ok, batch, _rest} -> {:ok, batch, conn}
                  :incomplete -> receive_first_batch(conn, request_ref, acc)
                  {:error, reason} -> {:error, reason, conn}
                end

              true ->
                receive_first_batch(conn, request_ref, acc)
            end

          {:error, conn, _error, _responses} ->
            {:error, :stream_error, conn}

          :unknown ->
            receive_first_batch(conn, request_ref, acc)
        end
    after
      @recv_timeout -> {:error, :timeout, conn}
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

  defp handle_complete_response(%{status: 200, data: data}, conn) do
    case try_decode_batch(data) do
      {:ok, batch, _rest} -> {:ok, batch, conn}
      {:error, reason} -> {:error, reason, conn}
      :incomplete -> {:error, :incomplete_frame, conn}
    end
  end

  defp handle_complete_response(%{status: status, data: data}, conn) do
    {:error, Shared.parse_http_error(status, data), conn}
  end
end

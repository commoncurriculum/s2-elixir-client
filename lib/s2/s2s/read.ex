defmodule S2.S2S.Read do
  @moduledoc """
  Unary read — sends a single read request and receives the first `ReadBatch`.

  This opens an S2S session (streaming), so it decodes frames as data arrives
  rather than waiting for the HTTP stream to close. Heartbeat frames (empty
  ReadBatch) are skipped automatically.
  """

  require Logger

  alias S2.S2S.Shared

  @recv_timeout 5_000

  @spec call(Mint.HTTP2.t(), String.t(), String.t(), keyword()) ::
          {:ok, S2.V1.ReadBatch.t(), Mint.HTTP2.t()}
          | {:error, term(), Mint.HTTP2.t()}
  def call(conn, basin, stream, opts \\ []) do
    Logger.debug("S2S.Read basin=#{basin} stream=#{stream} opts=#{inspect(opts)}")
    query = Shared.build_read_query(opts)
    path = "/v1/streams/#{URI.encode_www_form(stream)}/records" <> query
    token = Keyword.get(opts, :token)

    headers = [
      {"content-type", "s2s/proto"},
      {"s2-basin", basin}
    ] ++ S2.S2S.Connection.auth_headers(token)

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
                case Shared.decode_read_batch(acc.data) do
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

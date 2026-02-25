defmodule S2.S2S.CheckTail do
  @moduledoc """
  Check tail position for a stream.

  The server always returns JSON for this endpoint, even with s2s/proto content type.
  Uses Mint HTTP/2 directly for consistency with the rest of the data plane.
  """

  alias S2.S2S.Shared

  def call(conn, basin, stream) do
    path = "/v1/streams/#{stream}/records/tail"

    headers = [
      {"s2-basin", basin}
    ]

    case Mint.HTTP2.request(conn, "GET", path, headers, nil) do
      {:ok, conn, request_ref} ->
        case Shared.receive_complete(conn, request_ref) do
          {:ok, %{status: 200, data: data}, conn} ->
            parse_tail_response(data, conn)

          {:ok, %{status: status, data: data}, conn} ->
            {:error, Shared.parse_http_error(status, data), conn}

          {:error, reason, conn} ->
            {:error, reason, conn}
        end

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end

  defp parse_tail_response(data, conn) do
    case Jason.decode(data) do
      {:ok, %{"tail" => tail}} ->
        position = %S2.V1.StreamPosition{
          seq_num: tail["seq_num"] || 0,
          timestamp: tail["timestamp"] || 0
        }

        {:ok, position, conn}

      {:error, reason} ->
        {:error, {:decode_error, reason}, conn}
    end
  end
end

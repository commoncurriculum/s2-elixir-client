defmodule S2.S2S.CheckTail do
  @moduledoc """
  Check tail position for a stream.

  Uses Mint HTTP/2 directly for consistency with the rest of the data plane.
  No `Content-Type` header is sent because the server always returns JSON for
  this endpoint regardless of the requested content type — sending `s2s/proto`
  has no effect on the response format.
  """

  require Logger

  alias S2.S2S.Shared

  @spec call(Mint.HTTP2.t(), String.t(), String.t()) ::
          {:ok, S2.V1.StreamPosition.t(), Mint.HTTP2.t()}
          | {:error, term(), Mint.HTTP2.t()}
  def call(conn, basin, stream) do
    Logger.debug("S2S.CheckTail basin=#{basin} stream=#{stream}")
    path = "/v1/streams/#{URI.encode_www_form(stream)}/records/tail"

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
      {:ok, %{"tail" => %{"seq_num" => seq_num, "timestamp" => timestamp}}}
      when is_integer(seq_num) and seq_num >= 0 and is_integer(timestamp) and timestamp >= 0 ->
        position = %S2.V1.StreamPosition{
          seq_num: seq_num,
          timestamp: timestamp
        }

        {:ok, position, conn}

      # Server may omit timestamp for empty streams. Default to 0 (not provided).
      {:ok, %{"tail" => %{"seq_num" => seq_num}}} when is_integer(seq_num) and seq_num >= 0 ->
        position = %S2.V1.StreamPosition{
          seq_num: seq_num,
          timestamp: 0
        }

        {:ok, position, conn}

      {:ok, %{"tail" => tail}} when is_map(tail) ->
        {:error, {:decode_error, {:invalid_tail_fields, inspect(tail)}}, conn}

      {:ok, body} ->
        {:error, {:decode_error, {:missing_tail_key, inspect(body)}}, conn}

      {:error, reason} ->
        {:error, {:decode_error, reason}, conn}
    end
  end
end

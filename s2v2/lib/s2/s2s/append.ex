defmodule S2.S2S.Append do
  @moduledoc """
  Unary append — sends a single `AppendInput` and receives a single `AppendAck`.
  """

  alias S2.S2S.Shared

  def call(conn, basin, stream, %S2.V1.AppendInput{} = input) do
    body = Shared.encode_framed(input)
    path = "/v1/streams/#{stream}/records"

    headers = [
      {"content-type", "s2s/proto"},
      {"s2-basin", basin}
    ]

    case Mint.HTTP2.request(conn, "POST", path, headers, body) do
      {:ok, conn, request_ref} ->
        case Shared.receive_complete(conn, request_ref) do
          {:ok, %{status: 200, data: data}, conn} ->
            case Shared.decode_frame(data, S2.V1.AppendAck) do
              {:ok, ack, _rest} -> {:ok, ack, conn}
              {:error, reason} -> {:error, reason, conn}
              :incomplete -> {:error, :incomplete_frame, conn}
            end

          {:ok, %{status: status, data: data}, conn} ->
            {:error, Shared.parse_http_error(status, data), conn}

          {:error, reason, conn} ->
            {:error, reason, conn}
        end

      {:error, conn, reason} ->
        {:error, reason, conn}
    end
  end
end

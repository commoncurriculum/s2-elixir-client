defmodule S2.S2S.Append do
  @moduledoc """
  Unary append — sends a single `AppendInput` and receives a single `AppendAck`.
  """

  require Logger

  alias S2.S2S.Shared

  @doc """
  Append records to a stream (unary request/response).

  ## Options

    * `:token` — Bearer token for authentication.
    * `:recv_timeout` — Timeout in milliseconds for receiving the response (default: 5000).

  Returns `{:ok, ack, conn}` on success or `{:error, reason, conn}` on failure.
  """
  @spec call(Mint.HTTP2.t(), String.t(), String.t(), S2.V1.AppendInput.t(), keyword()) ::
          {:ok, S2.V1.AppendAck.t(), Mint.HTTP2.t()}
          | {:error, term(), Mint.HTTP2.t()}
  def call(conn, basin, stream, %S2.V1.AppendInput{} = input, opts \\ []) do
    Logger.debug(
      "S2S.Append basin=#{basin} stream=#{stream} records=#{length(input.records || [])}"
    )

    case Shared.encode_framed(input) do
      {:error, reason} ->
        {:error, reason, conn}

      {:ok, body} ->
        do_call(conn, basin, stream, body, opts)
    end
  end

  defp do_call(conn, basin, stream, body, opts) do
    path = Shared.records_path(stream)
    token = Keyword.get(opts, :token)
    recv_timeout = Keyword.get(opts, :recv_timeout, Shared.default_timeout())
    headers = Shared.build_headers(basin, token)

    case Mint.HTTP2.request(conn, "POST", path, headers, body) do
      {:ok, conn, request_ref} ->
        case Shared.receive_complete(conn, request_ref, timeout: recv_timeout) do
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

defmodule S2.S2S.Shared do
  @moduledoc false

  alias S2.S2S.Framing

  @default_timeout 5_000

  @doc """
  Receive a complete unary HTTP/2 response (status + headers + data + done).

  Accumulates all response parts and returns `{:ok, %{status: ..., data: ...}, conn}`
  once the stream is done.
  """
  def receive_complete(conn, request_ref, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    do_receive_complete(conn, request_ref, %{status: nil, data: <<>>}, timeout)
  end

  defp do_receive_complete(conn, request_ref, acc, timeout) do
    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, responses} ->
            acc = process_responses(responses, request_ref, acc)

            if acc[:done] do
              {:ok, acc, conn}
            else
              do_receive_complete(conn, request_ref, acc, timeout)
            end

          {:error, conn, _error, _responses} ->
            {:error, :stream_error, conn}

          :unknown ->
            do_receive_complete(conn, request_ref, acc, timeout)
        end
    after
      timeout -> {:error, :timeout, conn}
    end
  end

  @doc """
  Extract data frames from a list of Mint responses.
  """
  def extract_data(responses, request_ref) do
    Enum.reduce(responses, <<>>, fn
      {:data, ^request_ref, data}, acc -> acc <> data
      _, acc -> acc
    end)
  end

  @doc """
  Process Mint responses into an accumulator map with :status, :data, :done keys.
  """
  def process_responses(responses, request_ref, acc) do
    Enum.reduce(responses, acc, fn
      {:status, ^request_ref, status}, acc -> Map.put(acc, :status, status)
      {:headers, ^request_ref, _headers}, acc -> acc
      {:data, ^request_ref, data}, acc -> Map.update!(acc, :data, &(&1 <> data))
      {:done, ^request_ref}, acc -> Map.put(acc, :done, true)
      _, acc -> acc
    end)
  end

  @doc """
  Parse a non-200 HTTP response body into an `%S2.Error{}`.
  """
  def parse_http_error(status, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"code" => code, "message" => message}} ->
        %S2.Error{status: status, code: code, message: message}

      _ ->
        %S2.Error{status: status, message: data}
    end
  end

  @doc """
  Parse a terminal S2S frame body into an `%S2.Error{}`.

  Terminal frames contain a 2-byte big-endian status code followed by JSON error info.
  Returns a safe error if the body is too short to contain a status code.
  """
  def parse_terminal_error(<<status_code::16-big, json_rest::binary>>) do
    case Jason.decode(json_rest) do
      {:ok, %{"code" => code, "message" => message}} ->
        %S2.Error{status: status_code, code: code, message: message}

      _ ->
        %S2.Error{status: status_code, message: json_rest}
    end
  end

  def parse_terminal_error(data) do
    %S2.Error{message: "malformed terminal frame: #{inspect(data)}"}
  end

  @doc """
  Decode an S2S frame containing a protobuf message of the given type.

  Returns `{:ok, decoded, rest}` on success, `{:error, reason}` on terminal/decode error,
  or `:incomplete` if more data is needed.
  """
  def decode_frame(data, proto_module) do
    case Framing.decode(data) do
      {:ok, %{terminal: false, body: body}, rest} ->
        case Protox.decode(body, proto_module) do
          {:ok, decoded} -> {:ok, decoded, rest}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:ok, %{terminal: true, body: body}, _rest} ->
        {:error, parse_terminal_error(body)}

      :incomplete ->
        :incomplete
    end
  end

  @doc """
  Build a query string from keyword opts, filtering to known read parameters.
  """
  def build_read_query(opts) do
    params =
      opts
      |> Keyword.take([:seq_num, :count, :wait, :until, :clamp, :tail_offset])
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    case params do
      [] -> ""
      _ -> "?" <> Enum.join(params, "&")
    end
  end

  @doc """
  Encode a protobuf struct into an S2S-framed binary.
  """
  def encode_framed(proto_struct) do
    {iodata, _size} = Protox.encode!(proto_struct)
    proto_bytes = IO.iodata_to_binary(iodata)
    Framing.encode(proto_bytes)
  end
end

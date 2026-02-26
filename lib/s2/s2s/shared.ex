defmodule S2.S2S.Shared do
  @moduledoc false

  alias S2.S2S.Framing

  @type conn :: Mint.HTTP2.t()

  @default_timeout 5_000

  @doc """
  Default timeout in milliseconds for S2S operations.
  """
  def default_timeout, do: @default_timeout

  @doc """
  Compute a deadline (monotonic time in ms) from a timeout in ms.
  """
  @spec deadline(non_neg_integer()) :: integer()
  def deadline(timeout_ms) do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  @doc """
  Remaining time until a deadline, minimum 0.
  """
  @spec remaining(integer()) :: non_neg_integer()
  def remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  # Maximum bytes to buffer before rejecting a frame as too large.
  # Protects against OOM from a misbehaving server (16 MiB).
  @max_buffer_size 16 * 1024 * 1024

  @doc """
  Receive a complete unary HTTP/2 response (status + headers + data + done).

  Accumulates all response parts and returns `{:ok, %{status: ..., data: ...}, conn}`
  once the stream is done.
  """
  @spec receive_complete(conn, reference(), keyword()) ::
          {:ok, map(), conn} | {:error, term(), conn}
  def receive_complete(conn, request_ref, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    dl = deadline(timeout)
    do_receive_complete(conn, request_ref, %{status: nil, data: <<>>}, dl)
  end

  defp do_receive_complete(conn, request_ref, acc, dl) do
    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, responses} ->
            acc = process_responses(responses, request_ref, acc)

            if acc[:done] do
              {:ok, acc, conn}
            else
              do_receive_complete(conn, request_ref, acc, dl)
            end

          {:error, updated_conn, _error, _responses} ->
            # Use Mint's updated conn — it may have cleaned up stream state.
            {:error, :stream_error, updated_conn}

          :unknown ->
            do_receive_complete(conn, request_ref, acc, dl)
        end
    after
      remaining(dl) -> {:error, :timeout, conn}
    end
  end

  @doc """
  Extract data frames from a list of Mint responses.
  """
  @spec extract_data([term()], reference()) :: binary()
  def extract_data(responses, request_ref) do
    Enum.reduce(responses, <<>>, fn
      {:data, ^request_ref, data}, acc -> acc <> data
      _, acc -> acc
    end)
  end

  @doc """
  Check whether any response is a `:done` signal.
  """
  @spec done?([term()]) :: boolean()
  def done?(responses) do
    Enum.any?(responses, &match?({:done, _}, &1))
  end

  @doc """
  Process Mint responses into an accumulator map with :status, :data, :done keys.
  """
  @spec process_responses([term()], reference(), map()) :: map()
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
  @spec parse_http_error(integer(), binary()) :: S2.Error.t()
  def parse_http_error(status, data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"code" => code, "message" => message}} ->
        %S2.Error{status: status, code: code, message: message}

      {:ok, %{"message" => message}} ->
        %S2.Error{status: status, message: message}

      {:ok, decoded} when is_map(decoded) ->
        %S2.Error{status: status, message: inspect(decoded)}

      _ ->
        %S2.Error{status: status, message: data}
    end
  end

  @doc """
  Parse a terminal S2S frame body into an `%S2.Error{}`.

  Terminal frames contain a 2-byte big-endian status code followed by JSON error info.
  Returns a safe error if the body is too short to contain a status code.
  """
  @spec parse_terminal_error(binary()) :: S2.Error.t()
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
  @spec decode_frame(binary(), module()) ::
          {:ok, struct(), binary()} | {:error, term()} | :incomplete
  def decode_frame(data, proto_module) do
    case Framing.decode(data) do
      {:ok, %{terminal: false, body: body}, rest} ->
        case Protox.decode(body, proto_module) do
          {:ok, decoded} -> {:ok, decoded, rest}
          {:error, reason} -> {:error, {:decode_error, reason}}
        end

      {:ok, %{terminal: true, body: body}, _rest} ->
        {:error, parse_terminal_error(body)}

      {:error, reason} ->
        {:error, reason}

      :incomplete ->
        :incomplete
    end
  end

  @doc """
  Decode a ReadBatch from S2S-framed data, automatically skipping heartbeat
  frames (empty ReadBatch with no records).

  Returns `{:ok, batch, rest}`, `{:error, reason}`, or `:incomplete`.
  """
  @spec decode_read_batch(binary()) ::
          {:ok, S2.V1.ReadBatch.t(), binary()} | {:error, term()} | :incomplete
  # Heartbeat skipping is tail-recursive (BEAM TCO), so consecutive heartbeats
  # won't blow the stack. Each heartbeat also shrinks `rest`, so it terminates.
  def decode_read_batch(data) do
    case Framing.decode(data) do
      {:ok, %{terminal: false, body: body}, rest} ->
        case Protox.decode(body, S2.V1.ReadBatch) do
          {:ok, %{records: []} = _heartbeat} ->
            decode_read_batch(rest)

          {:ok, batch} ->
            {:ok, batch, rest}

          {:error, reason} ->
            {:error, {:decode_error, reason}}
        end

      {:ok, %{terminal: true, body: body}, _rest} ->
        {:error, parse_terminal_error(body)}

      {:error, reason} ->
        {:error, reason}

      :incomplete ->
        :incomplete
    end
  end

  @doc """
  Build the S2S records path for a stream.
  """
  @spec records_path(String.t()) :: String.t()
  def records_path(stream) do
    "/v1/streams/#{URI.encode_www_form(stream)}/records"
  end

  @doc """
  Build standard S2S headers with basin and optional auth token.

  ## Options

    * `:content_type` — include content-type header (default: `true`).
  """
  @spec build_headers(String.t(), String.t() | nil, keyword()) :: [{String.t(), String.t()}]
  def build_headers(basin, token, opts \\ []) do
    headers =
      if Keyword.get(opts, :content_type, true) do
        [{"content-type", "s2s/proto"}, {"s2-basin", basin}]
      else
        [{"s2-basin", basin}]
      end

    headers ++ S2.S2S.Connection.auth_headers(token)
  end

  @doc """
  Assert that the calling process owns the session. Raises ArgumentError if not.
  """
  @spec assert_owner!(pid(), String.t()) :: :ok
  def assert_owner!(owner_pid, module_name) do
    if owner_pid != self() do
      raise ArgumentError,
        "#{module_name} must be used from the process that created it " <>
          "(owner: #{inspect(owner_pid)}, caller: #{inspect(self())})"
    end

    :ok
  end

  @doc """
  Build a query string from keyword opts, filtering to known read parameters.
  Values are URL-encoded to prevent parameter injection.
  """
  @spec build_read_query(keyword()) :: String.t()
  def build_read_query(opts) do
    params = Keyword.take(opts, [:seq_num, :count, :wait, :until, :clamp, :tail_offset])

    case params do
      [] -> ""
      _ -> "?" <> URI.encode_query(params)
    end
  end

  @doc """
  Encode a Protox-compatible struct (e.g. `S2.V1.AppendInput`) into an
  S2S-framed binary with optional compression.

  ## Options

    * `:compression` — `:none`, `:gzip`, or `:zstd` (default: `:none`).
  """
  @spec encode_framed(struct(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode_framed(proto_struct, opts \\ []) do
    case Protox.encode(proto_struct) do
      {:ok, iodata, _size} ->
        proto_bytes = IO.iodata_to_binary(iodata)
        {:ok, Framing.encode(proto_bytes, opts)}

      {:error, reason} ->
        {:error, {:encode_error, reason}}
    end
  end

  @doc """
  Check if accumulated buffer exceeds the safety limit.
  Returns `:ok` or `{:error, :buffer_overflow}`.
  """
  @spec check_buffer_size(binary()) :: :ok | {:error, :buffer_overflow}
  def check_buffer_size(data) when byte_size(data) > @max_buffer_size, do: {:error, :buffer_overflow}
  def check_buffer_size(_data), do: :ok
end

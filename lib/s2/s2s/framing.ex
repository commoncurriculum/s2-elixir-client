defmodule S2.S2S.Framing do
  @moduledoc """
  S2S wire framing: encode/decode length-prefixed frames with compression.

  Supports `:none`, `:gzip`, and `:zstd` compression. Gzip uses Erlang's
  built-in `:zlib`. Zstd requires the optional `:ezstd` dependency — if
  not installed, encoding with `:zstd` raises and decoding returns an error.
  """

  import Bitwise

  @ezstd_available Code.ensure_loaded?(:ezstd)

  @terminal_bit 0x80
  @compression_mask 0x60
  # Note: the 24-bit length prefix naturally caps frames at ~16 MiB (0xFFFFFF bytes).
  # No additional length validation is needed.

  @type compression :: :none | :zstd | :gzip | :unknown

  @type frame :: %{terminal: boolean(), compression: compression(), body: binary()}

  @doc """
  Encode a binary body into an S2S frame with optional compression.

  ## Options

    * `:terminal` — Whether this is a terminal frame (default: `false`).
    * `:compression` — Compression algorithm: `:none`, `:gzip`, or `:zstd` (default: `:none`).

  Raises `ArgumentError` for unsupported compression types.
  """
  # Maximum frame size: 24-bit length field (0xFFFFFF = 16,777,215 bytes including flags byte).
  @max_frame_body 0xFFFFFF - 1

  @spec encode(binary(), keyword()) :: binary()
  def encode(body, opts \\ []) do
    terminal = Keyword.get(opts, :terminal, false)
    compression = Keyword.get(opts, :compression, :none)

    compressed_body = compress(body, compression)
    flags = build_flags(terminal, compression)
    length = byte_size(compressed_body) + 1

    if byte_size(compressed_body) > @max_frame_body do
      raise ArgumentError,
            "frame body too large: #{byte_size(compressed_body)} bytes exceeds 24-bit max (#{@max_frame_body})"
    end

    <<length::24-big, flags, compressed_body::binary>>
  end

  @doc """
  Decode an S2S frame, decompressing the body if needed.

  Returns `{:ok, frame, rest}` or `:incomplete`. The returned frame body
  is always decompressed.
  """
  @spec decode(binary()) :: {:ok, frame(), binary()} | :incomplete | {:error, term()}
  def decode(data) when byte_size(data) < 3, do: :incomplete

  def decode(<<0::24-big, _rest::binary>>), do: {:error, :invalid_frame}

  def decode(<<length::24-big, rest::binary>>) when byte_size(rest) < length do
    :incomplete
  end

  def decode(<<length::24-big, flags, body_and_rest::binary>>) do
    body_size = length - 1
    <<body::binary-size(body_size), rest::binary>> = body_and_rest

    terminal = (flags &&& @terminal_bit) != 0
    compression = parse_compression(flags &&& @compression_mask)

    case decompress(body, compression) do
      {:ok, decompressed} ->
        {:ok, %{terminal: terminal, compression: compression, body: decompressed}, rest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_flags(terminal, compression) do
    t = if terminal, do: @terminal_bit, else: 0
    c = compression_bits(compression)
    t ||| c
  end

  defp compression_bits(:none), do: 0x00
  defp compression_bits(:zstd), do: 0x20
  defp compression_bits(:gzip), do: 0x40

  defp parse_compression(0x00), do: :none
  defp parse_compression(0x20), do: :zstd
  defp parse_compression(0x40), do: :gzip
  defp parse_compression(_bits), do: :unknown

  # Compression

  defp compress(body, :none), do: body
  defp compress(body, :gzip), do: :zlib.gzip(body)

  defp compress(body, :zstd) do
    ensure_ezstd!()
    :ezstd.compress(body)
  end

  defp compress(_body, other) do
    raise ArgumentError, "unsupported compression: #{inspect(other)}"
  end

  # Decompression

  defp decompress(body, :none), do: {:ok, body}

  defp decompress(body, :gzip) do
    {:ok, :zlib.gunzip(body)}
  rescue
    e -> {:error, {:decompression_error, :gzip, e}}
  end

  if @ezstd_available do
    defp decompress(body, :zstd) do
      case :ezstd.decompress(body) do
        {:error, reason} -> {:error, {:decompression_error, :zstd, reason}}
        decompressed when is_binary(decompressed) -> {:ok, decompressed}
      end
    rescue
      e -> {:error, {:decompression_error, :zstd, e}}
    end
  else
    defp decompress(_body, :zstd) do
      {:error,
       {:missing_dependency, :ezstd, "add {:ezstd, \"~> 1.1\"} to your deps for zstd support"}}
    end
  end

  defp decompress(_body, :unknown) do
    {:error, :unknown_compression}
  end

  if @ezstd_available do
    defp ensure_ezstd!, do: :ok
  else
    defp ensure_ezstd! do
      raise ArgumentError,
            "zstd compression requires the :ezstd dependency. Add {:ezstd, \"~> 1.1\"} to your mix.exs deps."
    end
  end
end

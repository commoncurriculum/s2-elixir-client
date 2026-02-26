defmodule S2.S2S.Framing do
  @moduledoc """
  S2S wire framing: encode/decode length-prefixed frames with flags.

  Compression flags (zstd, gzip) are parsed on decode but encoding always
  uses `:none`. The S2 server does not currently send compressed frames,
  but this module is forward-compatible if it does in the future.
  """

  import Bitwise

  @terminal_bit 0x80
  @compression_mask 0x60
  # Note: the 24-bit length prefix naturally caps frames at ~16 MiB (0xFFFFFF bytes).
  # No additional length validation is needed.

  @type compression :: :none | :zstd | :gzip | :unknown

  @type frame :: %{terminal: boolean(), compression: compression(), body: binary()}

  @spec encode(binary(), keyword()) :: binary()
  def encode(body, opts \\ []) do
    terminal = Keyword.get(opts, :terminal, false)
    compression = Keyword.get(opts, :compression, :none)

    flags = build_flags(terminal, compression)
    length = byte_size(body) + 1

    <<length::24-big, flags, body::binary>>
  end

  @spec decode(binary()) :: {:ok, frame(), binary()} | :incomplete
  def decode(data) when byte_size(data) < 3, do: :incomplete

  def decode(<<length::24-big, rest::binary>>) when byte_size(rest) < length do
    :incomplete
  end

  def decode(<<length::24-big, flags, body_and_rest::binary>>) do
    body_size = length - 1
    <<body::binary-size(body_size), rest::binary>> = body_and_rest

    terminal = (flags &&& @terminal_bit) != 0
    compression = parse_compression(flags &&& @compression_mask)

    {:ok, %{terminal: terminal, compression: compression, body: body}, rest}
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
end

defmodule S2.Patterns.Chunking do
  @moduledoc false

  # S2 record limit is 1 MiB (1_048_576 bytes). We reserve space for protobuf
  # overhead (headers, field tags, varint lengths). The TypeScript SDK reserves
  # ~1 KiB for this; we do the same.
  @max_record_bytes 1_048_576
  @overhead 1_024
  @max_chunk_bytes @max_record_bytes - @overhead

  @spec max_chunk_bytes() :: pos_integer()
  def max_chunk_bytes, do: @max_chunk_bytes

  @spec chunk(binary()) :: [binary()]
  def chunk(<<>>), do: [<<>>]

  def chunk(data) when byte_size(data) <= @max_chunk_bytes, do: [data]

  def chunk(data) do
    do_chunk(data, [])
    |> Enum.reverse()
  end

  defp do_chunk(data, acc) when byte_size(data) <= @max_chunk_bytes do
    [data | acc]
  end

  defp do_chunk(data, acc) do
    <<chunk::binary-size(@max_chunk_bytes), rest::binary>> = data
    do_chunk(rest, [chunk | acc])
  end
end

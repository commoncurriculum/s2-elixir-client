defmodule S2.Patterns.ChunkingTest do
  use ExUnit.Case, async: true

  alias S2.Patterns.Chunking

  test "small message returns single chunk" do
    data = "hello world"
    chunks = Chunking.chunk(data)
    assert chunks == [data]
  end

  test "empty binary returns single empty chunk" do
    assert Chunking.chunk(<<>>) == [<<>>]
  end

  test "message exactly at max size returns single chunk" do
    max = Chunking.max_chunk_bytes()
    data = :binary.copy(<<0>>, max)
    chunks = Chunking.chunk(data)
    assert length(chunks) == 1
    assert hd(chunks) == data
  end

  test "message one byte over max splits into two chunks" do
    max = Chunking.max_chunk_bytes()
    data = :binary.copy(<<0>>, max + 1)
    chunks = Chunking.chunk(data)
    assert length(chunks) == 2
    assert byte_size(hd(chunks)) == max
    assert byte_size(List.last(chunks)) == 1
  end

  test "large message splits into correct number of chunks" do
    max = Chunking.max_chunk_bytes()
    # 3.5x the max
    data = :binary.copy(<<1>>, trunc(max * 3.5))
    chunks = Chunking.chunk(data)
    assert length(chunks) == 4
    # reassembled data matches original
    assert IO.iodata_to_binary(chunks) == data
  end

  test "all chunks except last are exactly max size" do
    max = Chunking.max_chunk_bytes()
    data = :binary.copy(<<0xFF>>, max * 2 + 100)
    chunks = Chunking.chunk(data)
    assert length(chunks) == 3

    [c1, c2, c3] = chunks
    assert byte_size(c1) == max
    assert byte_size(c2) == max
    assert byte_size(c3) == 100
  end

  test "reassembled chunks equal original data" do
    max = Chunking.max_chunk_bytes()
    data = :crypto.strong_rand_bytes(max * 5 + 42)
    chunks = Chunking.chunk(data)
    assert IO.iodata_to_binary(chunks) == data
  end

  test "data exactly divisible by max_chunk_bytes produces exact chunks" do
    max = Chunking.max_chunk_bytes()
    data = :binary.copy(<<0>>, max * 2)
    chunks = Chunking.chunk(data)
    assert length(chunks) == 2
    assert byte_size(hd(chunks)) == max
    assert byte_size(List.last(chunks)) == max
  end

  test "max_chunk_bytes is less than 1 MiB" do
    # S2 record limit is 1 MiB; chunk body must leave room for headers
    assert Chunking.max_chunk_bytes() < 1_048_576
    assert Chunking.max_chunk_bytes() > 0
  end
end

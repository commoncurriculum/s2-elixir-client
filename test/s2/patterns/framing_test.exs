defmodule S2.Patterns.RecordFramingTest do
  use ExUnit.Case, async: true

  alias S2.Patterns.RecordFraming, as: Framing
  alias S2.Patterns.Chunking
  alias S2.Patterns.Constants

  describe "frame/1 with small message (single record)" do
    test "returns one AppendRecord" do
      records = Framing.frame("hello")
      assert length(records) == 1
    end

    test "record body contains the data" do
      [record] = Framing.frame("hello")
      assert record.body == "hello"
    end

    test "single-chunk record has no framing headers" do
      [record] = Framing.frame("hello")

      framing_headers =
        Enum.filter(record.headers, fn h ->
          h.name in [Constants.frame_bytes(), Constants.frame_records()]
        end)

      assert framing_headers == []
    end
  end

  describe "frame/1 with large message (multiple records)" do
    setup do
      max = Chunking.max_chunk_bytes()
      data = :crypto.strong_rand_bytes(max * 2 + 100)
      records = Framing.frame(data)
      %{data: data, records: records, max: max}
    end

    test "returns multiple AppendRecords", %{records: records} do
      assert length(records) == 3
    end

    test "first record has _frame_bytes header with total size", %{data: data, records: records} do
      first = hd(records)
      header = find_header(first, Constants.frame_bytes())
      assert header != nil
      assert decode_u64(header.value) == byte_size(data)
    end

    test "first record has _frame_records header with chunk count", %{records: records} do
      first = hd(records)
      header = find_header(first, Constants.frame_records())
      assert header != nil
      assert decode_u64(header.value) == 3
    end

    test "subsequent records have no framing headers", %{records: records} do
      for record <- tl(records) do
        assert find_header(record, Constants.frame_bytes()) == nil
        assert find_header(record, Constants.frame_records()) == nil
      end
    end

    test "reassembled bodies match original data", %{data: data, records: records} do
      reassembled = records |> Enum.map(& &1.body) |> IO.iodata_to_binary()
      assert reassembled == data
    end
  end

  describe "assembler" do
    test "single-record message returns immediately" do
      [record] = Framing.frame("hello")
      seq_record = to_sequenced(record, 0)

      assembler = Framing.Assembler.new()
      assert {:ok, "hello", assembler} = Framing.Assembler.add(assembler, seq_record)
      # assembler should be clean after emitting
      assert assembler.pending == nil
    end

    test "multi-record message assembles after all chunks arrive" do
      max = Chunking.max_chunk_bytes()
      data = :crypto.strong_rand_bytes(max + 100)
      records = Framing.frame(data)
      assert length(records) == 2

      assembler = Framing.Assembler.new()
      [r1, r2] = records

      # First chunk: incomplete
      assert {:incomplete, assembler} = Framing.Assembler.add(assembler, to_sequenced(r1, 0))
      assert assembler.pending != nil

      # Second chunk: completes the message
      assert {:ok, ^data, assembler} = Framing.Assembler.add(assembler, to_sequenced(r2, 1))
      assert assembler.pending == nil
    end

    test "assembler rejects new frame start while still assembling" do
      max = Chunking.max_chunk_bytes()
      data1 = :crypto.strong_rand_bytes(max + 100)
      data2 = :crypto.strong_rand_bytes(max + 100)
      records1 = Framing.frame(data1)
      records2 = Framing.frame(data2)

      assembler = Framing.Assembler.new()
      # Start assembling first message
      {:incomplete, assembler} = Framing.Assembler.add(assembler, to_sequenced(hd(records1), 0))

      # Feeding the start of a second multi-chunk message should error
      assert {:error, :unexpected_record} =
               Framing.Assembler.add(assembler, to_sequenced(hd(records2), 1))
    end

    test "returns error on frame size mismatch" do
      # Create a multi-chunk message, then tamper with one chunk's body
      max = Chunking.max_chunk_bytes()
      data = :crypto.strong_rand_bytes(max + 100)
      records = Framing.frame(data)
      [first, second] = records

      # Replace second chunk body with wrong-size data
      tampered = %{second | body: "short"}

      assembler = Framing.Assembler.new()
      {:incomplete, assembler} = Framing.Assembler.add(assembler, to_sequenced(first, 0))

      assert {:error, {:frame_size_mismatch, _}} =
               Framing.Assembler.add(assembler, to_sequenced(tampered, 1))
    end

    test "multiple messages in sequence" do
      assembler = Framing.Assembler.new()

      # First message
      [r1] = Framing.frame("first")
      {:ok, "first", assembler} = Framing.Assembler.add(assembler, to_sequenced(r1, 0))

      # Second message
      [r2] = Framing.frame("second")
      {:ok, "second", _assembler} = Framing.Assembler.add(assembler, to_sequenced(r2, 1))
    end
  end

  defp find_header(record, name) do
    Enum.find(record.headers, fn h -> h.name == name end)
  end

  defp decode_u64(<<value::unsigned-big-64>>), do: value

  defp to_sequenced(append_record, seq_num) do
    %S2.V1.SequencedRecord{
      seq_num: seq_num,
      timestamp: 0,
      headers: append_record.headers,
      body: append_record.body
    }
  end
end

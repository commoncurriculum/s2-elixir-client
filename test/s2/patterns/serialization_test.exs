defmodule S2.Patterns.SerializationTest do
  use ExUnit.Case, async: true

  alias S2.Patterns.Serialization
  alias S2.Patterns.Chunking

  @json_serializer %{
    serialize: &Jason.encode!/1,
    deserialize: &Jason.decode!/1
  }

  describe "prepare/3 (serialize → chunk → frame → dedupe → AppendInput)" do
    test "small message produces single record with dedupe headers" do
      writer = Serialization.writer()
      message = %{"event" => "signup", "user" => "alice"}

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)

      assert %S2.V1.AppendInput{records: records} = input
      assert length(records) == 1

      [record] = records
      assert Jason.decode!(record.body) == message
      # Has dedupe headers
      assert has_header?(record, "_writer_id")
      assert has_header?(record, "_dedupe_seq")
    end

    test "large message produces multiple records with framing + dedupe headers" do
      writer = Serialization.writer()
      max = Chunking.max_chunk_bytes()
      # Create a message whose serialized form exceeds max chunk size
      big_value = String.duplicate("x", max + 100)
      message = %{"data" => big_value}

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)

      records = input.records
      assert length(records) > 1

      # First record has framing headers + dedupe headers
      first = hd(records)
      assert has_header?(first, "_frame_bytes")
      assert has_header?(first, "_frame_records")
      assert has_header?(first, "_writer_id")
      assert has_header?(first, "_dedupe_seq")

      # Continuation records have dedupe headers but no framing headers
      for record <- tl(records) do
        refute has_header?(record, "_frame_bytes")
        assert has_header?(record, "_writer_id")
      end
    end

    test "multiple prepares increment dedupe seq" do
      writer = Serialization.writer()

      {input1, writer} = Serialization.prepare(writer, "first", @json_serializer)
      {input2, _writer} = Serialization.prepare(writer, "second", @json_serializer)

      seq1 = get_dedupe_seq(hd(input1.records))
      seq2 = get_dedupe_seq(hd(input2.records))
      assert seq2 > seq1
    end
  end

  describe "decode/3 (dedupe → reassemble → deserialize)" do
    test "round-trip small message" do
      writer = Serialization.writer()
      message = %{"hello" => "world"}
      reader = Serialization.reader()

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)
      sequenced = to_sequenced_records(input.records, 0)

      {messages, _reader} = Serialization.decode(reader, sequenced, @json_serializer)
      assert messages == [message]
    end

    test "round-trip large chunked message" do
      writer = Serialization.writer()
      max = Chunking.max_chunk_bytes()
      big_value = String.duplicate("z", max + 500)
      message = %{"big" => big_value}
      reader = Serialization.reader()

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)
      sequenced = to_sequenced_records(input.records, 0)

      {messages, _reader} = Serialization.decode(reader, sequenced, @json_serializer)
      assert messages == [message]
    end

    test "round-trip multiple messages in sequence" do
      writer = Serialization.writer()
      reader = Serialization.reader()

      messages = [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]

      {all_records, _writer} =
        Enum.flat_map_reduce(messages, writer, fn msg, w ->
          {input, w} = Serialization.prepare(w, msg, @json_serializer)
          {input.records, w}
        end)

      sequenced = to_sequenced_records(all_records, 0)

      {decoded, _reader} = Serialization.decode(reader, sequenced, @json_serializer)
      assert decoded == messages
    end

    test "duplicates are filtered out" do
      writer = Serialization.writer()
      reader = Serialization.reader()
      message = %{"event" => "click"}

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)
      sequenced = to_sequenced_records(input.records, 0)

      # Feed the same records twice (simulating a retry)
      {msgs1, reader} = Serialization.decode(reader, sequenced, @json_serializer)
      {msgs2, _reader} = Serialization.decode(reader, sequenced, @json_serializer)

      assert msgs1 == [message]
      assert msgs2 == []
    end

    test "deserialization error returns error tuple in results" do
      reader = Serialization.reader()

      # Create a sequenced record with invalid JSON body but valid framing
      # (single-record frame = no framing headers needed, just a raw body)
      bad_record = %S2.V1.SequencedRecord{
        seq_num: 0,
        timestamp: 0,
        headers: [],
        body: "not valid json{"
      }

      {results, _reader} = Serialization.decode(reader, [bad_record], @json_serializer)
      assert length(results) == 1
      assert {:error, {:deserialization_error, %Jason.DecodeError{}}} = hd(results)
    end

    test "assembly error returns error tuple when unexpected record arrives" do
      reader = Serialization.reader()
      max = Chunking.max_chunk_bytes()

      # Create two multi-chunk messages
      data1 = :crypto.strong_rand_bytes(max + 100)
      records1 = S2.Patterns.RecordFraming.frame(data1)
      data2 = :crypto.strong_rand_bytes(max + 100)
      records2 = S2.Patterns.RecordFraming.frame(data2)

      # Feed first chunk of msg1, then first chunk of msg2 (unexpected new frame start)
      seq_records = [
        to_sequenced_records([hd(records1)], 0),
        to_sequenced_records([hd(records2)], 1)
      ] |> List.flatten()

      {results, _reader} = Serialization.decode(reader, seq_records, @json_serializer)
      assert Enum.any?(results, &match?({:error, {:assembly_error, :unexpected_record}}, &1))
    end

    test "incomplete chunked message returns nothing until complete" do
      writer = Serialization.writer()
      reader = Serialization.reader()
      max = Chunking.max_chunk_bytes()
      message = %{"big" => String.duplicate("a", max + 100)}

      {input, _writer} = Serialization.prepare(writer, message, @json_serializer)
      [first | rest] = input.records

      # Feed just the first chunk
      first_seq = to_sequenced_records([first], 0)
      {messages, reader} = Serialization.decode(reader, first_seq, @json_serializer)
      assert messages == []

      # Feed remaining chunks
      rest_seq = to_sequenced_records(rest, 1)
      {messages, _reader} = Serialization.decode(reader, rest_seq, @json_serializer)
      assert messages == [message]
    end
  end

  defp has_header?(record, name) do
    Enum.any?(record.headers, fn h -> h.name == name end)
  end

  defp get_dedupe_seq(record) do
    header = Enum.find(record.headers, fn h -> h.name == "_dedupe_seq" end)
    <<seq::unsigned-big-64>> = header.value
    seq
  end

  defp to_sequenced_records(append_records, start_seq) do
    append_records
    |> Enum.with_index(start_seq)
    |> Enum.map(fn {record, seq} ->
      %S2.V1.SequencedRecord{
        seq_num: seq,
        timestamp: 0,
        headers: record.headers,
        body: record.body
      }
    end)
  end
end

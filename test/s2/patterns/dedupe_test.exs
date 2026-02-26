defmodule S2.Patterns.DedupeTest do
  use ExUnit.Case, async: true

  alias S2.Patterns.Dedupe
  alias S2.Patterns.Constants

  describe "Writer (inject headers)" do
    test "new writer has a random ID" do
      w1 = Dedupe.Writer.new()
      w2 = Dedupe.Writer.new()
      assert w1.writer_id != w2.writer_id
      assert byte_size(w1.writer_id) > 0
    end

    test "stamp/2 injects _writer_id and _dedupe_seq headers" do
      writer = Dedupe.Writer.new()
      record = %S2.V1.AppendRecord{headers: [], body: "hello"}

      {stamped, _writer} = Dedupe.Writer.stamp(writer, record)

      assert find_header(stamped, Constants.writer_id()) != nil
      assert find_header(stamped, Constants.dedupe_seq()) != nil
    end

    test "stamp/2 increments seq monotonically" do
      writer = Dedupe.Writer.new()
      record = %S2.V1.AppendRecord{headers: [], body: "x"}

      {r1, writer} = Dedupe.Writer.stamp(writer, record)
      {r2, writer} = Dedupe.Writer.stamp(writer, record)
      {r3, _writer} = Dedupe.Writer.stamp(writer, record)

      assert get_dedupe_seq(r1) == 0
      assert get_dedupe_seq(r2) == 1
      assert get_dedupe_seq(r3) == 2
    end

    test "stamp/2 preserves existing headers" do
      writer = Dedupe.Writer.new()
      existing = %S2.V1.Header{name: "my-header", value: "my-value"}
      record = %S2.V1.AppendRecord{headers: [existing], body: "hello"}

      {stamped, _writer} = Dedupe.Writer.stamp(writer, record)
      assert Enum.any?(stamped.headers, fn h -> h.name == "my-header" end)
    end

    test "stamp_records/2 stamps a list of records" do
      writer = Dedupe.Writer.new()
      records = for i <- 0..2, do: %S2.V1.AppendRecord{headers: [], body: "msg-#{i}"}

      {stamped, _writer} = Dedupe.Writer.stamp_records(writer, records)
      assert length(stamped) == 3
      seqs = Enum.map(stamped, &get_dedupe_seq/1)
      assert seqs == [0, 1, 2]
    end
  end

  describe "Filter (deduplicate reads)" do
    test "first record from a writer is accepted" do
      filter = Dedupe.Filter.new()
      record = make_sequenced("writer-1", 0, "hello")

      assert {:ok, filter} = Dedupe.Filter.check(filter, record)
      refute filter == Dedupe.Filter.new()
    end

    test "duplicate seq from same writer is rejected" do
      filter = Dedupe.Filter.new()
      r1 = make_sequenced("writer-1", 0, "hello")
      r2 = make_sequenced("writer-1", 0, "hello")

      {:ok, filter} = Dedupe.Filter.check(filter, r1)
      assert :duplicate = Dedupe.Filter.check(filter, r2)
    end

    test "lower seq from same writer is rejected" do
      filter = Dedupe.Filter.new()
      r1 = make_sequenced("writer-1", 5, "hello")
      r2 = make_sequenced("writer-1", 3, "old")

      {:ok, filter} = Dedupe.Filter.check(filter, r1)
      assert :duplicate = Dedupe.Filter.check(filter, r2)
    end

    test "higher seq from same writer is accepted" do
      filter = Dedupe.Filter.new()
      r1 = make_sequenced("writer-1", 0, "first")
      r2 = make_sequenced("writer-1", 1, "second")

      {:ok, filter} = Dedupe.Filter.check(filter, r1)
      assert {:ok, _filter} = Dedupe.Filter.check(filter, r2)
    end

    test "different writers are tracked independently" do
      filter = Dedupe.Filter.new()
      r1 = make_sequenced("writer-1", 0, "from-1")
      r2 = make_sequenced("writer-2", 0, "from-2")

      {:ok, filter} = Dedupe.Filter.check(filter, r1)
      assert {:ok, _filter} = Dedupe.Filter.check(filter, r2)
    end

    test "records without dedupe headers are always accepted" do
      filter = Dedupe.Filter.new()
      record = %S2.V1.SequencedRecord{seq_num: 0, timestamp: 0, headers: [], body: "plain"}

      assert {:ok, filter} = Dedupe.Filter.check(filter, record)
      # Same record again — still accepted (no dedupe tracking)
      assert {:ok, _filter} = Dedupe.Filter.check(filter, record)
    end

    test "evicts oldest writer when max capacity is exceeded" do
      filter = Dedupe.Filter.new()

      # Add max_writers unique writers (we can't test the exact number without
      # exposing the constant, but we can verify the mechanism works by adding
      # enough writers that the oldest gets evicted, then check that a
      # previously-seen record from the oldest writer is no longer duplicate)
      # The internal limit is 10_000 — test with a smaller proxy by filling
      # up and checking eviction behavior
      writer_ids = for i <- 1..10_001, do: "writer-#{i}"

      filter =
        Enum.reduce(writer_ids, filter, fn wid, f ->
          record = make_sequenced(wid, 0, "data")
          {:ok, f} = Dedupe.Filter.check(f, record)
          f
        end)

      # writer-1 should have been evicted, so seq 0 is accepted again (not :duplicate)
      record = make_sequenced("writer-1", 0, "replay")
      assert {:ok, _filter} = Dedupe.Filter.check(filter, record)
    end

    test "new writer ID resets tracking (crash recovery)" do
      filter = Dedupe.Filter.new()
      r1 = make_sequenced("writer-v1", 10, "before-crash")
      r2 = make_sequenced("writer-v2", 0, "after-restart")

      {:ok, filter} = Dedupe.Filter.check(filter, r1)
      # New writer starts at 0 — should be accepted
      assert {:ok, _filter} = Dedupe.Filter.check(filter, r2)
    end
  end

  defp find_header(record, name) do
    Enum.find(record.headers, fn h -> h.name == name end)
  end

  defp get_dedupe_seq(record) do
    header = find_header(record, Constants.dedupe_seq())
    <<seq::unsigned-big-64>> = header.value
    seq
  end

  defp make_sequenced(writer_id, seq, body) do
    %S2.V1.SequencedRecord{
      seq_num: 0,
      timestamp: 0,
      headers: [
        %S2.V1.Header{name: Constants.writer_id(), value: writer_id},
        %S2.V1.Header{name: Constants.dedupe_seq(), value: <<seq::unsigned-big-64>>}
      ],
      body: body
    }
  end
end

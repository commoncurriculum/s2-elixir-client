defmodule S2.AppendStreamTest do
  use ExUnit.Case, async: true

  alias S2.AppendStream

  defp records(count, size \\ 1),
    do: Enum.map(1..count, fn _number -> %S2.V1.AppendRecord{body: :binary.copy("x", size)} end)

  defp push!(stream, from, records, deadline \\ 1_000) do
    {:ok, stream} = AppendStream.push(stream, from, records, deadline)
    stream
  end

  defp decoded(frame) do
    {:ok, %{body: body}, ""} = S2.Framing.decode(frame)
    {:ok, input} = Protox.decode(body, S2.V1.AppendInput)
    length(input.records)
  end

  defp ack(start, count),
    do: %S2.V1.AppendAck{
      start: %S2.V1.StreamPosition{seq_num: start, timestamp: 7},
      end: %S2.V1.StreamPosition{seq_num: start + count, timestamp: 8},
      tail: %S2.V1.StreamPosition{seq_num: start + count, timestamp: 8}
    }

  test "batches while one is in flight, sends full batches anyway, never splits a call, and gives each call its own range" do
    # Nothing in flight: the first call goes at once, alone.
    stream = push!(AppendStream.new(), :a, records(2))
    {[frame], stream} = AppendStream.take(stream, 0)
    assert decoded(frame) == 2

    # While it's in flight, calls collect.
    stream = stream |> push!(:b, records(3)) |> push!(:c, records(4))
    assert {[], stream} = AppendStream.take(stream, 0)

    # Its ack frees the next batch, with both calls.
    assert {[{:a, a}], stream} = AppendStream.ack(stream, ack(10, 2))
    assert {a.start.seq_num, a.end.seq_num} == {10, 12}
    {[frame], stream} = AppendStream.take(stream, 0)
    assert decoded(frame) == 7
    assert {[{:b, b}, {:c, c}], stream} = AppendStream.ack(stream, ack(12, 7))
    assert {b.start.seq_num, b.end.seq_num, c.start.seq_num, c.end.seq_num} == {12, 15, 15, 19}
    assert c.tail.seq_num == 19
    assert AppendStream.idle?(stream)

    # A queue holding more than a batch sends the full one even while one is
    # out, splitting between calls, not inside one.
    stream = push!(stream, :d, records(1))
    {[_frame], stream} = AppendStream.take(stream, 0)
    stream = stream |> push!(:e, records(600)) |> push!(:f, records(600)) |> push!(:g, records(1))
    {[frame], stream} = AppendStream.take(stream, 0)
    assert decoded(frame) == 600
    {[], _stream} = AppendStream.take(stream, 0)

    # Byte limits split the same way: two 600 KiB calls don't share a batch.
    stream = push!(AppendStream.new(), :h, records(1, 600 * 1024))
    stream = push!(stream, :i, records(1, 600 * 1024))
    {[frame], _stream} = AppendStream.take(stream, 0)
    assert decoded(frame) == 1
  end

  test "a failed session resends the same bytes first, a refusal fails only the oldest batch, and expired or oversized calls never go out" do
    stream = push!(AppendStream.new(), :a, records(1))
    {[first], stream} = AppendStream.take(stream, 0)
    stream = push!(stream, :b, records(1))
    {[], stream} = AppendStream.take(stream, 0)

    # A full queue goes out behind the first batch.
    stream = push!(stream, :c, records(1000))
    {[second, third], stream} = AppendStream.take(stream, 0)
    assert {decoded(second), decoded(third)} == {1, 1000}

    # The session fails: the three batches go again, unchanged and in order.
    stream = AppendStream.requeue(stream)
    refute AppendStream.sent?(stream)
    assert {[^first, ^second, ^third], stream} = AppendStream.take(stream, 0)

    # S2 refuses the oldest for good; the others go again.
    assert {[:a], stream} = AppendStream.refuse(stream)
    assert {[^second, ^third], stream} = AppendStream.take(stream, 0)

    # A call whose caller has given up is dropped unsent.
    stream = %{stream | sent: :queue.new(), sent_bytes: 0} |> push!(:d, records(1), 5)
    assert {[], stream} = AppendStream.take(stream, 5)
    assert AppendStream.idle?(stream)

    assert AppendStream.push(stream, :e, records(1001), 10) == {:error, :batch_too_large}

    assert AppendStream.push(stream, :e, records(1, 1024 * 1024), 10) ==
             {:error, :batch_too_large}

    assert AppendStream.push(stream, :e, [], 10) == {:error, :no_records}
  end

  test "nothing new goes out while max_sent_bytes are unacknowledged" do
    stream = push!(AppendStream.new(), :a, records(1, 1000))
    {[_frame], stream} = AppendStream.take(stream, 0, 1_500)
    stream = push!(stream, :b, records(1000, 1))
    assert {[], stream} = AppendStream.take(stream, 0, 1_500)
    {[{:a, _ack}], stream} = AppendStream.ack(stream, ack(0, 1))
    assert {[_frame], _stream} = AppendStream.take(stream, 0, 1_500)
  end
end

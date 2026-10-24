defmodule S2.DataPlaneTest do
  use S2.DataPlaneCase, async: false

  setup %{basin: basin} do
    %{name: start_client(basin, pool_size: 2, idle_after: 200)}
  end

  test "append, read, check_tail and listen round trip, and an idle append session closes", %{
    name: name
  } do
    stream = unique_stream_name()

    assert {:ok, ack} = S2.append(name, stream, [record("a"), record("b")])
    assert {ack.start.seq_num, ack.end.seq_num} == {0, 2}
    assert {:ok, %S2.V1.StreamPosition{seq_num: 2}} = S2.check_tail(name, stream)
    assert {:ok, batch} = S2.read(name, stream, seq_num: 1, count: 10)
    assert bodies(batch.records) == ["b"]

    {:ok, listener} = S2.listen(name, stream)
    assert bodies(listened(listener, 2)) == ["a", "b"]
    {:ok, _ack} = S2.append(name, stream, [record("c")])
    assert [%{seq_num: 2, body: "c"}] = listened(listener, 1)

    {:ok, tail_listener} = S2.listen(name, stream, from: :tail)
    {:ok, _ack} = S2.append(name, stream, [record("d")])
    assert [%{body: "d"}] = listened(tail_listener, 1)
    assert [%{body: "d"}] = listened(listener, 1)

    assert :ok = S2.stop_listener(name, stream, tail_listener)
    assert {:error, :not_found} = S2.stop_listener(name, stream, tail_listener)

    # With nothing to send for idle_after, the append session is gone.
    Process.sleep(400)
    assert :sys.get_state(connection(name, stream)).appends == %{}
    {:ok, ack} = S2.append(name, stream, [record("e")])
    assert ack.start.seq_num == 4
  end

  test "concurrent appends to one stream are batched, and each caller gets its own range in order",
       %{name: name} do
    stream = unique_stream_name()

    acks =
      1..300
      |> Task.async_stream(
        fn number ->
          {:ok, ack} = S2.append(name, stream, [record("#{number}.1"), record("#{number}.2")])
          {number, ack}
        end,
        max_concurrency: 300
      )
      |> Enum.map(fn {:ok, result} -> result end)

    ranges = Enum.map(acks, fn {_number, ack} -> {ack.start.seq_num, ack.end.seq_num} end)
    assert Enum.sort(ranges) == Enum.map(0..299, &{2 * &1, 2 * &1 + 2})

    # Calls in one batch share its tail; far fewer batches than calls.
    batches = acks |> Enum.map(fn {_number, ack} -> ack.tail.seq_num end) |> Enum.uniq()
    assert length(batches) < 100

    # Each caller's records sit at its own range, together and in order.
    {:ok, listener} = S2.listen(name, stream, from: 0)
    records = listened(listener, 600)

    Enum.each(acks, fn {number, ack} ->
      assert records |> Enum.slice(ack.start.seq_num, 2) |> bodies() ==
               ["#{number}.1", "#{number}.2"]
    end)
  end

  test "batches far over HTTP/2's flow control window go out as the window opens, on many streams at once",
       %{name: name} do
    body = :binary.copy("x", 900 * 1024)

    results =
      1..4
      |> Enum.map(&"#{unique_stream_name()}-#{&1}")
      |> Task.async_stream(
        fn stream ->
          Enum.map(1..5, fn _number ->
            S2.append(name, stream, [record(body)], timeout: 30_000)
          end)
        end,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, results} -> results end)

    assert length(results) == 20
    assert Enum.all?(results, &match?({:ok, _ack}, &1))
  end

  test "records over a batch are refused, S2 refusing a call answers at once, and a listener on a refused read gets the error",
       %{name: name, basin: basin} do
    stream = unique_stream_name()

    assert {:error, :batch_too_large} =
             S2.append(name, stream, [record(:binary.copy("x", 1_048_577))])

    assert {:error, :no_records} = S2.append(name, stream, [])

    other = start_client(basin <> "-missing", pool_size: 1)
    assert {:error, %S2.Error{status: status}} = S2.append(other, stream, [record("a")])
    assert status in [403, 404]

    {:ok, listener} = S2.listen(other, stream, from: 0)
    assert_receive {S2, ^listener, {:error, %S2.Error{status: status}}}, 5_000
    assert status in [403, 404]
  end

  test "reads and listeners past the tail or on a missing stream get S2's refusal, and a read at the tail waits and comes back empty",
       %{name: name} do
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("a")])

    assert {:error, %S2.Error{status: 416}} = S2.read(name, stream, seq_num: 5)

    assert {:error, %S2.Error{status: 404, code: "stream_not_found"}} =
             S2.read(name, unique_stream_name())

    assert {:error, %S2.Error{status: 404}} = S2.check_tail(name, unique_stream_name())

    {microseconds, {:ok, batch}} = :timer.tc(fn -> S2.read(name, stream, seq_num: 1, wait: 1) end)
    assert batch.records == []
    assert microseconds >= 900_000

    {:ok, listener} = S2.listen(name, stream, from: 5)
    assert_receive {S2, ^listener, {:error, %S2.Error{status: 416}}}, 5_000
    refute Map.has_key?(:sys.get_state(connection(name, stream)).listeners, listener)

    # A listener ends with the process that listens.
    Task.await(Task.async(fn -> S2.listen(name, stream, from: 0) end))
    assert :sys.get_state(connection(name, stream)).listeners == %{}
  end

  test "deleting a followed stream ends its read session, which reopens and then ends the listener with 404; an append makes the stream again",
       %{name: name, basin: basin} do
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("a")])
    {:ok, listener} = S2.listen(name, stream, from: 0)
    assert [%{body: "a"}] = listened(listener, 1)

    log =
      capture_log(fn ->
        :ok = S2.Streams.delete_stream(stream, server: test_client(), basin: basin)
        # S2 may first deliver the trim command record the deletion wrote.
        assert_receive {S2, ^listener, {:error, %S2.Error{status: 404}}}, 10_000
        refute Map.has_key?(:sys.get_state(connection(name, stream)).listeners, listener)

        # The append session open before the deletion may fail and retry.
        assert {:ok, %{start: %{seq_num: 0}}} =
                 S2.append(name, stream, [record("b")], timeout: 15_000)
      end)

    assert log =~ "S2 read session on #{stream} ended, reopening in 100 ms"
  end

  test "a read session's heartbeats keep it open", %{name: name} do
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("a")])
    {:ok, listener} = S2.listen(name, stream, from: 1)

    log = capture_log(fn -> refute_receive {S2, ^listener, _message}, 17_000 end)
    refute log =~ "S2"
    {:ok, _ack} = S2.append(name, stream, [record("b")])
    assert [%{seq_num: 1, body: "b"}] = listened(listener, 1)
  end
end

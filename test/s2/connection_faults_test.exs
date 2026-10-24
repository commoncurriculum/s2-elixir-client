defmodule S2.ConnectionFaultsTest do
  use S2.DataPlaneCase, async: false

  alias S2.ProxyHelper

  @moduletag :proxy

  setup do
    endpoint = ProxyHelper.setup_proxy!()
    on_exit(&ProxyHelper.remove_all_toxics!/0)
    %{endpoint: endpoint}
  end

  # A resent batch may be in the stream twice, but a listener reads on from
  # after its last record, so it gets each copy once, in stream order.
  defp assert_each_once_in_order(records, count) do
    assert records |> bodies() |> Enum.uniq() == Enum.map(1..count, &"#{&1}")
    assert Enum.map(records, & &1.seq_num) == Enum.to_list(1..length(records))
  end

  defp listened_all(listener, count) do
    records = listened(listener, count)
    records ++ listened(listener, length(records) - length(Enum.uniq_by(records, & &1.body)))
  end

  test "a reset connection resends unacknowledged appends and reopens listeners after the last record",
       %{basin: basin, endpoint: endpoint} do
    name = start_client(basin, basin_endpoint: endpoint, pool_size: 1)
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("0")])
    {:ok, listener} = S2.listen(name, stream, from: 0)
    assert [%{body: "0"}] = listened(listener, 1)

    writer =
      Task.async(fn ->
        Enum.map(1..200, fn number -> S2.append(name, stream, [record("#{number}")]) end)
      end)

    log =
      capture_log(fn ->
        Process.sleep(100)
        ProxyHelper.add_toxic!(:reset_peer, timeout: 0)
        Process.sleep(300)
        ProxyHelper.remove_all_toxics!()
        assert Enum.all?(Task.await(writer, 30_000), &match?({:ok, _ack}, &1))
      end)

    assert log =~ "S2 connection lost"
    assert_each_once_in_order(listened_all(listener, 200), 200)
  end

  test "a connection that goes silent is dropped after heartbeat_deadline, and appends and listeners carry on over a new one",
       %{basin: basin, endpoint: endpoint} do
    name = start_client(basin, basin_endpoint: endpoint, pool_size: 1, heartbeat_deadline: 1_000)
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("0")])
    {:ok, listener} = S2.listen(name, stream, from: 0)
    assert [%{body: "0"}] = listened(listener, 1)
    before = :sys.get_state(connection(name, stream)).conn

    log =
      capture_log(fn ->
        # Bytes go in, nothing comes back, and nothing closes.
        ProxyHelper.add_toxic!(:timeout, timeout: 0)

        # A caller whose timeout passes first gets :timeout; its record may
        # still be appended once the connection is back.
        assert {:error, :timeout} =
                 S2.append(name, unique_stream_name(), [record("late")], timeout: 200)

        writer =
          Task.async(fn ->
            Enum.map(1..20, fn number ->
              S2.append(name, stream, [record("#{number}")], timeout: 15_000)
            end)
          end)

        Process.sleep(2_500)
        ProxyHelper.remove_all_toxics!()
        assert Enum.all?(Task.await(writer, 20_000), &match?({:ok, _ack}, &1))
      end)

    assert log =~ "S2 connection lost, reconnecting: :silent"
    refute :sys.get_state(connection(name, stream)).conn.socket == before.socket
    assert_each_once_in_order(listened_all(listener, 20), 20)
  end

  test "while S2 is unreachable, unary calls fail at once, appends wait for the connection, and a call cut off by a drop fails",
       %{basin: basin, endpoint: endpoint} do
    stream = unique_stream_name()

    log =
      capture_log(fn ->
        ProxyHelper.enable!(false)
        name = start_client(basin, basin_endpoint: endpoint, pool_size: 1)

        assert {:error, %S2.Error{message: "not connected to S2"}} = S2.check_tail(name, stream)
        writer = Task.async(fn -> S2.append(name, stream, [record("a")], timeout: 10_000) end)
        Process.sleep(500)
        ProxyHelper.enable!(true)
        assert {:ok, %{start: %{seq_num: 0}}} = Task.await(writer, 15_000)

        # A long-poll read is in flight when the connection drops.
        reader =
          Task.async(fn -> S2.read(name, stream, seq_num: 1, wait: 10, timeout: 15_000) end)

        Process.sleep(300)
        ProxyHelper.add_toxic!(:reset_peer, timeout: 0)
        assert {:error, %S2.Error{}} = Task.await(reader, 15_000)
        ProxyHelper.remove_all_toxics!()
        assert {:ok, %{start: %{seq_num: 1}}} = S2.append(name, stream, [record("b")])
      end)

    assert log =~ "connecting to S2 failed, retrying in 100 ms"
    assert log =~ "S2 connection lost"
  end

  test "with latency, concurrent appends still batch and pipeline, and every caller gets its own range",
       %{basin: basin, endpoint: endpoint} do
    name = start_client(basin, basin_endpoint: endpoint, pool_size: 1)
    stream = unique_stream_name()
    {:ok, _ack} = S2.append(name, stream, [record("warm")])
    ProxyHelper.add_toxic!(:latency, latency: 100)

    {microseconds, acks} =
      :timer.tc(fn ->
        1..200
        |> Task.async_stream(fn number -> S2.append(name, stream, [record("#{number}")]) end,
          max_concurrency: 200
        )
        |> Enum.map(fn {:ok, {:ok, ack}} -> ack end)
      end)

    assert acks |> Enum.map(& &1.start.seq_num) |> Enum.sort() == Enum.to_list(1..200)
    # One at a time this would take 200 round trips.
    assert microseconds < 5_000_000
  end
end

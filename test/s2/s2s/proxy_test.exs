defmodule S2.S2S.ProxyTest do
  @moduledoc """
  Tests that use Toxiproxy to simulate network conditions.
  Covers receive loop internals (continue/timeout) and error paths
  that are impossible to trigger with localhost s2-lite.
  """
  use ExUnit.Case
  import S2.TestHelpers

  @moduletag :proxy

  setup_all do
    port = S2.ProxyHelper.setup_proxy!()
    %{proxy_port: port}
  end

  setup %{proxy_port: proxy_port} do
    client = test_client()
    basin = unique_basin_name("proxy")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    # Append records via direct connection (not proxy)
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

    input = %S2.V1.AppendInput{
      records: [
        %S2.V1.AppendRecord{body: "proxy-test-0"},
        %S2.V1.AppendRecord{body: "proxy-test-1"}
      ]
    }

    {:ok, _ack, _conn} = S2.S2S.Append.call(conn, basin, stream, input)

    on_exit(fn ->
      S2.ProxyHelper.remove_all_toxics!()
      cleanup_basin(client, basin)
    end)

    %{basin: basin, stream: stream, proxy_port: proxy_port}
  end

  describe "slicer toxic (fragmented responses → receive loop :continue)" do
    test "Read.call succeeds with fragmented TCP data", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)

      result = S2.S2S.Read.call(conn, basin, stream, seq_num: 0, recv_timeout: 10_000)

      assert {:ok, %S2.V1.ReadBatch{} = batch, _conn} = result
      assert length(batch.records) > 0
    end

    test "AppendSession.append succeeds with fragmented ack", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream, recv_timeout: 10_000)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "sliced"}]}

      assert {:ok, %S2.V1.AppendAck{}, _session} =
               S2.S2S.AppendSession.append(session, input)
    end

    test "Append.call succeeds with fragmented ack", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)
      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "sliced-unary"}]}

      assert {:ok, %S2.V1.AppendAck{}, _conn} =
               S2.S2S.Append.call(conn, basin, stream, input, recv_timeout: 10_000)
    end

    test "CheckTail.call succeeds with fragmented response", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)

      assert {:ok, %S2.V1.StreamPosition{}, _conn} =
               S2.S2S.CheckTail.call(conn, basin, stream, recv_timeout: 10_000)
    end

    test "ReadSession.next_batch succeeds with fragmented data", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0, recv_timeout: 10_000)

      assert {:ok, %S2.V1.ReadBatch{}, _session} =
               S2.S2S.ReadSession.next_batch(session)
    end

    test "AppendSession close drains fragmented final response", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      S2.ProxyHelper.add_toxic!(:slicer, :downstream,
        average_size: 1,
        size_variation: 0,
        delay: 1
      )

      conn = S2.ProxyHelper.open_conn!(proxy_port)
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream, recv_timeout: 10_000)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "drain-slicer"}]}
      {:ok, _ack, session} = S2.S2S.AppendSession.append(session, input)

      assert {:ok, _session} = S2.S2S.AppendSession.close(session)
    end
  end

  describe "latency toxic (slow responses → timeout)" do
    test "Read.call times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      # Open connection BEFORE toxic so HTTP/2 handshake completes cleanly
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      assert {:error, :timeout, _conn} =
               S2.S2S.Read.call(conn, basin, stream, seq_num: 0, recv_timeout: 100)
    end

    test "Append.call times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "timeout"}]}

      assert {:error, :timeout, _conn} =
               S2.S2S.Append.call(conn, basin, stream, input, recv_timeout: 100)
    end

    test "AppendSession.open times out (wait_for_headers timeout)", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      assert {:error, :timeout, _conn} =
               S2.S2S.AppendSession.open(conn, basin, stream, recv_timeout: 100)
    end

    test "ReadSession.open times out (wait_for_headers timeout)", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      assert {:error, :timeout, _conn} =
               S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0, recv_timeout: 100)
    end

    test "CheckTail.call times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      assert {:error, :timeout, _conn} =
               S2.S2S.CheckTail.call(conn, basin, stream, recv_timeout: 100)
    end

    test "AppendSession.append ack times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      # Open session BEFORE toxic so headers arrive normally
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream, recv_timeout: 100)

      # Now add latency so the ACK response is delayed
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "ack-timeout"}]}

      assert {:error, :timeout, _session} =
               S2.S2S.AppendSession.append(session, input)
    end

    test "AppendSession.close drain times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      # Open session and append successfully first
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream, recv_timeout: 100)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "drain-test"}]}
      {:ok, _ack, session} = S2.S2S.AppendSession.append(session, input)

      # Add latency so the drain response is delayed
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      # Close should still return {:ok, session} even if drain times out
      assert {:ok, _session} = S2.S2S.AppendSession.close(session)
    end

    test "ReadSession.next_batch times out", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      # Open session before toxic
      conn = S2.ProxyHelper.open_conn_ready!(proxy_port)

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0, recv_timeout: 100)

      # Read first batch normally
      {:ok, _batch, session} = S2.S2S.ReadSession.next_batch(session)

      # Add latency so subsequent data is delayed
      S2.ProxyHelper.add_toxic!(:latency, :downstream, latency: 5_000)

      # Next batch should timeout (waiting for more data from server)
      assert {:error, :timeout, _session} = S2.S2S.ReadSession.next_batch(session)
    end
  end

  describe "limit_data toxic (connection cut mid-stream)" do
    test "ReadSession.next_batch returns error when connection cut", %{
      basin: basin,
      stream: stream,
      proxy_port: proxy_port
    } do
      # Allow just enough data for the handshake, then cut
      S2.ProxyHelper.add_toxic!(:limit_data, :downstream, bytes: 100)

      conn = S2.ProxyHelper.open_conn!(proxy_port)

      result = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0, recv_timeout: 5_000)

      # Either fails to open or opens but next_batch fails
      case result do
        {:error, _reason, _conn} ->
          :ok

        {:ok, session} ->
          result = S2.S2S.ReadSession.next_batch(session)
          assert {:error, _reason, _session} = result
      end
    end
  end

  describe "proxy down (connection refused)" do
    test "Connection.open fails when proxy is down", %{proxy_port: proxy_port} do
      proxy = S2.ProxyHelper.proxy!()

      ToxiproxyEx.down!(proxy, fn ->
        assert {:error, _} = S2.S2S.Connection.open("http://localhost:#{proxy_port}")
      end)
    end
  end
end

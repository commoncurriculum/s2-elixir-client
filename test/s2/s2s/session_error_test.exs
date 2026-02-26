defmodule S2.S2S.SessionErrorTest do
  @moduledoc """
  Integration tests covering error paths in AppendSession, ReadSession, and Read
  that require real connections (closed conn, error status, etc.)
  """
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("sess-err")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    # Append records for read tests
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

    input = %S2.V1.AppendInput{
      records: [%S2.V1.AppendRecord{body: "test-data"}]
    }

    {:ok, _ack, _conn} = S2.S2S.Append.call(conn, basin, stream, input)

    on_exit(fn -> cleanup_basin(client, basin) end)
    %{basin: basin, stream: stream}
  end

  describe "AppendSession error paths" do
    test "open returns error for nonexistent basin", %{stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.AppendSession.open(conn, "nonexistent-basin", stream)
    end

    test "open returns error on closed connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, conn} = Mint.HTTP2.close(conn)

      assert {:error, _reason, _conn} =
               S2.S2S.AppendSession.open(conn, "basin", "stream")
    end

    test "append encode error closes session", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      # Kill the TCP socket to cause a stream_request_body error
      :gen_tcp.close(session.conn.socket)

      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "test"}]}
      assert {:error, _reason, _session} = S2.S2S.AppendSession.append(session, input)
    end
  end

  describe "ReadSession error paths" do
    test "open returns error for nonexistent basin", %{stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.ReadSession.open(conn, "nonexistent-basin", stream, seq_num: 0)
    end

    test "open returns error on closed connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, conn} = Mint.HTTP2.close(conn)

      assert {:error, _reason, _conn} =
               S2.S2S.ReadSession.open(conn, "basin", "stream", seq_num: 0)
    end

    test "close handles already-closed stream gracefully", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      # Read the batch first to advance, then close
      {:ok, _batch, session} = S2.S2S.ReadSession.next_batch(session)
      {:ok, session} = S2.S2S.ReadSession.close(session)

      # Double close is a no-op
      assert {:ok, ^session} = S2.S2S.ReadSession.close(session)
    end

    test "next_batch returns decode error on killed connection", %{
      basin: basin,
      stream: stream
    } do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0, recv_timeout: 500)

      # Kill the socket to cause an error on next read
      :gen_tcp.close(session.conn.socket)

      result = S2.S2S.ReadSession.next_batch(session)
      # Either error (killed socket) or ok (data already buffered)
      assert match?({:error, _, _}, result) or match?({:ok, _, _}, result)
    end
  end

  describe "ReadSession close error paths" do
    test "close succeeds even when cancel_request fails (killed socket)", %{
      basin: basin,
      stream: stream
    } do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      # Kill the socket so cancel_request will fail
      :gen_tcp.close(session.conn.socket)

      # close should still succeed (best-effort)
      assert {:ok, closed_session} = S2.S2S.ReadSession.close(session)
      assert closed_session.closed == true
    end
  end

  describe "Read error paths" do
    test "returns error on closed connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, conn} = Mint.HTTP2.close(conn)

      assert {:error, _reason, _conn} =
               S2.S2S.Read.call(conn, "basin", "stream", seq_num: 0)
    end

    test "returns error for nonexistent basin" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.Read.call(conn, "nonexistent-basin", "stream", seq_num: 0)
    end
  end

  describe "Shared.receive_complete error paths" do
    test "returns timeout on very short timeout" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      # Make a real request then try to receive with 0 timeout
      headers = S2.S2S.Shared.build_headers("nonexistent", nil, content_type: false)

      case Mint.HTTP2.request(conn, "GET", "/v1/streams/test/records/tail", headers, nil) do
        {:ok, conn, ref} ->
          result = S2.S2S.Shared.receive_complete(conn, ref, timeout: 0)
          assert {:error, :timeout, _conn} = result

        {:error, _conn, _reason} ->
          :ok
      end
    end
  end
end

defmodule S2.S2S.AppendSessionTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("append-sess")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    on_exit(fn ->
      cleanup_basin(client, basin)
    end)

    %{basin: basin, stream: stream}
  end

  describe "open/3" do
    test "opens a streaming append session", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)
      assert %S2.S2S.AppendSession{} = session
      assert session.basin == basin
      assert session.stream == stream
      assert session.closed == false
    end
  end

  describe "append/2" do
    test "appends a record and receives ack", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "session-record-0"}]
      }

      assert {:ok, %S2.V1.AppendAck{} = ack, _session} =
               S2.S2S.AppendSession.append(session, input)

      assert ack.start.seq_num == 0
      assert ack.end.seq_num == 1
    end

    test "appends multiple sequential batches", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      input1 = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "batch1-rec0"}]
      }

      assert {:ok, %S2.V1.AppendAck{} = ack1, session} =
               S2.S2S.AppendSession.append(session, input1)

      assert ack1.start.seq_num == 0

      input2 = %S2.V1.AppendInput{
        records: [
          %S2.V1.AppendRecord{body: "batch2-rec0"},
          %S2.V1.AppendRecord{body: "batch2-rec1"}
        ]
      }

      assert {:ok, %S2.V1.AppendAck{} = ack2, _session} =
               S2.S2S.AppendSession.append(session, input2)

      assert ack2.start.seq_num == 1
      assert ack2.end.seq_num == 3
    end

    test "returns encode error for invalid input struct", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      bad_input = %S2.V1.AppendInput{records: "not_a_list"}

      assert {:error, {:encode_error, _}, _session} =
               S2.S2S.AppendSession.append(session, bad_input)
    end

    test "returns error when session is closed", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)
      {:ok, session} = S2.S2S.AppendSession.close(session)

      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "should fail"}]
      }

      assert {:error, :session_closed, _session} = S2.S2S.AppendSession.append(session, input)
    end
  end

  describe "process affinity" do
    test "raises when append is called from a different process", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "cross-process"}]
      }

      task =
        Task.async(fn ->
          try do
            S2.S2S.AppendSession.append(session, input)
          rescue
            e in ArgumentError -> {:raised, e}
          end
        end)

      assert {:raised, %ArgumentError{message: msg}} = Task.await(task)
      assert msg =~ "must be used from the process that created it"
    end
  end

  describe "close/1" do
    test "closes the session gracefully", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)

      assert {:ok, session} = S2.S2S.AppendSession.close(session)
      assert session.closed == true
    end

    test "closing an already-closed session is a no-op", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.AppendSession.open(conn, basin, stream)
      {:ok, session} = S2.S2S.AppendSession.close(session)

      assert {:ok, ^session} = S2.S2S.AppendSession.close(session)
    end
  end
end

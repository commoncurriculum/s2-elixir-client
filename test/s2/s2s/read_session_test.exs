defmodule S2.S2S.ReadSessionTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("read-sess")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    # Append some records to read back
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

    input = %S2.V1.AppendInput{
      records: [
        %S2.V1.AppendRecord{body: "record-0"},
        %S2.V1.AppendRecord{body: "record-1"},
        %S2.V1.AppendRecord{body: "record-2"}
      ]
    }

    {:ok, _ack, _conn} = S2.S2S.Append.call(conn, basin, stream, input)

    on_exit(fn ->
      cleanup_basin(client, basin)
    end)

    %{basin: basin, stream: stream}
  end

  describe "open/4" do
    test "opens a read session", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:ok, session} =
               S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      assert %S2.S2S.ReadSession{} = session
      assert session.closed == false
    end
  end

  describe "next_batch/1" do
    test "receives a ReadBatch with records", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      assert {:ok, %S2.V1.ReadBatch{} = batch, _session} =
               S2.S2S.ReadSession.next_batch(session)

      assert length(batch.records) == 3
      assert Enum.at(batch.records, 0).body == "record-0"
      assert Enum.at(batch.records, 2).body == "record-2"
    end

    test "live tailing receives new records", %{basin: basin, stream: stream} do
      # Open read session tailing from seq 3 (end of existing records)
      {:ok, read_conn} = S2.S2S.Connection.open("http://localhost:4243")

      {:ok, session} =
        S2.S2S.ReadSession.open(read_conn, basin, stream, seq_num: 3)

      # Append new records from a separate process to avoid mailbox interference
      task =
        Task.async(fn ->
          {:ok, write_conn} = S2.S2S.Connection.open("http://localhost:4243")

          input = %S2.V1.AppendInput{
            records: [%S2.V1.AppendRecord{body: "live-record"}]
          }

          S2.S2S.Append.call(write_conn, basin, stream, input)
        end)

      {:ok, _ack, _conn} = Task.await(task)

      # Read session should receive the new record
      assert {:ok, %S2.V1.ReadBatch{} = batch, _session} =
               S2.S2S.ReadSession.next_batch(session)

      assert length(batch.records) >= 1
      assert hd(batch.records).body == "live-record"
      assert hd(batch.records).seq_num == 3
    end

    test "returns error when session is closed", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)
      {:ok, session} = S2.S2S.ReadSession.close(session)

      assert {:error, :session_closed, _session} =
               S2.S2S.ReadSession.next_batch(session)
    end
  end

  describe "process affinity" do
    test "raises when next_batch is called from a different process", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      task = Task.async(fn ->
        try do
          S2.S2S.ReadSession.next_batch(session)
        rescue
          e in ArgumentError -> {:raised, e}
        end
      end)

      assert {:raised, %ArgumentError{message: msg}} = Task.await(task)
      assert msg =~ "must be used from the process that created it"
    end
  end

  describe "close/1" do
    test "closes the session", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)

      assert {:ok, session} = S2.S2S.ReadSession.close(session)
      assert session.closed == true
    end

    test "closing an already-closed session is a no-op", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, session} = S2.S2S.ReadSession.open(conn, basin, stream, seq_num: 0)
      {:ok, session} = S2.S2S.ReadSession.close(session)

      assert {:ok, ^session} = S2.S2S.ReadSession.close(session)
    end
  end
end

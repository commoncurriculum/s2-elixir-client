defmodule S2.S2S.AppendTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("append-test")
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

    %{client: client, basin: basin, stream: stream}
  end

  describe "call/4" do
    test "appends a single record and returns AppendAck", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      input = %S2.V1.AppendInput{
        records: [
          %S2.V1.AppendRecord{body: "hello s2s"}
        ]
      }

      assert {:ok, %S2.V1.AppendAck{} = ack, _conn} =
               S2.S2S.Append.call(conn, basin, stream, input)

      assert ack.start.seq_num == 0
      assert ack.end.seq_num == 1
    end

    test "appends multiple records", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      input = %S2.V1.AppendInput{
        records: [
          %S2.V1.AppendRecord{body: "record-1"},
          %S2.V1.AppendRecord{body: "record-2"},
          %S2.V1.AppendRecord{body: "record-3"}
        ]
      }

      assert {:ok, %S2.V1.AppendAck{} = ack, _conn} =
               S2.S2S.Append.call(conn, basin, stream, input)

      assert ack.start.seq_num == 0
      assert ack.end.seq_num == 3
    end

    test "returns error for nonexistent stream", %{basin: basin} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "data"}]
      }

      assert {:error, %S2.Error{} = error, _conn} =
               S2.S2S.Append.call(conn, basin, "nonexistent-stream", input)

      assert error.status != nil
    end

    test "returns error for nonexistent basin", %{stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "data"}]
      }

      assert {:error, error, _conn} =
               S2.S2S.Append.call(conn, "nonexistent-basin", stream, input)

      assert %S2.Error{} = error
    end
  end
end

defmodule S2.S2S.CheckTailTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("tail-test")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    # Append some records so tail is non-zero
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

    input = %S2.V1.AppendInput{
      records: [
        %S2.V1.AppendRecord{body: "record-0"},
        %S2.V1.AppendRecord{body: "record-1"}
      ]
    }

    {:ok, _ack, _conn} = S2.S2S.Append.call(conn, basin, stream, input)

    on_exit(fn ->
      cleanup_basin(client, basin)
    end)

    %{basin: basin, stream: stream}
  end

  describe "call/3" do
    test "returns tail position", %{basin: basin, stream: stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:ok, %S2.V1.StreamPosition{} = pos, _conn} =
               S2.S2S.CheckTail.call(conn, basin, stream)

      assert pos.seq_num == 2
    end

    test "returns error for nonexistent stream", %{basin: basin} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.CheckTail.call(conn, basin, "nonexistent-stream")
    end

    test "returns error for nonexistent basin" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.CheckTail.call(conn, "nonexistent-basin", "some-stream")
    end
  end
end

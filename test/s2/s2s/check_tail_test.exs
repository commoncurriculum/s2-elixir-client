defmodule S2.S2S.CheckTailTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("tail-test")
    stream = unique_stream_name("s")
    empty_stream = unique_stream_name("empty")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: empty_stream},
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

    %{basin: basin, stream: stream, empty_stream: empty_stream}
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

    test "returns seq_num 0 for empty stream", %{basin: basin, empty_stream: empty_stream} do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:ok, %S2.V1.StreamPosition{} = pos, _conn} =
               S2.S2S.CheckTail.call(conn, basin, empty_stream)

      assert pos.seq_num == 0
    end

    test "returns error for nonexistent basin" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      assert {:error, %S2.Error{}, _conn} =
               S2.S2S.CheckTail.call(conn, "nonexistent-basin", "some-stream")
    end

    test "returns error on closed connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      {:ok, conn} = Mint.HTTP2.close(conn)

      assert {:error, _reason, _conn} =
               S2.S2S.CheckTail.call(conn, "basin", "stream")
    end
  end

  describe "parse_tail_response/2" do
    test "parses valid tail with seq_num and timestamp" do
      data = Jason.encode!(%{"tail" => %{"seq_num" => 5, "timestamp" => 1000}})

      assert {:ok, %S2.V1.StreamPosition{seq_num: 5, timestamp: 1000}, :conn} =
               S2.S2S.CheckTail.parse_tail_response(data, :conn)
    end

    test "parses tail with seq_num but no timestamp" do
      data = Jason.encode!(%{"tail" => %{"seq_num" => 0}})

      assert {:ok, %S2.V1.StreamPosition{seq_num: 0, timestamp: 0}, :conn} =
               S2.S2S.CheckTail.parse_tail_response(data, :conn)
    end

    test "returns error for invalid tail fields" do
      data = Jason.encode!(%{"tail" => %{"seq_num" => "not_int"}})

      assert {:error, %S2.Error{message: msg}, :conn} =
               S2.S2S.CheckTail.parse_tail_response(data, :conn)

      assert msg =~ "invalid tail fields"
    end

    test "returns error when tail key is missing" do
      data = Jason.encode!(%{"other" => "stuff"})

      assert {:error, %S2.Error{message: msg}, :conn} =
               S2.S2S.CheckTail.parse_tail_response(data, :conn)

      assert msg =~ "missing tail key"
    end

    test "returns error for non-JSON data" do
      assert {:error, %S2.Error{message: msg}, :conn} =
               S2.S2S.CheckTail.parse_tail_response("not json", :conn)

      assert msg =~ "failed to decode"
    end

    test "returns error for negative seq_num" do
      data = Jason.encode!(%{"tail" => %{"seq_num" => -1}})

      assert {:error, %S2.Error{message: msg}, :conn} =
               S2.S2S.CheckTail.parse_tail_response(data, :conn)

      assert msg =~ "invalid tail fields"
    end
  end
end

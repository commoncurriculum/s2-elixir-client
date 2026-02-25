defmodule S2.StreamTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("stream-test")
    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    on_exit(fn ->
      cleanup_basin(client, basin)
    end)

    %{client: client, basin: basin}
  end

  describe "create_stream/2" do
    test "creates a stream", %{client: client, basin: basin} do
      stream = unique_stream_name("s")

      assert {:ok, %S2.StreamInfo{} = info} =
               S2.Streams.create_stream(
                 %S2.CreateStreamRequest{stream: stream},
                 server: client,
                 basin: basin
               )

      assert info.name == stream
    end
  end

  describe "list_streams/1" do
    test "lists streams in a basin", %{client: client, basin: basin} do
      stream = unique_stream_name("s")

      {:ok, _} =
        S2.Streams.create_stream(
          %S2.CreateStreamRequest{stream: stream},
          server: client,
          basin: basin
        )

      assert {:ok, %S2.ListStreamsResponse{} = resp} =
               S2.Streams.list_streams(server: client, basin: basin)

      assert is_list(resp.streams)
      assert length(resp.streams) >= 1
      assert %S2.StreamInfo{} = hd(resp.streams)
    end
  end

  describe "delete_stream/2" do
    test "deletes a stream", %{client: client, basin: basin} do
      stream = unique_stream_name("s")

      {:ok, _} =
        S2.Streams.create_stream(
          %S2.CreateStreamRequest{stream: stream},
          server: client,
          basin: basin
        )

      assert :ok = S2.Streams.delete_stream(stream, server: client, basin: basin)
    end
  end
end

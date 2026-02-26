defmodule S2.Store.ListenerTest do
  use ExUnit.Case
  import S2.TestHelpers

  describe "resolve_start_position/4" do
    setup do
      client = test_client()
      basin = unique_basin_name("listener-test")
      stream = unique_stream_name("s")

      {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      {:ok, _} =
        S2.Streams.create_stream(
          %S2.CreateStreamRequest{stream: stream},
          server: client,
          basin: basin
        )

      on_exit(fn -> cleanup_basin(client, basin) end)

      config = %{basin: basin, token: nil}
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      %{conn: conn, config: config, stream: stream}
    end

    test "returns explicit seq_num", %{conn: conn, config: config, stream: stream} do
      assert {:ok, 42, ^conn} =
               S2.Store.Listener.resolve_start_position(conn, config, stream, from: 42)
    end

    test "returns 0 as default", %{conn: conn, config: config, stream: stream} do
      assert {:ok, 0, ^conn} =
               S2.Store.Listener.resolve_start_position(conn, config, stream, [])
    end

    test "resolves :tail via CheckTail", %{conn: conn, config: config, stream: stream} do
      assert {:ok, seq_num, _conn} =
               S2.Store.Listener.resolve_start_position(conn, config, stream, from: :tail)

      assert is_integer(seq_num)
    end

    test "returns error for invalid from value", %{conn: conn, config: config, stream: stream} do
      assert {:error, {:invalid_from, "bad"}, _conn} =
               S2.Store.Listener.resolve_start_position(conn, config, stream, from: "bad")
    end

    test "returns error for negative seq_num", %{conn: conn, config: config, stream: stream} do
      assert {:error, {:invalid_from, -1}, _conn} =
               S2.Store.Listener.resolve_start_position(conn, config, stream, from: -1)
    end
  end

  describe "resolve_start_position/4 with CheckTail error" do
    test "returns error when CheckTail fails for :tail position" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      bad_config = %{basin: "nonexistent-basin-for-tail", token: nil}

      assert {:error, %S2.Error{}, _conn} =
               S2.Store.Listener.resolve_start_position(
                 conn,
                 bad_config,
                 "some-stream",
                 from: :tail
               )
    end
  end
end

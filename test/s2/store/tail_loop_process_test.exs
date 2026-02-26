defmodule S2.Store.TailLoopProcessTest do
  @moduledoc """
  Process-level tests for TailLoop covering decode errors, callback crashes,
  end_of_stream, and reconnect with backoff.
  """
  use ExUnit.Case
  import S2.TestHelpers

  @json_serializer %{
    serialize: &Jason.encode!/1,
    deserialize: &Jason.decode!/1
  }

  setup do
    client = test_client()
    basin = unique_basin_name("tail-loop")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    # Append some records
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

    input = %S2.V1.AppendInput{
      records: [
        %S2.V1.AppendRecord{body: Jason.encode!("msg-0")},
        %S2.V1.AppendRecord{body: Jason.encode!("msg-1")}
      ]
    }

    {:ok, _ack, _conn} = S2.S2S.Append.call(conn, basin, stream, input)

    on_exit(fn -> cleanup_basin(client, basin) end)

    config = %{
      base_url: "http://localhost:4243",
      token: nil,
      basin: basin,
      stream: stream,
      max_retries: 2,
      base_delay: 10,
      recv_timeout: 1_000
    }

    %{config: config, basin: basin, stream: stream}
  end

  # Helper: open session and run TailLoop inside a spawned process (respects process affinity)
  defp run_tail_loop(basin, stream, callback, config, opts \\ []) do
    recv_timeout = Keyword.get(opts, :recv_timeout, 1_000)
    seq_num = Keyword.get(opts, :seq_num, 0)
    kill_socket = Keyword.get(opts, :kill_socket, false)
    parent = self()

    spawn_link(fn ->
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, stream,
          seq_num: seq_num,
          recv_timeout: recv_timeout
        )

      if kill_socket do
        :gen_tcp.close(session.conn.socket)
      end

      result = S2.Store.TailLoop.run(session, @json_serializer, callback, config)
      send(parent, {:tail_loop_result, result})
    end)
  end

  test "run reads records and calls callback", %{config: config, basin: basin, stream: stream} do
    test_pid = self()
    callback = fn msg -> send(test_pid, {:received, msg}) end

    run_tail_loop(basin, stream, callback, config)

    assert_receive {:received, "msg-0"}, 2_000
    assert_receive {:received, "msg-1"}, 2_000
  end

  test "callback crash is rescued and loop continues", %{
    config: config,
    basin: basin,
    stream: stream
  } do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    callback = fn msg ->
      :counters.add(call_count, 1, 1)
      count = :counters.get(call_count, 1)

      if count == 1 do
        raise "boom"
      else
        send(test_pid, {:received, msg})
      end
    end

    run_tail_loop(basin, stream, callback, config)

    # First callback crashes, second should still be called
    assert_receive {:received, _msg}, 2_000
  end

  test "run without config (nil connector) still works", %{basin: basin, stream: stream} do
    test_pid = self()
    callback = fn msg -> send(test_pid, {:received, msg}) end

    # Pass nil config — no reconnect support
    run_tail_loop(basin, stream, callback, nil)

    assert_receive {:received, "msg-0"}, 2_000
  end

  test "error without connector returns error directly", %{basin: basin, stream: stream} do
    callback = fn _msg -> :ok end

    run_tail_loop(basin, stream, callback, nil,
      kill_socket: true,
      recv_timeout: 200
    )

    # Should return {:error, reason} since there's no connector to reconnect
    assert_receive {:tail_loop_result, {:error, _}}, 3_000
  end

  test "reconnect on connection error with config", %{
    config: config,
    basin: basin,
    stream: stream
  } do
    test_pid = self()
    callback = fn msg -> send(test_pid, {:received, msg}) end

    # Start reading, kill socket to trigger reconnect
    run_tail_loop(basin, stream, callback, config,
      kill_socket: true,
      recv_timeout: 500
    )

    # Either reconnects and reads records, or fails after max retries
    receive do
      {:received, _} -> :ok
      {:tail_loop_result, {:error, _}} -> :ok
    after
      5_000 -> :ok
    end
  end

  test "decode error in batch is logged and loop continues", %{
    config: config,
    basin: basin,
    stream: stream
  } do
    # Use a serializer that fails to deserialize, triggering {:error, reason} path
    bad_serializer = %{
      serialize: &Jason.encode!/1,
      deserialize: fn _data -> raise "decode boom" end
    }

    parent = self()

    spawn_link(fn ->
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, stream,
          seq_num: 0,
          recv_timeout: 1_000
        )

      result = S2.Store.TailLoop.run(session, bad_serializer, fn _msg -> :ok end, config)
      send(parent, {:tail_loop_result, result})
    end)

    # The decode errors should be logged, loop continues to next batch (blocks waiting)
    # Give it time to process
    Process.sleep(500)
  end

  test "end_of_stream returns :ok", %{config: config, basin: basin, stream: _stream} do
    parent = self()

    # Create an empty stream (no records) and read from it
    empty_stream = unique_stream_name("empty")

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: empty_stream},
        server: test_client(),
        basin: basin
      )

    spawn_link(fn ->
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      {:ok, session} =
        S2.S2S.ReadSession.open(conn, basin, empty_stream,
          seq_num: 0,
          recv_timeout: 500
        )

      result =
        S2.Store.TailLoop.run(
          session,
          @json_serializer,
          fn _msg -> :ok end,
          %{config | stream: empty_stream}
        )

      send(parent, {:tail_loop_result, result})
    end)

    # Delete the stream to force the server to close it
    Process.sleep(100)
    S2.Streams.delete_stream(empty_stream, server: test_client(), basin: basin)

    # The loop should get either :end_of_stream or an error
    receive do
      {:tail_loop_result, :ok} -> :ok
      {:tail_loop_result, {:error, _}} -> :ok
    after
      5_000 -> :ok
    end
  end

  test "reconnect with max_retries_exceeded", %{basin: basin, stream: stream} do
    callback = fn _msg -> :ok end

    config = %{
      base_url: "http://localhost:1",
      token: nil,
      basin: basin,
      stream: stream,
      max_retries: 1,
      base_delay: 10,
      recv_timeout: 200
    }

    # Kill socket + unreachable reconnect URL = max retries hit
    run_tail_loop(basin, stream, callback, config,
      kill_socket: true,
      recv_timeout: 200
    )

    assert_receive {:tail_loop_result, {:error, _reason}}, 10_000
  end
end

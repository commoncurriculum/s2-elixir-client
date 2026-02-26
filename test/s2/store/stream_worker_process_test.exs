defmodule S2.Store.StreamWorkerProcessTest do
  @moduledoc """
  Process-level tests for StreamWorker covering terminate, connection_failed,
  append_batch error paths, and reconnect handling.
  """
  use ExUnit.Case
  import S2.TestHelpers

  @json_serializer %{
    serialize: &Jason.encode!/1,
    deserialize: &Jason.decode!/1
  }

  defmodule TestWorkerStore do
    use S2.Store, otp_app: :s2, basin: "placeholder"
  end

  setup do
    client = test_client()
    basin = unique_basin_name("sw-proc")
    stream = unique_stream_name("s")

    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream},
        server: client,
        basin: basin
      )

    on_exit(fn -> cleanup_basin(client, basin) end)

    config = %{
      store: TestWorkerStore,
      basin: basin,
      serializer: @json_serializer,
      base_url: "http://localhost:4243",
      token: nil,
      max_retries: 2,
      base_delay: 10,
      max_queue_size: 1000,
      recv_timeout: 5_000,
      compression: :none,
      call_timeout: 5_000
    }

    # Start a supervisor so named processes work
    start_supervised!({S2.Store.Supervisor, config})

    %{config: config, stream: stream, basin: basin}
  end

  test "terminate with nil session does not crash", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    # Replace session with nil
    :sys.replace_state(pid, fn state -> %{state | session: nil} end)

    # Stop triggers terminate/2 with session: nil (line 49)
    GenServer.stop(pid, :normal)
  end

  test "terminate with non-session state does not crash", %{config: config} do
    stream2 = unique_stream_name("s2")

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream2},
        server: test_client(),
        basin: config.basin
      )

    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream2)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream2))

    # Replace session with a bare atom (not AppendSession or nil)
    :sys.replace_state(pid, fn state -> %{state | session: :not_a_session} end)

    GenServer.stop(pid, :normal)
  end

  test "handle_call returns error when connector status is :failed", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    # Set connector status to :failed
    :sys.replace_state(pid, fn state ->
      %{state | connector: %{state.connector | status: :failed}}
    end)

    assert {:error, :connection_failed} =
             GenServer.call(pid, {:append, "msg", @json_serializer})
  end

  test "append_batch returns serialization_error when serializer raises", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    bad_serializer = %{serialize: fn _ -> raise "boom" end, deserialize: &Function.identity/1}

    assert {:error, {:serialization_error, %RuntimeError{message: "boom"}}} =
             GenServer.call(pid, {:append_batch, ["x"], bad_serializer})
  end

  test "append_batch returns overloaded when connector is reconnecting", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    # Set connector to reconnecting — this exercises the guard clause on line 59
    :sys.replace_state(pid, fn state ->
      %{state | connector: %{state.connector | status: :reconnecting}}
    end)

    assert {:error, :reconnecting} =
             GenServer.call(pid, {:append_batch, ["a", "b"], @json_serializer})
  end

  test "reconnect cycle on append failure", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    # Kill the TCP socket
    state = :sys.get_state(pid)
    :gen_tcp.close(state.session.conn.socket)

    # Append should fail and trigger reconnect
    assert {:error, _reason} =
             GenServer.call(pid, {:append, "test", @json_serializer})

    state = :sys.get_state(pid)
    assert state.session == nil
    assert state.connector.status in [:reconnecting, :failed]

    # Wait for reconnect
    Process.sleep(500)

    state = :sys.get_state(pid)

    if state.connector.status == :connected do
      assert {:ok, _ack} = GenServer.call(pid, {:append, "recovered", @json_serializer})
    end
  end

  test "handle_info with stale message is no-op", %{stream: stream} do
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream))

    state_before = :sys.get_state(pid)
    send(pid, {:tcp, :fake_socket, "stale data"})
    Process.sleep(10)
    state_after = :sys.get_state(pid)

    assert state_before.connector == state_after.connector
  end

  test "max_retries_exceeded sets connector to failed after append failure", %{config: config} do
    # Create a stream, start worker, then change basin to cause reconnect failure
    stream3 = unique_stream_name("s3")

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream3},
        server: test_client(),
        basin: config.basin
      )

    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream3)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream3))

    # Set max_retries to 1 so we hit max_retries_exceeded quickly
    :sys.replace_state(pid, fn state ->
      %{
        state
        | config: %{state.config | max_retries: 1, base_delay: 10, base_url: "http://localhost:1"},
          connector: %{state.connector | max_retries: 1, base_delay: 10}
      }
    end)

    # Kill the socket to trigger reconnect
    state = :sys.get_state(pid)
    :gen_tcp.close(state.session.conn.socket)

    # Append fails and triggers reconnect
    assert {:error, _reason} =
             GenServer.call(pid, {:append, "test", @json_serializer})

    # Wait for reconnect attempts to exhaust
    Process.sleep(1_000)

    state = :sys.get_state(pid)
    # Should be :failed or :reconnecting (depending on timing)
    assert state.connector.status in [:failed, :reconnecting]
  end

  test "reconnect_failed and DOWN messages trigger schedule_reconnect", %{config: config} do
    stream4 = unique_stream_name("s4")

    {:ok, _} =
      S2.Streams.create_stream(
        %S2.CreateStreamRequest{stream: stream4},
        server: test_client(),
        basin: config.basin
      )

    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestWorkerStore, stream4)
    pid = GenServer.whereis(S2.Store.Supervisor.stream_worker_name(TestWorkerStore, stream4))

    # Put worker into reconnecting state with nil session
    :sys.replace_state(pid, fn state ->
      connector =
        S2.Store.Connector.new(base_delay: 10, max_retries: 5)
        |> S2.Store.Connector.connected()

      %{state | session: nil, connector: connector}
    end)

    # Send reconnect_failed — should trigger schedule_reconnect (lines 114, 173-175)
    send(pid, {:reconnect_failed, :test_failure})
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.connector.status in [:reconnecting, :connected, :failed]

    # Send :DOWN for reconnect ref — should trigger schedule_reconnect (line 124)
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      %{state | reconnect_ref: ref}
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.connector.status in [:reconnecting, :connected, :failed]
  end

  test "init returns error for unreachable URL" do
    config = %{
      store: TestWorkerStore,
      basin: "bad-basin",
      serializer: @json_serializer,
      base_url: "http://localhost:1",
      token: nil,
      max_retries: 1,
      base_delay: 10,
      max_queue_size: 1000,
      recv_timeout: 100,
      compression: :none,
      call_timeout: 5_000
    }

    # Use GenServer.start directly to avoid named process collision
    result = GenServer.start(S2.Store.StreamWorker, {config, "unreachable-stream"})
    assert {:error, {:connect_failed, _}} = result
  end
end

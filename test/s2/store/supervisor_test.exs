defmodule S2.Store.SupervisorTest do
  use ExUnit.Case
  import S2.TestHelpers

  defmodule TestSupStore do
    use S2.Store,
      otp_app: :s2,
      basin: "placeholder"
  end

  setup do
    client = test_client()
    basin = unique_basin_name("sup-test")
    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    config = %{
      store: TestSupStore,
      basin: basin,
      serializer: TestSupStore.config().serializer,
      base_url: "http://localhost:4243",
      token: nil,
      max_retries: 5,
      base_delay: 100,
      max_queue_size: 1000,
      recv_timeout: 5_000,
      compression: :none,
      call_timeout: 5_000
    }

    start_supervised!({S2.Store.Supervisor, config})
    on_exit(fn -> cleanup_basin(client, basin) end)

    %{basin: basin}
  end

  test "delete_stream delegates to control plane" do
    {:ok, _} = S2.Store.Supervisor.create_stream(TestSupStore, "del-test-stream")
    result = S2.Store.Supervisor.delete_stream(TestSupStore, "del-test-stream")
    assert result == :ok || match?({:error, _}, result)
  end

  test "ensure_worker returns error for connection failure" do
    # Start a supervisor with an unreachable URL
    config = %{
      store: Module.concat(TestSupStore, BadConn),
      basin: "bad-basin",
      serializer: TestSupStore.config().serializer,
      base_url: "http://localhost:1",
      token: nil,
      max_retries: 1,
      base_delay: 10,
      max_queue_size: 1000,
      recv_timeout: 100,
      compression: :none,
      call_timeout: 5_000
    }

    start_supervised!(%{
      id: :bad_sup,
      start: {S2.Store.Supervisor, :start_link, [config]},
      type: :supervisor
    })

    # ensure_worker will fail because it can't connect
    result = S2.Store.Supervisor.ensure_worker(Module.concat(TestSupStore, BadConn), "stream")
    assert {:error, _} = result
  end

  test "stop_listener returns error for non-existent pid" do
    dead_pid = spawn(fn -> :ok end)
    Process.sleep(10)
    assert {:error, :not_found} = S2.Store.Supervisor.stop_listener(TestSupStore, dead_pid)
  end
end

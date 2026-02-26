defmodule S2.StoreIntegrationTest do
  use ExUnit.Case
  import S2.TestHelpers

  # -- The "chat app" from the README, as a real test --

  # Store (like MyApp.S2)
  defmodule TestS2 do
    use S2.Store,
      otp_app: :s2,
      basin: "placeholder"
  end

  # Message schema — defined before Chat so serializer/0 is available at compile time
  defmodule Chat.Message do
    use Ecto.Schema
    import Ecto.Changeset

    @derive Jason.Encoder
    @primary_key false
    embedded_schema do
      field :user, :string
      field :text, :string
      field :ts, :utc_datetime
    end

    def new(attrs) do
      %__MODULE__{ts: DateTime.utc_now()}
      |> changeset(Map.new(attrs))
      |> apply_action!(:new)
    end

    def changeset(message \\ %__MODULE__{}, attrs) do
      message
      |> cast(attrs, [:user, :text, :ts])
      |> validate_required([:user, :text])
    end

    def serializer do
      %{
        serialize: &Jason.encode!/1,
        deserialize: fn json ->
          attrs = Jason.decode!(json)
          %__MODULE__{} |> cast(attrs, [:user, :text, :ts]) |> apply_action!(:load)
        end
      }
    end
  end

  # Chat module (like MyApp.Chat)
  defmodule Chat do
    use S2.StoreIntegrationTest.TestS2,
      serializer: S2.StoreIntegrationTest.Chat.Message.serializer()

    def create_room(room), do: create_stream("chat/#{room}")
  end

  setup do
    client = test_client()
    basin = unique_basin_name("store-int")
    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    Application.put_env(:s2, TestS2, base_url: "http://localhost:4243")

    config = %{
      store: TestS2,
      basin: basin,
      serializer: TestS2.config().serializer,
      base_url: "http://localhost:4243",
      token: nil,
      max_retries: 5,
      base_delay: 100,
      max_queue_size: 1000,
      recv_timeout: 5_000,
      compression: :none
    }

    start_supervised!({S2.Store.Supervisor, config})

    on_exit(fn -> cleanup_basin(client, basin) end)

    %{basin: basin}
  end

  test "full chat flow: create room, append messages, listen" do
    {:ok, _} = Chat.create_room("general")

    msg1 = Chat.Message.new(user: "alice", text: "hey everyone!")
    msg2 = Chat.Message.new(user: "bob", text: "hi alice!")
    msg3 = Chat.Message.new(user: "alice", text: "how's it going?")

    {:ok, ack1} = Chat.append("chat/general", msg1)
    {:ok, ack2} = Chat.append("chat/general", msg2)
    {:ok, ack3} = Chat.append("chat/general", msg3)

    assert ack1.start.seq_num == 0
    assert ack2.start.seq_num >= 1
    assert ack3.start.seq_num >= 2

    test_pid = self()

    Chat.listen("chat/general", fn %Chat.Message{} = msg ->
      send(test_pid, {:msg, msg})
    end)

    messages = for _ <- 1..3 do
      assert_receive {:msg, %Chat.Message{} = msg}, 5_000
      msg
    end

    assert length(messages) == 3
    assert Enum.at(messages, 0).user == "alice"
    assert Enum.at(messages, 0).text == "hey everyone!"
    assert Enum.at(messages, 1).user == "bob"
    assert Enum.at(messages, 1).text == "hi alice!"
    assert Enum.at(messages, 2).user == "alice"
    assert Enum.at(messages, 2).text == "how's it going?"

    # Timestamps were auto-set
    assert %DateTime{} = Enum.at(messages, 0).ts
  end

  test "multiple rooms are independent streams" do
    {:ok, _} = Chat.create_room("general")
    {:ok, _} = Chat.create_room("random")

    {:ok, _} = Chat.append("chat/general", Chat.Message.new(user: "alice", text: "in general"))
    {:ok, _} = Chat.append("chat/random", Chat.Message.new(user: "bob", text: "in random"))

    test_pid = self()

    Chat.listen("chat/general", fn %Chat.Message{} = msg ->
      send(test_pid, {:general, msg})
    end)

    assert_receive {:general, %Chat.Message{text: "in general"}}, 5_000
    refute_receive {:general, %Chat.Message{text: "in random"}}, 500
  end

  test "append reconnects after connection drop" do
    {:ok, _} = Chat.create_room("reconnect")

    # First append succeeds — this lazily starts the stream worker
    msg1 = Chat.Message.new(user: "alice", text: "before disconnect")
    {:ok, ack1} = Chat.append("chat/reconnect", msg1)
    assert ack1.start.seq_num == 0

    # Kill the worker's underlying TCP socket to simulate a connection drop
    [{worker_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/reconnect")
    %{session: session} = :sys.get_state(worker_pid)
    socket = session.conn.socket
    :gen_tcp.close(socket)

    # Next append should reconnect transparently and succeed
    msg2 = Chat.Message.new(user: "bob", text: "after disconnect")
    {:ok, ack2} = Chat.append("chat/reconnect", msg2)
    assert ack2.start.seq_num >= 1

    # Both messages should be readable
    test_pid = self()

    Chat.listen("chat/reconnect", fn %Chat.Message{} = msg ->
      send(test_pid, {:msg, msg})
    end)

    messages = for _ <- 1..2 do
      assert_receive {:msg, %Chat.Message{} = msg}, 5_000
      msg
    end

    assert Enum.at(messages, 0).text == "before disconnect"
    assert Enum.at(messages, 1).text == "after disconnect"
  end

  test "listener reconnects after connection drop" do
    {:ok, _} = Chat.create_room("listen-reconnect")

    test_pid = self()

    {:ok, listener_pid} = Chat.listen("chat/listen-reconnect", fn %Chat.Message{} = msg ->
      send(test_pid, {:msg, msg})
    end)

    # Append a message — listener should receive it
    {:ok, _} = Chat.append("chat/listen-reconnect", Chat.Message.new(user: "alice", text: "first"))
    assert_receive {:msg, %Chat.Message{text: "first"}}, 5_000

    # Find and kill the listener's TCP socket to simulate a connection drop
    {:links, links} = Process.info(listener_pid, :links)
    tcp_port = Enum.find(links, fn
      port when is_port(port) -> Port.info(port, :name) == {:name, ~c"tcp_inet"}
      _ -> false
    end)
    :gen_tcp.close(tcp_port)

    # Append another message — the listener should reconnect and receive it
    {:ok, _} = Chat.append("chat/listen-reconnect", Chat.Message.new(user: "bob", text: "second"))
    assert_receive {:msg, %Chat.Message{text: "second"}}, 10_000
  end

  test "no duplicate messages after reconnect" do
    {:ok, _} = Chat.create_room("dedup")

    # Append two messages normally
    {:ok, _} = Chat.append("chat/dedup", Chat.Message.new(user: "alice", text: "one"))
    {:ok, _} = Chat.append("chat/dedup", Chat.Message.new(user: "alice", text: "two"))

    # Kill the connection and append a third
    [{worker_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/dedup")
    %{session: session} = :sys.get_state(worker_pid)
    :gen_tcp.close(session.conn.socket)

    {:ok, _} = Chat.append("chat/dedup", Chat.Message.new(user: "alice", text: "three"))

    # Read all messages — should be exactly 3, no duplicates
    test_pid = self()

    Chat.listen("chat/dedup", fn %Chat.Message{} = msg ->
      send(test_pid, {:msg, msg})
    end)

    messages = for _ <- 1..3 do
      assert_receive {:msg, %Chat.Message{} = msg}, 5_000
      msg
    end

    assert Enum.map(messages, & &1.text) == ["one", "two", "three"]
    refute_receive {:msg, _}, 500
  end

  test "crashed worker is restarted by supervisor" do
    {:ok, _} = Chat.create_room("crash")

    # First append starts the worker
    {:ok, _} = Chat.append("chat/crash", Chat.Message.new(user: "alice", text: "before crash"))

    [{old_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/crash")

    # Kill the worker process
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}

    # Supervisor restarts the worker — new PID, same stream name
    Process.sleep(50)
    [{new_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/crash")
    assert new_pid != old_pid

    # The restarted worker works — next append succeeds
    {:ok, _} = Chat.append("chat/crash", Chat.Message.new(user: "bob", text: "after crash"))

    test_pid = self()

    Chat.listen("chat/crash", fn %Chat.Message{} = msg ->
      send(test_pid, {:msg, msg})
    end)

    messages = for _ <- 1..2 do
      assert_receive {:msg, %Chat.Message{} = msg}, 5_000
      msg
    end

    assert Enum.at(messages, 0).text == "before crash"
    assert Enum.at(messages, 1).text == "after crash"
  end

  test "listen from: :tail skips existing messages" do
    {:ok, _} = Chat.create_room("tail")

    # Append messages before the listener starts
    {:ok, _} = Chat.append("chat/tail", Chat.Message.new(user: "alice", text: "old message 1"))
    {:ok, _} = Chat.append("chat/tail", Chat.Message.new(user: "alice", text: "old message 2"))

    test_pid = self()

    # Start listening from tail — should NOT see old messages
    {:ok, _} = Chat.listen("chat/tail", fn %Chat.Message{} = msg ->
      send(test_pid, {:tail_msg, msg})
    end, from: :tail)

    # Give the listener time to connect and NOT receive old messages
    refute_receive {:tail_msg, _}, 1_000

    # Append a new message — listener should receive only this one
    {:ok, _} = Chat.append("chat/tail", Chat.Message.new(user: "bob", text: "new message"))
    assert_receive {:tail_msg, %Chat.Message{text: "new message"}}, 5_000

    # Confirm no old messages leaked through
    refute_receive {:tail_msg, _}, 500
  end

  test "stop_listener stops a running listener" do
    {:ok, _} = Chat.create_room("stop")

    test_pid = self()

    {:ok, listener_pid} = Chat.listen("chat/stop", fn %Chat.Message{} = msg ->
      send(test_pid, {:stop_msg, msg})
    end)

    assert Process.alive?(listener_pid)

    # Append a message — listener receives it
    {:ok, _} = Chat.append("chat/stop", Chat.Message.new(user: "alice", text: "before stop"))
    assert_receive {:stop_msg, %Chat.Message{text: "before stop"}}, 5_000

    # Stop the listener
    :ok = Chat.stop_listener(listener_pid)

    # Give it a moment to die
    Process.sleep(50)
    refute Process.alive?(listener_pid)
  end

  test "serializer error returns error tuple instead of crashing worker" do
    {:ok, _} = Chat.create_room("bad-serial")

    # Use the store directly with a broken serializer
    bad_serializer = %{
      serialize: fn _msg -> raise "boom" end,
      deserialize: fn _bin -> raise "boom" end
    }

    # This should return an error, not crash the worker
    {:ok, _} = S2.Store.Supervisor.ensure_worker(TestS2, "chat/bad-serial")
    result = S2.Store.StreamWorker.append(TestS2, "chat/bad-serial", "anything", bad_serializer)
    assert {:error, {:serialization_error, %RuntimeError{message: "boom"}}} = result

    # The worker should still be alive and functional with a good serializer
    msg = Chat.Message.new(user: "alice", text: "still works")
    assert {:ok, _ack} = Chat.append("chat/bad-serial", msg)
  end

  test "concurrent ensure_worker calls don't crash" do
    {:ok, _} = Chat.create_room("race")

    # Spawn concurrent ensure_worker calls — tests that the race condition
    # where two processes both try to start a worker is handled gracefully
    tasks = for _i <- 1..5 do
      Task.async(fn ->
        S2.Store.Supervisor.ensure_worker(TestS2, "chat/race")
      end)
    end

    results = Task.await_many(tasks, 10_000)

    # All should succeed with {:ok, pid} — no crashes
    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    assert length(pids) == 5

    # All should resolve to the same worker pid
    assert Enum.uniq(pids) |> length() == 1
  end

  test "backpressure returns {:error, :overloaded} when mailbox is full" do
    {:ok, _} = Chat.create_room("backpressure")

    # Start the worker
    {:ok, _} = Chat.append("chat/backpressure", Chat.Message.new(user: "alice", text: "warmup"))

    # Set max_queue_size to 0 so every call is rejected when anything else is queued
    [{worker_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/backpressure")
    :sys.replace_state(worker_pid, fn state ->
      put_in(state, [:config, :max_queue_size], 0)
    end)

    # Suspend the worker so calls pile up in its mailbox
    :sys.suspend(worker_pid)

    # Fire off several async appends — they will queue in the mailbox
    tasks = for i <- 1..3 do
      Task.async(fn ->
        Chat.append("chat/backpressure", Chat.Message.new(user: "user#{i}", text: "msg#{i}"))
      end)
    end

    # Give messages time to land in the mailbox
    Process.sleep(100)

    # Resume — each call sees other messages still queued, should reject as overloaded
    :sys.resume(worker_pid)

    results = Task.await_many(tasks, 30_000)

    # At least one should be overloaded
    assert Enum.any?(results, &match?({:error, :overloaded}, &1)),
      "Expected at least one {:error, :overloaded} but got: #{inspect(results)}"

    # Restore max_queue_size and verify the worker still works
    :sys.replace_state(worker_pid, fn state ->
      put_in(state, [:config, :max_queue_size], 1000)
    end)

    assert {:ok, _ack} = Chat.append("chat/backpressure", Chat.Message.new(user: "alice", text: "after"))
  end

  test "telemetry events are emitted on append" do
    {:ok, _} = Chat.create_room("telemetry")

    test_pid = self()

    # Attach telemetry handlers
    :telemetry.attach("test-append-start", [:s2, :store, :append, :start], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    :telemetry.attach("test-append-stop", [:s2, :store, :append, :stop], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn ->
      :telemetry.detach("test-append-start")
      :telemetry.detach("test-append-stop")
    end)

    {:ok, _} = Chat.append("chat/telemetry", Chat.Message.new(user: "alice", text: "hi"))

    assert_receive {:telemetry, [:s2, :store, :append, :start], %{system_time: _}, %{stream: "chat/telemetry"}}, 1_000
    assert_receive {:telemetry, [:s2, :store, :append, :stop], %{duration: duration}, %{stream: "chat/telemetry"}}, 1_000
    assert is_integer(duration) and duration > 0
  end

  test "telemetry events are emitted on reconnect" do
    {:ok, _} = Chat.create_room("telemetry-reconnect")

    test_pid = self()

    :telemetry.attach("test-reconnect-start", [:s2, :store, :reconnect, :start], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    :telemetry.attach("test-reconnect-stop", [:s2, :store, :reconnect, :stop], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn ->
      :telemetry.detach("test-reconnect-start")
      :telemetry.detach("test-reconnect-stop")
    end)

    # Start worker, then kill its connection
    {:ok, _} = Chat.append("chat/telemetry-reconnect", Chat.Message.new(user: "alice", text: "before"))
    [{worker_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/telemetry-reconnect")
    %{session: session} = :sys.get_state(worker_pid)
    :gen_tcp.close(session.conn.socket)

    # Next append triggers reconnect
    {:ok, _} = Chat.append("chat/telemetry-reconnect", Chat.Message.new(user: "bob", text: "after"))

    assert_receive {:telemetry, [:s2, :store, :reconnect, :start], %{system_time: _}, %{stream: "chat/telemetry-reconnect", component: :writer, attempt: 1}}, 1_000
    assert_receive {:telemetry, [:s2, :store, :reconnect, :stop], %{duration: _}, %{stream: "chat/telemetry-reconnect", component: :writer, attempt: 1}}, 1_000
  end

  test "telemetry events are emitted on listener connect" do
    {:ok, _} = Chat.create_room("telemetry-listen")

    test_pid = self()

    :telemetry.attach("test-listener-connect", [:s2, :store, :listener, :connect], fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end, nil)

    on_exit(fn ->
      :telemetry.detach("test-listener-connect")
    end)

    {:ok, _} = Chat.listen("chat/telemetry-listen", fn _msg -> :ok end)

    assert_receive {:telemetry, [:s2, :store, :listener, :connect], %{system_time: _}, %{stream: "chat/telemetry-listen"}}, 1_000
  end

  test "worker closes session on shutdown" do
    {:ok, _} = Chat.create_room("shutdown")

    # Start worker
    {:ok, _} = Chat.append("chat/shutdown", Chat.Message.new(user: "alice", text: "hi"))

    [{worker_pid, _}] = Registry.lookup(S2.StoreIntegrationTest.TestS2.Registry, "chat/shutdown")
    %{session: session} = :sys.get_state(worker_pid)
    socket = session.conn.socket

    # The TCP socket should be open
    assert {:ok, _} = :inet.peername(socket)

    # Stop the worker gracefully — terminate/2 should close the session
    ref = Process.monitor(worker_pid)
    GenServer.stop(worker_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}

    # The socket should now be closed
    assert {:error, _} = :inet.peername(socket)
  end

  test "Message.new validates required fields" do
    assert_raise Ecto.InvalidChangesetError, fn ->
      Chat.Message.new(text: "no user")
    end

    assert_raise Ecto.InvalidChangesetError, fn ->
      Chat.Message.new(user: "alice")
    end
  end

  test "Message.new sets timestamp automatically" do
    before = DateTime.utc_now()
    msg = Chat.Message.new(user: "alice", text: "hi")
    assert %DateTime{} = msg.ts
    assert DateTime.compare(msg.ts, before) in [:eq, :gt]
  end

  test "Message.new accepts explicit timestamp" do
    ts = ~U[2025-01-01 00:00:00Z]
    msg = Chat.Message.new(user: "alice", text: "hi", ts: ts)
    assert msg.ts == ts
  end

  test "append and listen with gzip compression" do
    # Start a separate store with gzip compression
    basin = unique_basin_name("store-gzip")
    client = test_client()
    {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

    config = %{
      store: TestS2,
      basin: basin,
      serializer: TestS2.config().serializer,
      base_url: "http://localhost:4243",
      token: nil,
      max_retries: 5,
      base_delay: 100,
      max_queue_size: 1000,
      recv_timeout: 5_000,
      compression: :gzip
    }

    # Use a unique registry to avoid conflicts with the main test store
    gzip_store = Module.concat(TestS2, GzipTest)
    config = %{config | store: gzip_store}
    start_supervised!(%{id: :gzip_store, start: {S2.Store.Supervisor, :start_link, [config]}, type: :supervisor})

    on_exit(fn -> cleanup_basin(client, basin) end)

    stream = "chat/gzip-test"
    S2.Streams.create_stream(%S2.CreateStreamRequest{stream: stream}, server: client, basin: basin)

    # Append with gzip compression
    S2.Store.Supervisor.ensure_worker(gzip_store, stream)
    {:ok, _ack} = S2.Store.StreamWorker.append(gzip_store, stream, %{"text" => "compressed!"}, config.serializer)

    # Read back — decompression should happen transparently
    test_pid = self()
    {:ok, _listener} = S2.Store.Supervisor.listen(gzip_store, stream, fn msg ->
      send(test_pid, {:msg, msg})
    end, [])

    assert_receive {:msg, %{"text" => "compressed!"}}, 5_000
  end
end

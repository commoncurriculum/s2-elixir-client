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
      token: nil
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
end

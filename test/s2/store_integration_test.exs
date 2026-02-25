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

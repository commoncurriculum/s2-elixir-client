defmodule S2.StoreTest do
  use ExUnit.Case

  # A test store module, like a user would define
  defmodule TestStore do
    use S2.Store,
      otp_app: :s2,
      basin: "test-basin",
      serializer: %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1}
  end

  describe "module definition" do
    test "defines start_link/1" do
      assert function_exported?(TestStore, :start_link, 1)
    end

    test "defines child_spec/1" do
      spec = TestStore.child_spec([])
      assert spec.id == TestStore
      assert spec.start == {TestStore, :start_link, [[]]}
    end

    test "defines append/2 and append/3 (with serializer override)" do
      assert function_exported?(TestStore, :append, 2)
      assert function_exported?(TestStore, :append, 3)
    end

    test "defines listen/2 and listen/3" do
      assert function_exported?(TestStore, :listen, 2)
      assert function_exported?(TestStore, :listen, 3)
    end

    test "defines create_stream/1" do
      assert function_exported?(TestStore, :create_stream, 1)
    end

    test "defines delete_stream/1" do
      assert function_exported?(TestStore, :delete_stream, 1)
    end

    test "exposes config/0" do
      config = TestStore.config()
      assert config.basin == "test-basin"
      assert config.serializer == %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1}
    end
  end

  describe "serializer default" do
    defmodule JsonStore do
      use S2.Store,
        otp_app: :s2,
        basin: "json-basin"
    end

    test "defaults to JSON serializer when none provided" do
      config = JsonStore.config()
      assert config.serializer.serialize.(%{hello: "world"}) == Jason.encode!(%{hello: "world"})
      assert config.serializer.deserialize.(~s({"hello":"world"})) == %{"hello" => "world"}
    end
  end

  describe "use MyStore (stream module)" do
    defmodule StreamStore do
      use S2.Store,
        otp_app: :s2,
        basin: "stream-basin"
    end

    defmodule ChatStream do
      use S2.StoreTest.StreamStore,
        serializer: %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1}
    end

    test "defines append/2 bound to the store and serializer" do
      assert function_exported?(ChatStream, :append, 2)
    end

    test "defines listen/2 bound to the store and serializer" do
      assert function_exported?(ChatStream, :listen, 2)
      assert function_exported?(ChatStream, :listen, 3)
    end

    test "defines create_stream/1 and delete_stream/1" do
      assert function_exported?(ChatStream, :create_stream, 1)
      assert function_exported?(ChatStream, :delete_stream, 1)
    end

    defmodule DefaultStream do
      use S2.StoreTest.StreamStore
    end

    test "defaults to store serializer when none provided" do
      assert function_exported?(DefaultStream, :append, 2)
    end
  end

  describe "supervisor and stream workers" do
    defmodule WorkerStore do
      use S2.Store,
        otp_app: :s2,
        basin: "worker-basin"
    end

    test "start_link starts a supervisor" do
      # Workers are started lazily, so the supervisor starts even without a server.
      # start_link may fail if Connection.open fails (no server running),
      # but the Supervisor itself is what we're testing.
      result = WorkerStore.start_link()

      case result do
        {:ok, pid} ->
          assert Process.alive?(pid)
          Supervisor.stop(pid)

        {:error, _reason} ->
          # Expected when no S2 server is running — ControlPlane init doesn't
          # connect, so this should succeed. If it fails, something else is wrong.
          flunk("start_link should succeed — workers connect lazily, supervisor should start")
      end
    end

    test "stream_worker_name generates consistent names per stream" do
      name1 = S2.Store.Supervisor.stream_worker_name(WorkerStore, "chat/general")
      name2 = S2.Store.Supervisor.stream_worker_name(WorkerStore, "chat/general")
      name3 = S2.Store.Supervisor.stream_worker_name(WorkerStore, "chat/random")

      assert name1 == name2
      assert name1 != name3
    end
  end
end

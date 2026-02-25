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
end

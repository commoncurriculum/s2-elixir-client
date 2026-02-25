defmodule S2.ClientTest do
  use ExUnit.Case
  import S2.TestHelpers

  describe "new/1" do
    test "creates a client from config" do
      config = S2.Config.new()
      client = S2.Client.new(config)
      assert %S2.Client{} = client
      assert client.config == config
    end
  end

  describe "request/1" do
    setup do
      client = test_client()
      basin = unique_basin_name("client-test")

      on_exit(fn ->
        cleanup_basin(client, basin)
      end)

      %{client: client, basin: basin}
    end

    test "executes a create basin request via generated operation", %{client: client, basin: basin} do
      result =
        S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      assert {:ok, %S2.BasinInfo{}} = result
    end
  end
end

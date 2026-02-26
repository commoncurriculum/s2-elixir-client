defmodule S2.BasinTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name("basin-test")

    on_exit(fn ->
      cleanup_basin(client, basin)
    end)

    %{client: client, basin: basin}
  end

  describe "create_basin/2" do
    test "creates a basin and returns BasinInfo", %{client: client, basin: basin} do
      assert {:ok, %S2.BasinInfo{} = info} =
               S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      assert info.name == basin
      assert info.state in ["active", "creating"]
    end

    test "returns error for duplicate basin", %{client: client, basin: basin} do
      {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      assert {:error, %S2.Error{code: "resource_already_exists"}} =
               S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)
    end
  end

  describe "list_basins/1" do
    test "lists basins", %{client: client, basin: basin} do
      {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      assert {:ok, %S2.ListBasinsResponse{} = resp} =
               S2.Basins.list_basins(server: client, prefix: basin)

      assert is_list(resp.basins)
    end
  end

  describe "delete_basin/2" do
    test "deletes a basin", %{client: client, basin: basin} do
      {:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)
      assert :ok = S2.Basins.delete_basin(basin, server: client)
    end
  end
end

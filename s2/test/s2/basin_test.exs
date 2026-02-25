defmodule S2.BasinTest do
  use ExUnit.Case

  import S2.TestHelpers

  describe "create/2" do
    test "creates a basin and returns its info" do
      client = test_client()
      name = unique_basin_name()

      result = S2.Basin.create(client, name)

      assert {:ok, basin} = result
      assert basin["name"] == name
      assert basin["state"] == "active"

      cleanup_basin(client, name)
    end

    test "returns error on duplicate basin" do
      client = test_client()
      name = unique_basin_name()

      {:ok, _} = S2.Basin.create(client, name)
      result = S2.Basin.create(client, name)

      assert {:error, %S2.Error{status: 409}} = result

      cleanup_basin(client, name)
    end
  end

  describe "list/2" do
    test "lists basins" do
      client = test_client()
      name = unique_basin_name("listtest")
      {:ok, _} = S2.Basin.create(client, name)

      {:ok, result} = S2.Basin.list(client)

      names = Enum.map(result["basins"], & &1["name"])
      assert name in names

      cleanup_basin(client, name)
    end

    test "filters by prefix" do
      client = test_client()
      name = unique_basin_name("preftest")
      {:ok, _} = S2.Basin.create(client, name)

      {:ok, result} = S2.Basin.list(client, prefix: "preftest")

      names = Enum.map(result["basins"], & &1["name"])
      assert name in names

      cleanup_basin(client, name)
    end

    test "paginates with limit" do
      client = test_client()
      n1 = unique_basin_name("pagtest")
      n2 = unique_basin_name("pagtest")
      {:ok, _} = S2.Basin.create(client, n1)
      {:ok, _} = S2.Basin.create(client, n2)

      {:ok, page1} = S2.Basin.list(client, prefix: "pagtest", limit: 1)
      assert length(page1["basins"]) == 1
      assert page1["has_more"] == true

      last = List.last(page1["basins"])["name"]
      {:ok, page2} = S2.Basin.list(client, prefix: "pagtest", start_after: last)
      assert length(page2["basins"]) >= 1

      cleanup_basin(client, n1)
      cleanup_basin(client, n2)
    end
  end

  describe "delete/2" do
    test "deletes a basin" do
      client = test_client()
      name = unique_basin_name("deltest")
      {:ok, _} = S2.Basin.create(client, name)

      result = S2.Basin.delete(client, name)
      assert {:ok, _} = result
    end
  end

  describe "config" do
    test "get_config returns 404 on s2-lite" do
      client = test_client()
      name = unique_basin_name("cfgtest")
      {:ok, _} = S2.Basin.create(client, name)

      result = S2.Basin.get_config(client, name)
      assert {:error, %S2.Error{status: 404}} = result

      cleanup_basin(client, name)
    end

    test "reconfigure returns 404 on s2-lite" do
      client = test_client()
      name = unique_basin_name("cfgtest")
      {:ok, _} = S2.Basin.create(client, name)

      result = S2.Basin.reconfigure(client, name, %{})
      assert {:error, %S2.Error{status: 404}} = result

      cleanup_basin(client, name)
    end
  end
end

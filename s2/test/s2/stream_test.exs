defmodule S2.StreamTest do
  use ExUnit.Case

  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name()
    {:ok, _} = S2.Basin.create(client, basin)

    on_exit(fn -> cleanup_basin(test_client(), basin) end)

    %{client: client, basin: basin}
  end

  describe "create/3" do
    test "creates a stream", %{client: client, basin: basin} do
      name = unique_stream_name()

      result = S2.Stream.create(client, basin, name)

      assert {:ok, stream} = result
      assert stream["name"] == name
      assert stream["created_at"]
    end

    test "returns 409 on duplicate stream", %{client: client, basin: basin} do
      name = unique_stream_name()

      {:ok, _} = S2.Stream.create(client, basin, name)
      result = S2.Stream.create(client, basin, name)

      assert {:error, %S2.Error{status: 409}} = result
    end
  end

  describe "list/3" do
    test "lists created streams", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "alpha-stream")
      {:ok, _} = S2.Stream.create(client, basin, "beta-stream")
      {:ok, _} = S2.Stream.create(client, basin, "gamma-stream")

      {:ok, result} = S2.Stream.list(client, basin)

      names = Enum.map(result["streams"], & &1["name"])
      assert "alpha-stream" in names
      assert "beta-stream" in names
      assert "gamma-stream" in names
    end

    test "filters by prefix", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "foo-one")
      {:ok, _} = S2.Stream.create(client, basin, "foo-two")
      {:ok, _} = S2.Stream.create(client, basin, "bar-one")

      {:ok, result} = S2.Stream.list(client, basin, prefix: "foo")

      names = Enum.map(result["streams"], & &1["name"])
      assert length(names) == 2
      assert "foo-one" in names
      assert "foo-two" in names
    end

    test "paginates with limit and start_after", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "a-stream")
      {:ok, _} = S2.Stream.create(client, basin, "b-stream")
      {:ok, _} = S2.Stream.create(client, basin, "c-stream")

      {:ok, page1} = S2.Stream.list(client, basin, limit: 2)
      assert length(page1["streams"]) == 2
      assert page1["has_more"] == true

      last_name = List.last(page1["streams"])["name"]
      {:ok, page2} = S2.Stream.list(client, basin, start_after: last_name)
      assert length(page2["streams"]) == 1
      assert page2["has_more"] == false
    end
  end

  describe "config" do
    test "get_config returns 404 on s2-lite", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "config-test")
      result = S2.Stream.get_config(client, basin, "config-test")
      # s2-lite does not implement config endpoints
      assert {:error, %S2.Error{status: 404}} = result
    end

    test "reconfigure returns 404 on s2-lite", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "reconfig-test")
      result = S2.Stream.reconfigure(client, basin, "reconfig-test", %{})
      assert {:error, %S2.Error{status: 404}} = result
    end
  end

  describe "delete/3" do
    test "deletes a stream", %{client: client, basin: basin} do
      {:ok, _} = S2.Stream.create(client, basin, "to-delete")

      result = S2.Stream.delete(client, basin, "to-delete")
      assert {:ok, _} = result

      # s2-lite still lists deleted streams but with deleted_at set
      {:ok, list_result} = S2.Stream.list(client, basin)
      deleted = Enum.find(list_result["streams"], &(&1["name"] == "to-delete"))
      assert deleted["deleted_at"] != nil
    end
  end
end

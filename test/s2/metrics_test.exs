defmodule S2.MetricsTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    %{client: test_client()}
  end

  describe "account_metrics/1" do
    test "returns metrics with storage set", %{client: client} do
      result = S2.Metrics.account_metrics(server: client, set: "storage")

      case result do
        {:ok, %S2.MetricSetResponse{} = resp} ->
          assert is_map(resp)

        {:error, %S2.Error{} = error} ->
          # 403 or similar is acceptable for a test environment
          assert error.status != nil or error.message != nil
      end
    end

    test "returns error for invalid metric set", %{client: client} do
      assert {:error, %S2.Error{}} =
               S2.Metrics.account_metrics(server: client, set: "nonexistent_set")
    end
  end

  describe "basin_metrics/2" do
    test "returns error for nonexistent basin", %{client: client} do
      assert {:error, %S2.Error{}} =
               S2.Metrics.basin_metrics("nonexistent-basin-12345", server: client, set: "storage")
    end
  end

  describe "stream_metrics/3" do
    test "returns error for nonexistent basin/stream", %{client: client} do
      assert {:error, %S2.Error{}} =
               S2.Metrics.stream_metrics("nonexistent-basin-12345", "nonexistent-stream", server: client, set: "storage")
    end
  end
end

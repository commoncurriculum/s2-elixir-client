defmodule S2.MetricsTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    %{client: test_client()}
  end

  describe "account_metrics/1" do
    test "returns metrics or error", %{client: client} do
      case S2.Metrics.account_metrics(server: client, set: "summary") do
        {:ok, %S2.MetricSetResponse{}} -> :ok
        {:error, %S2.ErrorInfo{}} -> :ok
      end
    end
  end

  describe "basin_metrics/2" do
    test "returns metrics or error", %{client: client} do
      case S2.Metrics.basin_metrics("test-basin", server: client, set: "summary") do
        {:ok, %S2.MetricSetResponse{}} -> :ok
        {:error, %S2.ErrorInfo{}} -> :ok
      end
    end
  end

  describe "stream_metrics/3" do
    test "returns metrics or error", %{client: client} do
      case S2.Metrics.stream_metrics("test-basin", "test-stream", server: client, set: "summary") do
        {:ok, %S2.MetricSetResponse{}} -> :ok
        {:error, %S2.ErrorInfo{}} -> :ok
      end
    end
  end
end

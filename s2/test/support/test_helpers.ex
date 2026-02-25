defmodule S2.TestHelpers do
  def unique_basin_name(prefix \\ "test") do
    ts = System.system_time(:microsecond)
    rand = :rand.uniform(999_999)
    "#{prefix}-#{ts}-#{rand}"
  end

  def unique_stream_name(prefix \\ "stream") do
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

  def test_client do
    S2.Config.new(base_url: "http://localhost:4243")
    |> S2.Client.new()
  end

  def cleanup_basin(client, basin_name) do
    S2.Basin.delete(client, basin_name)
  end
end

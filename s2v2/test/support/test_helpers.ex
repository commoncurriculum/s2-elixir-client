defmodule S2.TestHelpers do
  def test_client do
    config = S2.Config.new(base_url: "http://localhost:4243")
    S2.Client.new(config)
  end

  def unique_basin_name(prefix \\ "test") do
    ts = System.system_time(:millisecond)
    rand = :rand.uniform(100_000)
    "#{prefix}-#{ts}-#{rand}"
  end

  def unique_stream_name(prefix \\ "test") do
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

  def cleanup_basin(client, name) do
    S2.Basins.delete_basin(name, server: client)
  end
end

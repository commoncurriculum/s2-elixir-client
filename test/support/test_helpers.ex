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

  @doc """
  Retry a function until it returns {:ok, _} or max attempts are exhausted.
  Waits `delay` ms between attempts. Returns the last result on failure.
  """
  def retry_until_ok(fun, opts \\ []) do
    max = Keyword.get(opts, :max_attempts, 20)
    delay = Keyword.get(opts, :delay, 100)
    do_retry(fun, max, delay, nil)
  end

  defp do_retry(_fun, 0, _delay, last_result), do: last_result

  defp do_retry(fun, attempts, delay, _last_result) do
    case fun.() do
      {:ok, _} = ok -> ok
      other ->
        Process.sleep(delay)
        do_retry(fun, attempts - 1, delay, other)
    end
  end
end

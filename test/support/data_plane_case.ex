defmodule S2.DataPlaneCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import S2.TestHelpers

  using do
    quote do
      import ExUnit.CaptureLog
      import S2.DataPlaneCase
      import S2.TestHelpers
    end
  end

  setup do
    client = test_client()
    basin = unique_basin_name("data-plane")

    {:ok, _} =
      S2.Basins.create_basin(
        %S2.CreateBasinRequest{
          basin: basin,
          config: %S2.BasinConfig{create_stream_on_append: true}
        },
        server: client
      )

    on_exit(fn -> cleanup_basin(client, basin) end)
    %{basin: basin}
  end

  @doc "Starts a client for `basin` under the test, and returns its name."
  def start_client(basin, options \\ []) do
    name = :"s2_#{System.unique_integer([:positive])}"
    start_supervised!({S2, [name: name, basin: basin] ++ options}, id: name)
    name
  end

  def record(body), do: %S2.V1.AppendRecord{body: body}

  def bodies(records), do: Enum.map(records, & &1.body)

  @doc "The connection process `stream` uses."
  def connection(name, stream) do
    pool_size = :persistent_term.get({S2, name})
    Process.whereis(:"#{name}.Connection_#{:erlang.phash2(stream, pool_size)}")
  end

  @doc "Every record the listener gets until at least `count` have come."
  def listened(listener, count, received \\ []) do
    if length(received) >= count do
      received
    else
      assert_receive {S2, ^listener, {:records, records}}, 10_000
      listened(listener, count, received ++ records)
    end
  end
end

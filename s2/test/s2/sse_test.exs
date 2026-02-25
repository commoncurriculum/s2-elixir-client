defmodule S2.SSETest do
  use ExUnit.Case

  import S2.TestHelpers

  setup do
    client = test_client()
    basin = unique_basin_name()
    {:ok, _} = S2.Basin.create(client, basin)
    stream = unique_stream_name()
    {:ok, _} = S2.Stream.create(client, basin, stream)

    on_exit(fn -> cleanup_basin(test_client(), basin) end)

    %{client: client, basin: basin, stream: stream}
  end

  describe "stream/4" do
    test "returns lazy enumerable with existing records", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..2, do: %{body: Base.encode64("sse-#{i}")}
      {:ok, _} = S2.Record.append(client, basin, stream, records)

      {:ok, event_stream} = S2.SSE.stream(client, basin, stream, seq_num: 0)

      events =
        event_stream
        |> Enum.take(1)

      assert [%{event: "batch", data: data}] = events
      parsed = Jason.decode!(data)
      assert length(parsed["records"]) == 3
    end

    @tag timeout: 15_000
    test "live tailing receives new records", %{client: client, basin: basin, stream: stream} do
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("initial")}])

      {:ok, event_stream} = S2.SSE.stream(client, basin, stream, seq_num: 0)

      reader =
        Task.async(fn ->
          event_stream
          |> Enum.take(3)
        end)

      # Give SSE time to connect and receive first batch
      Process.sleep(1_000)

      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("live")}])

      events = Task.await(reader, 12_000)
      batch_events = Enum.filter(events, &(&1.event == "batch"))
      assert length(batch_events) >= 2

      all_records =
        batch_events
        |> Enum.flat_map(fn e ->
          Jason.decode!(e.data)["records"]
        end)

      bodies = Enum.map(all_records, & &1["body"])
      assert Base.encode64("initial") in bodies
      assert Base.encode64("live") in bodies
    end

    @tag timeout: 8_000
    test "receives ping events during idle", %{client: client, basin: basin, stream: stream} do
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("seed")}])

      {:ok, event_stream} = S2.SSE.stream(client, basin, stream, seq_num: 0)

      events =
        event_stream
        |> Enum.take(2)

      event_types = Enum.map(events, & &1.event)
      # First should be batch, second should be ping
      assert "batch" in event_types
      assert "ping" in event_types
    end

    test "handles error event", %{client: client, basin: basin, stream: _stream} do
      # Reading from a nonexistent stream should produce an error
      {:ok, event_stream} = S2.SSE.stream(client, basin, "nonexistent", seq_num: 0)

      events = Enum.take(event_stream, 1)

      assert [%{event: "error"}] = events
    end
  end
end

defmodule S2.RecordTest do
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

  describe "check_tail/3" do
    test "returns seq_num 0 on empty stream", %{client: client, basin: basin, stream: stream} do
      result = S2.Record.check_tail(client, basin, stream)

      assert {:ok, tail} = result
      assert tail["seq_num"] == 0
      assert tail["timestamp"] == 0
    end
  end

  describe "append/4" do
    test "appends one record and advances tail", %{client: client, basin: basin, stream: stream} do
      body = Base.encode64("hello")
      result = S2.Record.append(client, basin, stream, [%{body: body}])

      assert {:ok, ack} = result
      assert ack["start"]["seq_num"] == 0
      assert ack["end"]["seq_num"] == 1

      {:ok, tail} = S2.Record.check_tail(client, basin, stream)
      assert tail["seq_num"] == 1
    end

    test "appends batch of 5 records", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..4, do: %{body: Base.encode64("msg-#{i}")}
      {:ok, ack} = S2.Record.append(client, basin, stream, records)

      assert ack["start"]["seq_num"] == 0
      assert ack["end"]["seq_num"] == 5
    end

    test "append with match_seq_num succeeds when correct", %{client: client, basin: basin, stream: stream} do
      body = Base.encode64("first")
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: body}])

      result = S2.Record.append(client, basin, stream, [%{body: Base.encode64("second")}], match_seq_num: 1)
      assert {:ok, ack} = result
      assert ack["start"]["seq_num"] == 1
    end

    test "append with wrong match_seq_num returns 412", %{client: client, basin: basin, stream: stream} do
      body = Base.encode64("first")
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: body}])

      result = S2.Record.append(client, basin, stream, [%{body: Base.encode64("second")}], match_seq_num: 5)
      assert {:error, %S2.Error{status: 412}} = result
    end

    test "append with fencing_token sends token and returns 412 on mismatch", %{client: client, basin: basin, stream: stream} do
      # s2-lite returns 412 for any fencing_token since fence must be set via command record
      token = Base.encode64("mytoken")
      result = S2.Record.append(client, basin, stream, [%{body: Base.encode64("fenced")}], fencing_token: token)
      assert {:error, %S2.Error{status: 412}} = result
    end
  end

  describe "read/4" do
    test "reads all records from seq_num 0", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..4, do: %{body: Base.encode64("msg-#{i}")}
      {:ok, _} = S2.Record.append(client, basin, stream, records)

      {:ok, batch} = S2.Record.read(client, basin, stream, seq_num: 0)

      assert length(batch["records"]) == 5
      assert Enum.at(batch["records"], 0)["body"] == Base.encode64("msg-0")
      assert Enum.at(batch["records"], 4)["body"] == Base.encode64("msg-4")
    end

    test "reads with count limit", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..4, do: %{body: Base.encode64("msg-#{i}")}
      {:ok, _} = S2.Record.append(client, basin, stream, records)

      {:ok, batch} = S2.Record.read(client, basin, stream, seq_num: 0, count: 2)

      assert length(batch["records"]) == 2
    end

    test "reads from middle seq_num", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..4, do: %{body: Base.encode64("msg-#{i}")}
      {:ok, _} = S2.Record.append(client, basin, stream, records)

      {:ok, batch} = S2.Record.read(client, basin, stream, seq_num: 3)

      assert length(batch["records"]) == 2
      assert Enum.at(batch["records"], 0)["seq_num"] == 3
    end

    test "reads past tail returns 416", %{client: client, basin: basin, stream: stream} do
      result = S2.Record.read(client, basin, stream, seq_num: 0)

      assert {:error, %S2.Error{status: 416}} = result
    end

    test "reads with timestamp start", %{client: client, basin: basin, stream: stream} do
      records = for i <- 0..2, do: %{body: Base.encode64("msg-#{i}")}
      {:ok, _} = S2.Record.append(client, basin, stream, records)

      {:ok, batch} = S2.Record.read(client, basin, stream, timestamp: 0)

      assert length(batch["records"]) == 3
    end
  end

  describe "read long-poll" do
    @tag timeout: 10_000
    test "wait returns new record appended after read starts", %{client: client, basin: basin, stream: stream} do
      # Append one record so stream is not empty, then read from tail with wait
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("seed")}])

      reader =
        Task.async(fn ->
          S2.Record.read(client, basin, stream, seq_num: 1, wait: 5)
        end)

      # Give the read request time to start
      Process.sleep(500)

      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("delayed")}])

      {:ok, batch} = Task.await(reader, 8_000)
      assert length(batch["records"]) >= 1
      assert Enum.at(batch["records"], 0)["body"] == Base.encode64("delayed")
    end

    @tag timeout: 5_000
    test "wait with no new data returns empty after timeout", %{client: client, basin: basin, stream: stream} do
      {:ok, _} = S2.Record.append(client, basin, stream, [%{body: Base.encode64("seed")}])

      start = System.monotonic_time(:millisecond)
      result = S2.Record.read(client, basin, stream, seq_num: 1, wait: 1)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should have waited ~1 second
      assert elapsed >= 800
      # With wait, s2 returns 200 with empty records list
      assert {:ok, %{"records" => []}} = result
    end
  end
end

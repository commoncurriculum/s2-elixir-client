defmodule S2.S2S.SharedTest do
  use ExUnit.Case, async: true

  alias S2.S2S.Shared

  describe "extract_data/2" do
    test "extracts data for matching ref" do
      ref = make_ref()
      responses = [{:data, ref, "hello"}, {:data, ref, " world"}, {:status, ref, 200}]
      assert Shared.extract_data(responses, ref) == "hello world"
    end

    test "ignores data for other refs" do
      ref = make_ref()
      other = make_ref()
      responses = [{:data, other, "nope"}, {:data, ref, "yes"}]
      assert Shared.extract_data(responses, ref) == "yes"
    end

    test "returns empty binary when no data" do
      ref = make_ref()
      assert Shared.extract_data([{:status, ref, 200}], ref) == <<>>
    end
  end

  describe "records_path/1" do
    test "builds path for a stream" do
      assert Shared.records_path("my-stream") == "/v1/streams/my-stream/records"
    end

    test "URL-encodes special characters in stream name" do
      assert Shared.records_path("my stream/test") == "/v1/streams/my+stream%2Ftest/records"
    end
  end

  describe "assert_owner!/2" do
    test "returns :ok when called from owner process" do
      assert :ok = Shared.assert_owner!(self(), "Test")
    end

    test "raises when called from non-owner process" do
      other_pid = spawn(fn -> :ok end)

      assert_raise ArgumentError, ~r/must be used from the process/, fn ->
        Shared.assert_owner!(other_pid, "Test")
      end
    end
  end

  describe "open_session/3" do
    test "returns error when connection fails" do
      assert {:error, _reason} = Shared.open_session("http://localhost:1", [timeout: 100], fn _conn ->
        {:ok, :session}
      end)
    end
  end

  describe "deadline/1 and remaining/1" do
    test "remaining returns positive value for future deadline" do
      dl = Shared.deadline(1000)
      assert Shared.remaining(dl) > 0
    end

    test "remaining returns 0 for past deadline" do
      dl = Shared.deadline(0)
      Process.sleep(1)
      assert Shared.remaining(dl) == 0
    end
  end

  describe "parse_terminal_error/1" do
    test "parses a valid terminal error with code and message" do
      json = Jason.encode!(%{"code" => "not_found", "message" => "stream not found"})
      body = <<404::16-big>> <> json

      error = Shared.parse_terminal_error(body)

      assert %S2.Error{} = error
      assert error.status == 404
      assert error.code == "not_found"
      assert error.message == "stream not found"
    end

    test "handles terminal error with non-JSON body" do
      body = <<500::16-big, "not json">>

      error = Shared.parse_terminal_error(body)

      assert %S2.Error{} = error
      assert error.status == 500
      assert error.message == "not json"
    end

    test "handles terminal error body shorter than 2 bytes" do
      error = Shared.parse_terminal_error(<<0x01>>)

      assert %S2.Error{} = error
      assert error.message =~ "malformed terminal frame"
    end

    test "handles empty terminal error body" do
      error = Shared.parse_terminal_error(<<>>)

      assert %S2.Error{} = error
      assert error.message =~ "malformed terminal frame"
    end
  end

  describe "parse_http_error/2" do
    test "parses JSON error with code and message" do
      data = Jason.encode!(%{"code" => "bad_request", "message" => "invalid"})

      error = Shared.parse_http_error(400, data)

      assert %S2.Error{} = error
      assert error.status == 400
      assert error.code == "bad_request"
      assert error.message == "invalid"
    end

    test "handles non-JSON error body" do
      error = Shared.parse_http_error(500, "internal error")

      assert %S2.Error{} = error
      assert error.status == 500
      assert error.message == "internal error"
    end

    test "handles empty error body" do
      error = Shared.parse_http_error(502, "")

      assert %S2.Error{} = error
      assert error.status == 502
    end
  end

  describe "build_read_query/1" do
    test "returns empty string for no opts" do
      assert Shared.build_read_query([]) == ""
    end

    test "builds query with seq_num" do
      assert Shared.build_read_query(seq_num: 5) == "?seq_num=5"
    end

    test "builds query with multiple params" do
      query = Shared.build_read_query(seq_num: 0, count: 10)
      assert query =~ "seq_num=0"
      assert query =~ "count=10"
      assert String.starts_with?(query, "?")
    end

    test "ignores unknown params" do
      assert Shared.build_read_query(foo: "bar") == ""
    end

    test "URL-encodes parameter values to prevent injection" do
      query = Shared.build_read_query(seq_num: "0&evil=1")
      # The & should be encoded, not treated as a parameter separator
      refute query =~ "&evil"
      assert query =~ "seq_num=0%26evil%3D1"
    end
  end

  describe "process_responses/3" do
    test "accumulates status, data, and done" do
      ref = make_ref()

      responses = [
        {:status, ref, 200},
        {:headers, ref, [{"content-type", "s2s/proto"}]},
        {:data, ref, "hello"},
        {:data, ref, " world"},
        {:done, ref}
      ]

      acc = Shared.process_responses(responses, ref, %{status: nil, data: <<>>})
      assert acc.status == 200
      assert acc.data == "hello world"
      assert acc.done == true
    end

    test "ignores responses for different refs" do
      ref = make_ref()
      other = make_ref()
      responses = [{:status, other, 200}, {:data, other, "nope"}]
      acc = Shared.process_responses(responses, ref, %{status: nil, data: <<>>})
      assert acc.status == nil
      assert acc.data == <<>>
    end
  end

  describe "build_headers/3" do
    test "includes content-type by default" do
      headers = Shared.build_headers("my-basin", nil)
      assert {"content-type", "s2s/proto"} in headers
      assert {"s2-basin", "my-basin"} in headers
    end

    test "excludes content-type when opted out" do
      headers = Shared.build_headers("my-basin", nil, content_type: false)
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
      assert {"s2-basin", "my-basin"} in headers
    end

    test "includes auth header when token provided" do
      headers = Shared.build_headers("basin", "tok123")
      assert {"authorization", "Bearer tok123"} in headers
    end
  end

  describe "encode_framed/1" do
    test "encodes a protobuf struct into an S2S frame" do
      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "hello"}]
      }

      assert {:ok, frame} = Shared.encode_framed(input)

      assert is_binary(frame)
      assert byte_size(frame) > 4
      # Should be decodable
      assert {:ok, %{terminal: false}, _rest} = S2.S2S.Framing.decode(frame)
    end
  end

  describe "decode_frame/2" do
    test "decodes a framed protobuf message" do
      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "test"}]
      }

      assert {:ok, frame} = Shared.encode_framed(input)

      assert {:ok, decoded, <<>>} = Shared.decode_frame(frame, S2.V1.AppendInput)
      assert length(decoded.records) == 1
      assert hd(decoded.records).body == "test"
    end

    test "returns :incomplete for partial data" do
      assert :incomplete = Shared.decode_frame(<<0, 0>>, S2.V1.AppendInput)
    end

    test "returns error for terminal frame" do
      json = Jason.encode!(%{"code" => "err", "message" => "oops"})
      body = <<400::16-big>> <> json
      frame = S2.S2S.Framing.encode(body, terminal: true)

      assert {:error, %S2.Error{status: 400, code: "err"}} =
               Shared.decode_frame(frame, S2.V1.AppendInput)
    end
  end

  describe "decode_frame/2 error paths" do
    test "returns decode_error for invalid protobuf in non-terminal frame" do
      # Encode a frame with garbage protobuf data
      frame = S2.S2S.Framing.encode("not valid protobuf")

      assert {:error, {:decode_error, _}} = Shared.decode_frame(frame, S2.V1.AppendAck)
    end

    test "returns framing error for invalid frame" do
      assert {:error, :invalid_frame} = Shared.decode_frame(<<0, 0, 0>>, S2.V1.AppendAck)
    end
  end

  describe "decode_read_batch/1 error paths" do
    test "returns decode_error for invalid protobuf in non-terminal frame" do
      frame = S2.S2S.Framing.encode("not valid protobuf")

      assert {:error, {:decode_error, _}} = Shared.decode_read_batch(frame)
    end

    test "returns terminal error from read batch" do
      json = Jason.encode!(%{"code" => "err", "message" => "oops"})
      body = <<400::16-big>> <> json
      frame = S2.S2S.Framing.encode(body, terminal: true)

      assert {:error, %S2.Error{status: 400}} = Shared.decode_read_batch(frame)
    end

    test "returns framing error for invalid frame" do
      assert {:error, :invalid_frame} = Shared.decode_read_batch(<<0, 0, 0>>)
    end
  end

  describe "encode_framed/2 error path" do
    test "returns encode_error when struct has invalid field types" do
      # Protox.encode raises for invalid field types (e.g. string where list expected)
      # encode_framed rescues and returns {:error, {:encode_error, exception}}
      bad_input = %S2.V1.AppendInput{records: "not_a_list"}
      assert {:error, {:encode_error, %Protocol.UndefinedError{}}} = Shared.encode_framed(bad_input)
    end
  end

  describe "parse_http_error/2 with partial JSON" do
    test "handles JSON with message but no code" do
      data = Jason.encode!(%{"message" => "something broke"})
      error = Shared.parse_http_error(500, data)

      assert %S2.Error{} = error
      assert error.status == 500
      assert error.message == "something broke"
      assert error.code == nil
    end

    test "handles JSON object with neither code nor message" do
      data = Jason.encode!(%{"foo" => "bar"})
      error = Shared.parse_http_error(500, data)

      assert %S2.Error{} = error
      assert error.status == 500
      assert error.message =~ "foo"
    end
  end

  describe "decode_read_batch/1" do
    test "decodes a framed ReadBatch" do
      batch = %S2.V1.ReadBatch{
        records: [%S2.V1.SequencedRecord{seq_num: 0, body: "hello"}]
      }

      {iodata, _size} = Protox.encode!(batch)
      frame = S2.S2S.Framing.encode(IO.iodata_to_binary(iodata))

      assert {:ok, decoded, <<>>} = Shared.decode_read_batch(frame)
      assert length(decoded.records) == 1
      assert hd(decoded.records).body == "hello"
    end

    test "skips heartbeat frames" do
      heartbeat = %S2.V1.ReadBatch{records: []}
      {hb_io, _} = Protox.encode!(heartbeat)
      hb_frame = S2.S2S.Framing.encode(IO.iodata_to_binary(hb_io))

      real = %S2.V1.ReadBatch{
        records: [%S2.V1.SequencedRecord{seq_num: 0, body: "real"}]
      }

      {real_io, _} = Protox.encode!(real)
      real_frame = S2.S2S.Framing.encode(IO.iodata_to_binary(real_io))

      assert {:ok, decoded, <<>>} = Shared.decode_read_batch(hb_frame <> real_frame)
      assert hd(decoded.records).body == "real"
    end

    test "returns :incomplete for partial data" do
      assert :incomplete = Shared.decode_read_batch(<<0, 0>>)
    end
  end

  describe "check_buffer_size/1" do
    test "returns :ok for small buffers" do
      assert :ok = Shared.check_buffer_size(<<0::8>>)
      assert :ok = Shared.check_buffer_size(:crypto.strong_rand_bytes(1000))
    end

    test "returns :ok for empty buffer" do
      assert :ok = Shared.check_buffer_size(<<>>)
    end

    test "returns error for oversized buffer" do
      # Create a binary just over the 16MiB limit
      big = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
      assert {:error, :buffer_overflow} = Shared.check_buffer_size(big)
    end
  end

  describe "handle_complete_response/3" do
    test "returns {:ok, acc, conn} when done" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:data, ref, "body"}, {:done, ref}]

      assert {:ok, acc, :new_conn} =
               Shared.handle_complete_response({:ok, :new_conn, responses}, ref, %{
                 status: nil,
                 data: <<>>
               })

      assert acc.status == 200
      assert acc.data == "body"
      assert acc.done == true
    end

    test "returns :continue when not done" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:data, ref, "partial"}]

      assert {:continue, :new_conn, acc} =
               Shared.handle_complete_response({:ok, :new_conn, responses}, ref, %{
                 status: nil,
                 data: <<>>
               })

      assert acc.data == "partial"
    end

    test "returns buffer_overflow for oversized data" do
      ref = make_ref()
      big = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
      responses = [{:data, ref, big}]

      assert {:error, :buffer_overflow, :new_conn} =
               Shared.handle_complete_response({:ok, :new_conn, responses}, ref, %{
                 status: nil,
                 data: <<>>
               })
    end

    test "returns stream_error on Mint error" do
      ref = make_ref()

      assert {:error, :stream_error, :err_conn} =
               Shared.handle_complete_response(
                 {:error, :err_conn, :protocol_error, []},
                 ref,
                 %{status: nil, data: <<>>}
               )
    end

    test "returns :continue on unknown message" do
      assert {:continue, :conn, %{data: <<>>}} =
               Shared.handle_complete_response(:unknown, :conn, %{status: nil, data: <<>>})
    end
  end

  describe "handle_headers_response/2" do
    test "returns {:ok, status, data, conn} when status present" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:data, ref, "init"}]

      assert {:ok, 200, "init", :new_conn} =
               Shared.handle_headers_response({:ok, :new_conn, responses}, ref)
    end

    test "returns :continue when no status yet" do
      ref = make_ref()
      responses = [{:headers, ref, []}]

      assert {:continue, :new_conn} =
               Shared.handle_headers_response({:ok, :new_conn, responses}, ref)
    end

    test "returns stream_error on Mint error" do
      ref = make_ref()

      assert {:error, :stream_error, :err_conn} =
               Shared.handle_headers_response({:error, :err_conn, :closed, []}, ref)
    end

    test "returns :continue on unknown message" do
      assert {:continue, :conn} = Shared.handle_headers_response(:unknown, :conn)
    end
  end

  describe "close_session/2" do
    test "marks session as closed keeping existing conn" do
      session = %S2.S2S.AppendSession{conn: :original_conn, closed: false}
      closed = Shared.close_session(session)
      assert closed.closed == true
      assert closed.conn == :original_conn
    end

    test "replaces conn when provided" do
      session = %S2.S2S.ReadSession{conn: :old_conn, closed: false}
      closed = Shared.close_session(session, :new_conn)
      assert closed.closed == true
      assert closed.conn == :new_conn
    end
  end

  describe "done?/2" do
    test "returns true when :done is present for matching ref" do
      ref = make_ref()
      assert Shared.done?([{:data, ref, "hi"}, {:done, ref}], ref)
    end

    test "returns false when :done is absent" do
      ref = make_ref()
      refute Shared.done?([{:data, ref, "hi"}], ref)
    end

    test "returns false for empty list" do
      refute Shared.done?([], make_ref())
    end

    test "returns false when :done is for a different ref" do
      ref = make_ref()
      other_ref = make_ref()
      refute Shared.done?([{:done, other_ref}], ref)
    end
  end
end

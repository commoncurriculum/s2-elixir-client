defmodule S2.S2S.SharedTest do
  use ExUnit.Case, async: true

  alias S2.S2S.Shared

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

  describe "encode_framed/1" do
    test "encodes a protobuf struct into an S2S frame" do
      input = %S2.V1.AppendInput{
        records: [%S2.V1.AppendRecord{body: "hello"}]
      }

      frame = Shared.encode_framed(input)

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

      frame = Shared.encode_framed(input)

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

  describe "done?/1" do
    test "returns true when :done is present" do
      ref = make_ref()
      assert Shared.done?([{:data, ref, "hi"}, {:done, ref}])
    end

    test "returns false when :done is absent" do
      ref = make_ref()
      refute Shared.done?([{:data, ref, "hi"}])
    end

    test "returns false for empty list" do
      refute Shared.done?([])
    end
  end
end

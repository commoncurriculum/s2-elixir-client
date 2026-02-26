defmodule S2.S2S.FramingTest do
  use ExUnit.Case, async: true

  alias S2.S2S.Framing

  describe "encode/2" do
    test "encodes a regular message with no compression" do
      body = "hello"
      frame = Framing.encode(body)

      # 3-byte length prefix (flag byte + body = 1 + 5 = 6)
      # 1-byte flags (0x00 = no terminal, no compression)
      # body
      assert <<6::24-big, 0x00, "hello">> = frame
    end

    test "encodes an empty body" do
      frame = Framing.encode(<<>>)
      # length = 1 (flag byte only), flags = 0x00
      assert <<1::24-big, 0x00>> = frame
    end

    test "encodes with zstd compression" do
      frame = Framing.encode("data", compression: :zstd)
      # Frame should have zstd flag (0x20) and compressed body (not raw "data")
      assert <<_length::24-big, 0x20, _compressed::binary>> = frame
      # Compressed frame should be different from uncompressed
      uncompressed = Framing.encode("data")
      assert frame != uncompressed
    end

    test "encodes with gzip compression" do
      frame = Framing.encode("data", compression: :gzip)
      # Frame should have gzip flag (0x40) and compressed body
      assert <<_length::24-big, 0x40, _compressed::binary>> = frame
    end

    test "encodes terminal with compression" do
      frame = Framing.encode("err", terminal: true, compression: :zstd)
      # 0x80 (terminal) | 0x20 (zstd) = 0xA0
      assert <<_length::24-big, 0xA0, _compressed::binary>> = frame
    end

    test "raises on unsupported compression type" do
      assert_raise ArgumentError, ~r/unsupported compression/, fn ->
        Framing.encode("data", compression: :deflate)
      end
    end
  end

  describe "decode/1" do
    test "decodes a regular message" do
      frame = <<6::24-big, 0x00, "hello">>

      assert {:ok, %{terminal: false, compression: :none, body: "hello"}, <<>>} =
               Framing.decode(frame)
    end

    test "returns rest bytes when extra data present" do
      frame = <<6::24-big, 0x00, "hello", "extra">>
      assert {:ok, %{body: "hello"}, "extra"} = Framing.decode(frame)
    end

    test "returns :incomplete when not enough bytes" do
      assert :incomplete = Framing.decode(<<0, 0>>)
      assert :incomplete = Framing.decode(<<6::24-big, 0x00, "hel">>)
    end

    test "returns :incomplete for empty binary" do
      assert :incomplete = Framing.decode(<<>>)
    end

    test "returns error for zero-length frame" do
      # length=0 is invalid: the frame body must have at least 1 byte (flags).
      # With enough trailing bytes, this should return {:error, :invalid_frame}
      # rather than crashing with a MatchError.
      frame = <<0, 0, 0>>
      assert {:error, :invalid_frame} = Framing.decode(frame)
    end

    test "returns :incomplete when only length prefix present" do
      assert :incomplete = Framing.decode(<<0, 0, 10>>)
    end

    test "decodes unknown compression bits as error" do
      # 0x60 = both compression bits set (undefined)
      frame = <<5::24-big, 0x60, "data">>
      assert {:error, :unknown_compression} = Framing.decode(frame)
    end

    test "returns error for corrupted gzip data" do
      # Manually construct a frame with gzip flag but non-gzip body
      frame = <<5::24-big, 0x40, "data">>
      assert {:error, {:decompression_error, :gzip, _}} = Framing.decode(frame)
    end

    test "decodes multiple concatenated frames" do
      frame1 = Framing.encode("first")
      frame2 = Framing.encode("second")
      combined = frame1 <> frame2

      assert {:ok, %{body: "first"}, rest} = Framing.decode(combined)
      assert {:ok, %{body: "second"}, <<>>} = Framing.decode(rest)
    end

    test "returns :incomplete for length that exceeds available data" do
      # length=1 means we need 1 byte after the 3-byte prefix, but there are 0
      frame = <<1::24-big>>
      assert :incomplete = Framing.decode(frame)
    end
  end

  describe "terminal messages" do
    test "encode terminal message with status code and JSON" do
      status = 400
      error_json = Jason.encode!(%{"code" => "bad_request", "message" => "oops"})
      body = <<status::16-big>> <> error_json
      frame = Framing.encode(body, terminal: true)

      assert {:ok, %{terminal: true, body: ^body}, <<>>} = Framing.decode(frame)
    end

    test "decode terminal flag from frame" do
      # Flag byte 0x80 = terminal bit set
      body = <<400::16-big, "{}">>
      length = byte_size(body) + 1
      frame = <<length::24-big, 0x80>> <> body

      assert {:ok, %{terminal: true, body: ^body}, <<>>} = Framing.decode(frame)
    end

    test "terminal with compression round-trips" do
      body = "error"
      frame = Framing.encode(body, terminal: true, compression: :gzip)

      assert {:ok, %{terminal: true, compression: :gzip, body: "error"}, <<>>} =
               Framing.decode(frame)
    end
  end

  describe "round-trip" do
    test "encode then decode preserves body" do
      body = :crypto.strong_rand_bytes(100)
      frame = Framing.encode(body)
      assert {:ok, %{terminal: false, body: ^body}, <<>>} = Framing.decode(frame)
    end

    test "encode terminal then decode preserves terminal flag" do
      body = <<500::16-big, "error">>
      frame = Framing.encode(body, terminal: true)
      assert {:ok, %{terminal: true, body: ^body}, <<>>} = Framing.decode(frame)
    end

    test "round-trip with all compression types" do
      for compression <- [:none, :zstd, :gzip] do
        frame = Framing.encode("data", compression: compression)
        assert {:ok, %{compression: ^compression, body: "data"}, <<>>} = Framing.decode(frame)
      end
    end

    test "large payload round-trip" do
      body = :crypto.strong_rand_bytes(10_000)
      frame = Framing.encode(body)
      assert {:ok, %{body: ^body}, <<>>} = Framing.decode(frame)
    end

    test "large payload round-trip with gzip" do
      body = :crypto.strong_rand_bytes(10_000)
      frame = Framing.encode(body, compression: :gzip)
      assert {:ok, %{body: ^body, compression: :gzip}, <<>>} = Framing.decode(frame)
    end

    test "large payload round-trip with zstd" do
      body = :crypto.strong_rand_bytes(10_000)
      frame = Framing.encode(body, compression: :zstd)
      assert {:ok, %{body: ^body, compression: :zstd}, <<>>} = Framing.decode(frame)
    end

    test "compression actually reduces size for compressible data" do
      # Highly compressible: repeated pattern
      body = String.duplicate("hello world! ", 1000)
      none_frame = Framing.encode(body, compression: :none)
      gzip_frame = Framing.encode(body, compression: :gzip)
      zstd_frame = Framing.encode(body, compression: :zstd)

      assert byte_size(gzip_frame) < byte_size(none_frame)
      assert byte_size(zstd_frame) < byte_size(none_frame)
    end
  end

  describe "protobuf round-trip" do
    test "encode AppendInput protobuf, frame it, decode the frame, decode the protobuf" do
      input = %S2.V1.AppendInput{
        records: [
          %S2.V1.AppendRecord{body: "hello world", headers: []}
        ]
      }

      {iodata, _size} = Protox.encode!(input)
      proto_bytes = IO.iodata_to_binary(iodata)
      frame = Framing.encode(proto_bytes)

      assert {:ok, %{terminal: false, body: decoded_bytes}, <<>>} = Framing.decode(frame)
      assert {:ok, decoded} = Protox.decode(decoded_bytes, S2.V1.AppendInput)
      assert length(decoded.records) == 1
      assert hd(decoded.records).body == "hello world"
    end

    test "protobuf round-trip with gzip compression" do
      input = %S2.V1.AppendInput{
        records: [
          %S2.V1.AppendRecord{body: String.duplicate("hello ", 100), headers: []}
        ]
      }

      {iodata, _size} = Protox.encode!(input)
      proto_bytes = IO.iodata_to_binary(iodata)
      frame = Framing.encode(proto_bytes, compression: :gzip)

      assert {:ok, %{body: decoded_bytes, compression: :gzip}, <<>>} = Framing.decode(frame)
      assert {:ok, decoded} = Protox.decode(decoded_bytes, S2.V1.AppendInput)
      assert hd(decoded.records).body == String.duplicate("hello ", 100)
    end
  end
end

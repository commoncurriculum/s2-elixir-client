defmodule S2.Patterns.ConstantsTest do
  use ExUnit.Case, async: true

  alias S2.Patterns.Constants

  test "header keys are binary strings" do
    assert is_binary(Constants.frame_bytes())
    assert is_binary(Constants.frame_records())
    assert is_binary(Constants.dedupe_seq())
    assert is_binary(Constants.writer_id())
  end

  test "header keys start with underscore" do
    assert String.starts_with?(Constants.frame_bytes(), "_")
    assert String.starts_with?(Constants.frame_records(), "_")
    assert String.starts_with?(Constants.dedupe_seq(), "_")
    assert String.starts_with?(Constants.writer_id(), "_")
  end

  test "header keys match TypeScript SDK conventions" do
    assert Constants.frame_bytes() == "_frame_bytes"
    assert Constants.frame_records() == "_frame_records"
    assert Constants.dedupe_seq() == "_dedupe_seq"
    assert Constants.writer_id() == "_writer_id"
  end

  describe "find_header/2" do
    test "returns header value when found" do
      headers = [
        %S2.V1.Header{name: "_writer_id", value: "abc"},
        %S2.V1.Header{name: "_dedupe_seq", value: <<5::unsigned-big-64>>}
      ]

      assert Constants.find_header(headers, "_writer_id") == "abc"
      assert Constants.find_header(headers, "_dedupe_seq") == <<5::unsigned-big-64>>
    end

    test "returns nil when header not found" do
      headers = [%S2.V1.Header{name: "_writer_id", value: "abc"}]
      assert Constants.find_header(headers, "_missing") == nil
    end

    test "returns nil for empty headers" do
      assert Constants.find_header([], "_anything") == nil
    end
  end
end

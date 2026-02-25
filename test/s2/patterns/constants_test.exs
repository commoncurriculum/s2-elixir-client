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
end

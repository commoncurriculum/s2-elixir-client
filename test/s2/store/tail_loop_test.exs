defmodule S2.Store.TailLoopTest do
  use ExUnit.Case, async: true

  alias S2.Store.TailLoop

  describe "build_config/2" do
    test "extracts relevant fields from store config" do
      store_config = %{
        base_url: "https://example.com",
        token: "tok_123",
        basin: "my-basin",
        max_retries: 5,
        base_delay: 100,
        recv_timeout: 3000,
        serializer: %{serialize: &Function.identity/1},
        extra_field: "ignored"
      }

      config = TailLoop.build_config(store_config, "my-stream")

      assert config.base_url == "https://example.com"
      assert config.token == "tok_123"
      assert config.basin == "my-basin"
      assert config.stream == "my-stream"
      assert config.max_retries == 5
      assert config.base_delay == 100
      assert config.recv_timeout == 3000
      refute Map.has_key?(config, :serializer)
      refute Map.has_key?(config, :extra_field)
    end
  end

  describe "next_seq_num/2" do
    test "returns seq_num unchanged for empty records" do
      assert TailLoop.next_seq_num([], 5) == 5
    end

    test "returns last record's seq_num + 1" do
      records = [
        %S2.V1.SequencedRecord{seq_num: 0, body: "a"},
        %S2.V1.SequencedRecord{seq_num: 1, body: "b"},
        %S2.V1.SequencedRecord{seq_num: 2, body: "c"}
      ]

      assert TailLoop.next_seq_num(records, 0) == 3
    end

    test "ignores previous seq_num when records present" do
      records = [%S2.V1.SequencedRecord{seq_num: 10, body: "x"}]
      assert TailLoop.next_seq_num(records, 999) == 11
    end
  end
end

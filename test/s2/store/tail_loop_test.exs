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
end

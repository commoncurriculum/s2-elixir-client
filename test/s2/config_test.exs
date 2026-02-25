defmodule S2.ConfigTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "returns config with defaults" do
      config = S2.Config.new()
      assert %S2.Config{} = config
      assert config.base_url == "http://localhost:4243"
      assert config.token == nil
    end

    test "accepts base_url and token options" do
      config = S2.Config.new(base_url: "http://example.com", token: "my-token")
      assert config.base_url == "http://example.com"
      assert config.token == "my-token"
    end
  end
end

defmodule S2.ConfigTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "returns a config struct with provided values" do
      config = S2.Config.new(base_url: "http://localhost:4243", token: "test-token")

      assert %S2.Config{} = config
      assert config.base_url == "http://localhost:4243"
      assert config.token == "test-token"
    end

    test "uses default base_url when not provided" do
      config = S2.Config.new(token: "test-token")

      assert config.base_url == "http://localhost:4243"
    end

    test "token defaults to nil" do
      config = S2.Config.new(base_url: "http://localhost:4243")

      assert config.token == nil
    end
  end
end

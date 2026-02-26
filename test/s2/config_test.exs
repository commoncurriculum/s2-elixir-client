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

    test "raises on missing scheme" do
      assert_raise ArgumentError, ~r/scheme/, fn ->
        S2.Config.new(base_url: "/just/path")
      end
    end

    test "raises on non-http scheme" do
      assert_raise ArgumentError, ~r/scheme/, fn ->
        S2.Config.new(base_url: "localhost:4243")
      end
    end

    test "raises on missing host" do
      assert_raise ArgumentError, ~r/host/, fn ->
        S2.Config.new(base_url: "http://")
      end
    end

    test "raises on empty string" do
      assert_raise ArgumentError, fn ->
        S2.Config.new(base_url: "")
      end
    end
  end
end

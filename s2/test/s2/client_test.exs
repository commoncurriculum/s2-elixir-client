defmodule S2.ClientTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "creates a client from config" do
      config = S2.Config.new(base_url: "http://localhost:4243", token: "test-token")
      client = S2.Client.new(config)

      assert %S2.Client{} = client
      assert client.config == config
    end

    test "creates a client without token" do
      config = S2.Config.new(base_url: "http://localhost:4243")
      client = S2.Client.new(config)

      assert %S2.Client{} = client
      assert client.config.token == nil
    end
  end

  describe "S2.client/1 convenience" do
    test "creates a client with defaults" do
      client = S2.client()

      assert %S2.Client{} = client
      assert client.config.base_url == "http://localhost:4243"
    end

    test "creates a client with custom options" do
      client = S2.client(base_url: "http://example.com", token: "my-token")

      assert client.config.base_url == "http://example.com"
      assert client.config.token == "my-token"
    end
  end
end

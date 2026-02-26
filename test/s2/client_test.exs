defmodule S2.ClientTest do
  use ExUnit.Case
  import S2.TestHelpers

  describe "new/1" do
    test "creates a client from config" do
      config = S2.Config.new()
      client = S2.Client.new(config)
      assert %S2.Client{} = client
      assert client.config == config
    end
  end

  describe "new/1 with token" do
    test "creates client with auth headers when token provided" do
      config = S2.Config.new(base_url: "http://localhost:4243", token: "my-token")
      client = S2.Client.new(config)
      assert %S2.Client{} = client
      # Verify the auth header is set on the Req instance
      headers = client.req.headers
      assert {"authorization", ["Bearer my-token"]} in headers
    end
  end

  describe "request/1 validation" do
    test "raises without server opt" do
      assert_raise ArgumentError, ~r/server is required/, fn ->
        S2.Client.request(%{url: "/", method: "GET", response: [], opts: []})
      end
    end

    test "raises when server is not a Client struct" do
      assert_raise ArgumentError, ~r/must be an %S2.Client{}/, fn ->
        S2.Client.request(%{url: "/", method: "GET", response: [], opts: [server: :not_a_client]})
      end
    end
  end

  describe "request/1 error handling" do
    test "wraps exception transport errors in S2.Error" do
      config = S2.Config.new(base_url: "http://localhost:1")
      client = S2.Client.new(config)

      result =
        S2.Client.request(%{
          url: "/nonexistent",
          method: "GET",
          response: [{200, {S2.BasinInfo, :t}}],
          opts: [server: client]
        })

      assert {:error, %S2.Error{status: nil, message: msg}} = result
      assert is_binary(msg)
    end

    test "handles unmapped status codes" do
      # This is tested implicitly via the integration tests, but let's
      # verify the fallback path exists by testing from_response
      error = S2.Error.from_response(%{status: 418, body: "I'm a teapot"})
      assert error.status == 418
      assert error.message == "I'm a teapot"
    end
  end

  describe "request/1" do
    setup do
      client = test_client()
      basin = unique_basin_name("client-test")

      on_exit(fn ->
        cleanup_basin(client, basin)
      end)

      %{client: client, basin: basin}
    end

    test "executes a create basin request via generated operation", %{
      client: client,
      basin: basin
    } do
      result =
        S2.Basins.create_basin(%S2.CreateBasinRequest{basin: basin}, server: client)

      assert {:ok, %S2.BasinInfo{}} = result
    end
  end
end

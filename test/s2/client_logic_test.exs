defmodule S2.ClientLogicTest do
  use ExUnit.Case, async: true

  alias S2.Client

  describe "decode_schema/2" do
    test "decodes a map body into a schema struct" do
      body = %{"basin" => "my-basin"}
      result = Client.decode_schema(body, S2.BasinInfo)
      assert %S2.BasinInfo{} = result
    end

    test "returns nil for nil body" do
      assert Client.decode_schema(nil, S2.BasinInfo) == nil
    end

    test "returns non-map body as-is" do
      assert Client.decode_schema("raw string", S2.BasinInfo) == "raw string"
      assert Client.decode_schema(42, S2.BasinInfo) == 42
    end
  end

  describe "decode_field/2" do
    test "returns nil for nil value" do
      assert Client.decode_field(nil, :string) == nil
    end

    test "decodes a list of schema structs" do
      values = [%{"basin" => "b1"}, %{"basin" => "b2"}]
      result = Client.decode_field(values, [{S2.BasinInfo, :t}])
      assert length(result) == 2
      assert Enum.all?(result, &match?(%S2.BasinInfo{}, &1))
    end

    test "decodes a nested schema map" do
      value = %{"basin" => "nested"}
      result = Client.decode_field(value, {S2.BasinInfo, :t})
      assert %S2.BasinInfo{} = result
    end

    test "decodes union with null variant" do
      result = Client.decode_field(nil, {:union, [:null, {:const, "foo"}]})
      assert result == nil
    end

    test "decodes union with const variant" do
      result = Client.decode_field("active", {:union, [:null, {:const, "active"}]})
      assert result == "active"
    end

    test "decodes union with schema variant" do
      value = %{"basin" => "union-basin"}
      result = Client.decode_field(value, {:union, [:null, {S2.BasinInfo, :t}]})
      assert %S2.BasinInfo{} = result
    end

    test "returns value as-is when no union variant matches" do
      result =
        Client.decode_field("unknown", {:union, [{:const, "active"}, {:const, "inactive"}]})

      assert result == "unknown"
    end

    test "returns primitive value as-is for unknown types" do
      assert Client.decode_field("hello", :string) == "hello"
      assert Client.decode_field(42, :integer) == 42
    end
  end

  describe "handle_response/3" do
    test "returns :ok for null response spec" do
      assert :ok = Client.handle_response(204, "", [{204, :null}])
    end

    test "decodes success schema" do
      body = %{"basin" => "test"}

      assert {:ok, %S2.BasinInfo{}} =
               Client.handle_response(200, body, [{200, {S2.BasinInfo, :t}}])
    end

    test "decodes error schema" do
      body = %{"code" => "not_found", "message" => "gone"}

      assert {:error, %S2.Error{status: 404}} =
               Client.handle_response(404, body, [{404, {S2.ErrorInfo, :t}}])
    end

    test "returns error for unmapped status" do
      assert {:error, %S2.Error{status: 503}} = Client.handle_response(503, "unavailable", [])
    end
  end

  describe "to_error/2" do
    test "passes through S2.Error struct" do
      error = %S2.Error{status: 404, message: "not found"}
      assert ^error = Client.to_error(404, error)
    end

    test "converts map with code and message" do
      result = Client.to_error(400, %{code: "bad", message: "nope"})
      assert %S2.Error{status: 400, code: "bad", message: "nope"} = result
    end

    test "inspects unrecognized values" do
      result = Client.to_error(500, :something_weird)
      assert %S2.Error{status: 500} = result
      assert result.message =~ "something_weird"
    end
  end

  describe "encode_body/1" do
    test "encodes a struct to map dropping nil values" do
      struct = %S2.CreateBasinRequest{basin: "test"}
      encoded = Client.encode_body(struct)
      assert is_map(encoded)
      assert encoded.basin == "test"
      refute Map.has_key?(encoded, :config)
    end

    test "encodes a list of structs" do
      structs = [%S2.CreateBasinRequest{basin: "a"}, %S2.CreateBasinRequest{basin: "b"}]
      result = Client.encode_body(structs)
      assert length(result) == 2
    end

    test "returns primitives as-is" do
      assert Client.encode_body("hello") == "hello"
      assert Client.encode_body(42) == 42
    end
  end

  describe "handle_response/3 edge cases" do
    test "returns error with inspect for non-error/non-map decoded schema" do
      body = %{"code" => "bad", "message" => "oops"}

      assert {:error, %S2.Error{status: 400, code: "bad"}} =
               Client.handle_response(400, body, [{400, {S2.ErrorInfo, :t}}])
    end
  end

  describe "request/1 non-exception error" do
    test "handles non-exception error from Req (inspect path)" do
      # Build a client pointing to an unreachable host to trigger a connection error
      config = S2.Config.new(base_url: "http://192.0.2.1:1")
      client = S2.Client.new(config)

      result =
        S2.Client.request(%{
          url: "/test",
          method: "GET",
          response: [{200, {S2.BasinInfo, :t}}],
          opts: [server: client]
        })

      assert {:error, %S2.Error{status: nil}} = result
    end
  end

  describe "decode_field/2 union with null variant (non-nil value)" do
    test "null variant is skipped when value is not nil" do
      # The :null variant should not match when value is a string
      result = Client.decode_field("hello", {:union, [:null, {:const, "hello"}]})
      assert result == "hello"
    end
  end

  describe "request/1 with query params" do
    test "includes query params when present" do
      config = S2.Config.new(base_url: "http://localhost:4243")
      client = S2.Client.new(config)

      # Test that request handles query params (exercises the query branch)
      result =
        S2.Client.request(%{
          url: "/nonexistent",
          method: "GET",
          query: [has_more: true],
          response: [{200, {S2.ListBasinsResponse, :t}}],
          opts: [server: client]
        })

      # Will fail because path doesn't exist, but exercises the code path
      assert {:error, _} = result
    end

    test "includes body when present" do
      config = S2.Config.new(base_url: "http://localhost:4243")
      client = S2.Client.new(config)

      result =
        S2.Client.request(%{
          url: "/nonexistent",
          method: "POST",
          body: %S2.CreateBasinRequest{basin: "test"},
          response: [{200, {S2.BasinInfo, :t}}],
          opts: [server: client, basin: "my-basin"]
        })

      assert {:error, _} = result
    end
  end
end

defmodule S2.ErrorTest do
  use ExUnit.Case, async: true

  describe "from_response/1" do
    test "parses JSON error body with code and message" do
      response = %{status: 400, body: %{"code" => "invalid_argument", "message" => "bad request"}}
      error = S2.Error.from_response(response)
      assert %S2.Error{} = error
      assert error.code == "invalid_argument"
      assert error.message == "bad request"
      assert error.status == 400
    end

    test "handles string body" do
      response = %{status: 500, body: "internal error"}
      error = S2.Error.from_response(response)
      assert error.code == nil
      assert error.message == "internal error"
      assert error.status == 500
    end

    test "handles nil body" do
      response = %{status: 404, body: nil}
      error = S2.Error.from_response(response)
      assert error.status == 404
      assert error.message == nil
    end
  end

  describe "message/1" do
    test "nil status, nil code, message provided" do
      assert Exception.message(%S2.Error{message: "oops"}) == "oops"
    end

    test "nil status, nil code, nil message" do
      assert Exception.message(%S2.Error{}) == "unknown error"
    end

    test "nil status, code provided, nil message" do
      assert Exception.message(%S2.Error{code: "not_found"}) == "(not_found)"
    end

    test "nil status, code and message provided" do
      assert Exception.message(%S2.Error{code: "not_found", message: "gone"}) ==
               "(not_found): gone"
    end

    test "status provided, nil code, nil message" do
      assert Exception.message(%S2.Error{status: 500}) == "HTTP 500"
    end

    test "status provided, nil code, message provided" do
      assert Exception.message(%S2.Error{status: 500, message: "bad"}) == "HTTP 500: bad"
    end

    test "status and code provided, nil message" do
      assert Exception.message(%S2.Error{status: 404, code: "not_found"}) ==
               "HTTP 404 (not_found)"
    end

    test "all fields provided" do
      assert Exception.message(%S2.Error{status: 400, code: "invalid", message: "bad input"}) ==
               "HTTP 400 (invalid): bad input"
    end
  end
end

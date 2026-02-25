defmodule S2.ErrorTest do
  use ExUnit.Case, async: true

  describe "from_response/1" do
    test "parses error response with code and message" do
      response = %{status: 400, body: %{"code" => "bad_request", "message" => "Invalid input"}}

      error = S2.Error.from_response(response)

      assert %S2.Error{} = error
      assert error.code == "bad_request"
      assert error.message == "Invalid input"
      assert error.status == 400
    end

    test "handles response with only code" do
      response = %{status: 404, body: %{"code" => "not_found"}}

      error = S2.Error.from_response(response)

      assert error.code == "not_found"
      assert error.message == nil
      assert error.status == 404
    end

    test "handles response with string body" do
      response = %{status: 500, body: "Internal Server Error"}

      error = S2.Error.from_response(response)

      assert error.status == 500
      assert error.message == "Internal Server Error"
    end
  end
end

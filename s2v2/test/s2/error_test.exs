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
end

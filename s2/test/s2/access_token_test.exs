defmodule S2.AccessTokenTest do
  use ExUnit.Case

  import S2.TestHelpers

  describe "issue/2" do
    test "returns permission_denied on s2-lite" do
      client = test_client()

      result = S2.AccessToken.issue(client, "test-token-id", scope: %{})
      # s2-lite does not implement access token endpoints
      assert {:error, %S2.Error{code: "permission_denied"}} = result
    end
  end

  describe "list/1" do
    test "returns permission_denied on s2-lite" do
      client = test_client()

      result = S2.AccessToken.list(client)
      assert {:error, %S2.Error{code: "permission_denied"}} = result
    end
  end

  describe "revoke/2" do
    test "returns permission_denied on s2-lite" do
      client = test_client()

      result = S2.AccessToken.revoke(client, "nonexistent")
      assert {:error, %S2.Error{code: "permission_denied"}} = result
    end
  end
end

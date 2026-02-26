defmodule S2.AccessTokenTest do
  use ExUnit.Case
  import S2.TestHelpers

  setup do
    %{client: test_client()}
  end

  describe "list_access_tokens/1" do
    test "returns permission_denied on s2-lite", %{client: client} do
      assert {:error, %S2.Error{code: "permission_denied"}} =
               S2.AccessTokens.list_access_tokens(server: client)
    end
  end

  describe "issue_access_token/2" do
    test "returns permission_denied on s2-lite", %{client: client} do
      assert {:error, %S2.Error{}} =
               S2.AccessTokens.issue_access_token(
                 %S2.AccessTokenInfo{id: "test-token", scope: %S2.AccessTokenScope{}},
                 server: client
               )
    end
  end

  describe "revoke_access_token/2" do
    test "returns permission_denied on s2-lite", %{client: client} do
      assert {:error, %S2.Error{code: "permission_denied"}} =
               S2.AccessTokens.revoke_access_token("fake-token", server: client)
    end
  end
end

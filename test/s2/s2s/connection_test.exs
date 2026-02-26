defmodule S2.S2S.ConnectionTest do
  use ExUnit.Case

  describe "open/1" do
    test "opens an HTTP/2 connection to s2-lite" do
      assert {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      assert Mint.HTTP.open?(conn)
    end
  end

  describe "open/1 with options" do
    test "returns error for unreachable host" do
      assert {:error, _reason} = S2.S2S.Connection.open("http://localhost:1", timeout: 100)
    end
  end

  describe "auth_headers/1" do
    test "returns empty list for nil token" do
      assert S2.S2S.Connection.auth_headers(nil) == []
    end

    test "returns authorization header for token" do
      assert S2.S2S.Connection.auth_headers("my-token") == [
               {"authorization", "Bearer my-token"}
             ]
    end
  end

  describe "close/1" do
    test "closes a connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      assert {:ok, _conn} = S2.S2S.Connection.close(conn)
    end
  end
end

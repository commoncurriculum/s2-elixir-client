defmodule S2.S2S.ConnectionTest do
  use ExUnit.Case

  describe "open/1" do
    test "opens an HTTP/2 connection to s2-lite" do
      assert {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      assert Mint.HTTP.open?(conn)
    end
  end

  describe "close/1" do
    test "closes a connection" do
      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")
      assert {:ok, _conn} = S2.S2S.Connection.close(conn)
    end
  end
end

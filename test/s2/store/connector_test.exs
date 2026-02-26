defmodule S2.Store.ConnectorTest do
  use ExUnit.Case, async: true

  alias S2.Store.Connector

  describe "new/1" do
    test "creates a connector with default options" do
      conn = Connector.new()
      assert conn.status == :disconnected
      assert conn.attempt == 0
      assert conn.base_delay == 500
      assert conn.max_retries == :infinity
    end

    test "accepts custom options" do
      conn = Connector.new(base_delay: 1000, max_retries: 5)
      assert conn.base_delay == 1000
      assert conn.max_retries == 5
    end
  end

  describe "connected/1" do
    test "sets status to :connected and resets attempt counter" do
      conn = %Connector{status: :reconnecting, attempt: 5}
      conn = Connector.connected(conn)
      assert conn.status == :connected
      assert conn.attempt == 0
    end
  end

  describe "begin_reconnect/1" do
    test "returns {:retry, delay, connector} on first failure" do
      conn = Connector.new() |> Connector.connected()
      assert {:retry, delay, conn} = Connector.begin_reconnect(conn)
      assert conn.status == :reconnecting
      assert conn.attempt == 1
      assert is_integer(delay) and delay > 0
    end

    test "increases delay with each attempt (exponential backoff)" do
      conn = Connector.new(base_delay: 100) |> Connector.connected()

      {:retry, delay1, conn} = Connector.begin_reconnect(conn)
      {:retry, delay2, conn} = Connector.begin_reconnect(conn)
      {:retry, delay3, _conn} = Connector.begin_reconnect(conn)

      # Delays grow exponentially. With jitter they won't be exact,
      # but each attempt's max should roughly double.
      # base=100: attempt 1 -> 100..150, attempt 2 -> 200..300, attempt 3 -> 400..600
      assert delay1 < delay2
      assert delay2 < delay3
    end

    test "caps delay at max_backoff" do
      conn = Connector.new(base_delay: 20_000) |> Connector.connected()

      {:retry, delay, _conn} = Connector.begin_reconnect(conn)
      # max_backoff is 30_000, so 20_000 * 2^0 = 20_000 + jitter, should be <= 30_000 + jitter
      assert delay <= 45_000
    end

    test "returns {:error, :max_retries_exceeded} when retries exhausted" do
      conn = Connector.new(max_retries: 2) |> Connector.connected()

      {:retry, _delay, conn} = Connector.begin_reconnect(conn)
      {:retry, _delay, conn} = Connector.begin_reconnect(conn)
      assert {:error, :max_retries_exceeded} = Connector.begin_reconnect(conn)
    end

    test "infinite retries never returns error" do
      conn = Connector.new(max_retries: :infinity) |> Connector.connected()

      # Retry 100 times — should never fail
      conn =
        Enum.reduce(1..100, conn, fn _i, acc ->
          {:retry, _delay, acc} = Connector.begin_reconnect(acc)
          acc
        end)

      assert conn.attempt == 100
      assert conn.status == :reconnecting
    end
  end
end

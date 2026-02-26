defmodule S2.S2S.AppendSessionLogicTest do
  use ExUnit.Case, async: true

  alias S2.S2S.AppendSession
  alias S2.S2S.Shared

  # Build a minimal session struct for testing pure logic
  defp make_session(opts \\ []) do
    ref = Keyword.get(opts, :request_ref, make_ref())

    %AppendSession{
      conn: :fake_conn,
      request_ref: ref,
      owner_pid: self(),
      basin: "test-basin",
      stream: "test-stream",
      recv_timeout: 5000,
      compression: :none,
      closed: false,
      data: <<>>
    }
  end

  describe "handle_ack_response/3" do
    test "decodes a complete ack from responses" do
      session = make_session()

      # Build a real framed AppendAck
      ack = %S2.V1.AppendAck{
        start: %S2.V1.StreamPosition{seq_num: 0, timestamp: 100},
        end: %S2.V1.StreamPosition{seq_num: 1, timestamp: 100}
      }

      {:ok, frame} = Shared.encode_framed(ack)
      responses = [{:data, session.request_ref, frame}]

      assert {:ok, decoded_ack, updated_session} =
               AppendSession.handle_ack_response({:ok, :new_conn, responses}, session, <<>>)

      assert decoded_ack.start.seq_num == 0
      assert updated_session.conn == :new_conn
    end

    test "returns :continue on incomplete data" do
      session = make_session()
      # Partial frame data
      responses = [{:data, session.request_ref, <<0, 0, 10>>}]

      assert {:continue, updated_session, _acc} =
               AppendSession.handle_ack_response({:ok, :new_conn, responses}, session, <<>>)

      assert updated_session.conn == :new_conn
    end

    test "returns error on buffer overflow" do
      session = make_session()
      big = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
      responses = [{:data, session.request_ref, big}]

      assert {:error, :buffer_overflow, closed_session} =
               AppendSession.handle_ack_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end

    test "returns stream_error on Mint error" do
      session = make_session()

      assert {:error, :stream_error, closed_session} =
               AppendSession.handle_ack_response(
                 {:error, :new_conn, :protocol_error, []},
                 session,
                 <<>>
               )

      assert closed_session.closed == true
    end

    test "returns :continue on :unknown message" do
      session = make_session()

      assert {:continue, ^session, <<>>} =
               AppendSession.handle_ack_response(:unknown, session, <<>>)
    end

    test "returns incomplete_frame when done but data incomplete" do
      session = make_session()
      # Partial frame + done signal
      responses = [
        {:data, session.request_ref, <<0, 0, 10>>},
        {:done, session.request_ref}
      ]

      assert {:error, :incomplete_frame, closed_session} =
               AppendSession.handle_ack_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end

    test "returns error on terminal frame" do
      session = make_session()
      json = Jason.encode!(%{"code" => "err", "message" => "oops"})
      body = <<400::16-big>> <> json
      frame = S2.S2S.Framing.encode(body, terminal: true)
      responses = [{:data, session.request_ref, frame}]

      assert {:error, %S2.Error{status: 400, code: "err"}, closed_session} =
               AppendSession.handle_ack_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end
  end

  describe "receive_ack buffered data paths" do
    test "returns ack when accumulated data contains complete frame" do
      # Build a framed AppendAck as accumulated data (the acc parameter)
      ack = %S2.V1.AppendAck{
        start: %S2.V1.StreamPosition{seq_num: 0, timestamp: 100},
        end: %S2.V1.StreamPosition{seq_num: 1, timestamp: 100}
      }

      {:ok, frame} = S2.S2S.Shared.encode_framed(ack)
      session = make_session()

      # Pass the frame as acc (accumulated data from previous receive loop iterations)
      # and empty response data — the decoder should find the ack in acc
      result =
        AppendSession.handle_ack_response(
          {:ok, :new_conn, [{:data, session.request_ref, <<>>}]},
          session,
          frame
        )

      assert {:ok, %S2.V1.AppendAck{}, _session} = result
    end

    test "returns error when accumulated data contains terminal frame" do
      json = Jason.encode!(%{"code" => "err", "message" => "fail"})
      body = <<400::16-big>> <> json
      frame = S2.S2S.Framing.encode(body, terminal: true)

      session = make_session()

      result =
        AppendSession.handle_ack_response(
          {:ok, :new_conn, [{:data, session.request_ref, frame}]},
          session,
          <<>>
        )

      assert {:error, %S2.Error{status: 400}, _session} = result
    end
  end

  describe "handle_drain_response/2" do
    test "returns :ok when done signal received" do
      session = make_session()
      responses = [{:done, session.request_ref}]

      assert {:ok, updated_session} =
               AppendSession.handle_drain_response({:ok, :new_conn, responses}, session)

      assert updated_session.conn == :new_conn
    end

    test "returns :continue when no done signal" do
      session = make_session()
      responses = [{:data, session.request_ref, "stuff"}]

      assert {:continue, updated_session} =
               AppendSession.handle_drain_response({:ok, :new_conn, responses}, session)

      assert updated_session.conn == :new_conn
    end

    test "returns :ok on Mint error (best effort)" do
      session = make_session()

      assert {:ok, updated_session} =
               AppendSession.handle_drain_response({:error, :new_conn, :closed, []}, session)

      assert updated_session.conn == :new_conn
    end

    test "returns :continue on unknown message" do
      session = make_session()
      assert {:continue, ^session} = AppendSession.handle_drain_response(:unknown, session)
    end
  end
end

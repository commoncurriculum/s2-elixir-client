defmodule S2.S2S.ReadSessionLogicTest do
  use ExUnit.Case, async: true

  alias S2.S2S.ReadSession

  defp make_session(opts \\ []) do
    ref = Keyword.get(opts, :request_ref, make_ref())

    %ReadSession{
      conn: :fake_conn,
      request_ref: ref,
      owner_pid: self(),
      recv_timeout: 5000,
      closed: false,
      data: <<>>
    }
  end

  defp make_read_batch_frame(records) do
    batch = %S2.V1.ReadBatch{records: records}
    {iodata, _size} = Protox.encode!(batch)
    S2.S2S.Framing.encode(IO.iodata_to_binary(iodata))
  end

  describe "handle_batch_response/3" do
    test "decodes a complete batch from responses" do
      session = make_session()
      records = [%S2.V1.SequencedRecord{seq_num: 0, body: "hello"}]
      frame = make_read_batch_frame(records)
      responses = [{:data, session.request_ref, frame}]

      assert {:ok, batch, updated_session} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert length(batch.records) == 1
      assert hd(batch.records).body == "hello"
      assert updated_session.conn == :new_conn
    end

    test "returns :continue on incomplete data" do
      session = make_session()
      responses = [{:data, session.request_ref, <<0, 0, 10>>}]

      assert {:continue, updated_session, _acc} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert updated_session.conn == :new_conn
    end

    test "returns end_of_stream when done with incomplete data" do
      session = make_session()

      responses = [
        {:data, session.request_ref, <<>>},
        {:done, session.request_ref}
      ]

      assert {:error, :end_of_stream, closed_session} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end

    test "returns buffer_overflow on oversized data" do
      session = make_session()
      big = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
      responses = [{:data, session.request_ref, big}]

      assert {:error, :buffer_overflow, closed_session} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end

    test "returns stream_error on Mint error" do
      session = make_session()

      assert {:error, :stream_error, closed_session} =
               ReadSession.handle_batch_response(
                 {:error, :new_conn, :protocol_error, []},
                 session,
                 <<>>
               )

      assert closed_session.closed == true
    end

    test "returns :continue on unknown message" do
      session = make_session()

      assert {:continue, ^session, <<>>} =
               ReadSession.handle_batch_response(:unknown, session, <<>>)
    end

    test "returns error on terminal frame" do
      session = make_session()
      json = Jason.encode!(%{"code" => "err", "message" => "oops"})
      body = <<400::16-big>> <> json
      frame = S2.S2S.Framing.encode(body, terminal: true)
      responses = [{:data, session.request_ref, frame}]

      assert {:error, %S2.Error{status: 400}, closed_session} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end

    test "returns decode error for bad protobuf in frame" do
      session = make_session()
      frame = S2.S2S.Framing.encode("not valid protobuf")
      responses = [{:data, session.request_ref, frame}]

      assert {:error, {:decode_error, _}, closed_session} =
               ReadSession.handle_batch_response({:ok, :new_conn, responses}, session, <<>>)

      assert closed_session.closed == true
    end
  end

  describe "next_batch/1 with buffered decode error" do
    test "returns error when buffered data contains bad frame" do
      # Build a session with invalid protobuf data already buffered
      frame = S2.S2S.Framing.encode("not valid protobuf")

      session = %ReadSession{
        conn: :fake_conn,
        request_ref: make_ref(),
        owner_pid: self(),
        recv_timeout: 5000,
        closed: false,
        data: frame
      }

      assert {:error, {:decode_error, _}, closed_session} = ReadSession.next_batch(session)
      assert closed_session.closed == true
    end
  end
end

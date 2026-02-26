defmodule S2.S2S.ReadLogicTest do
  use ExUnit.Case, async: true

  alias S2.S2S.Read


  defp make_read_batch_frame(records) do
    batch = %S2.V1.ReadBatch{records: records}
    {iodata, _size} = Protox.encode!(batch)
    S2.S2S.Framing.encode(IO.iodata_to_binary(iodata))
  end

  describe "handle_first_batch_response/3" do
    test "decodes batch when status 200 and complete frame" do
      ref = make_ref()
      records = [%S2.V1.SequencedRecord{seq_num: 0, body: "hello"}]
      frame = make_read_batch_frame(records)
      responses = [{:status, ref, 200}, {:data, ref, frame}]
      acc = %{status: nil, data: <<>>}

      assert {:ok_cancel, batch, :new_conn, ^ref} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)

      assert length(batch.records) == 1
    end

    test "returns :continue when status 200 but incomplete data" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:data, ref, <<0, 0, 10>>}]
      acc = %{status: nil, data: <<>>}

      assert {:continue, :new_conn, _acc} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "handles complete error response (done with non-200 status)" do
      ref = make_ref()
      error_json = Jason.encode!(%{"code" => "not_found", "message" => "stream not found"})
      responses = [{:status, ref, 404}, {:data, ref, error_json}, {:done, ref}]
      acc = %{status: nil, data: <<>>}

      assert {:error, %S2.Error{status: 404, code: "not_found"}, :new_conn} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns :continue when non-200 status but not done yet" do
      ref = make_ref()
      responses = [{:status, ref, 404}, {:data, ref, "partial"}]
      acc = %{status: nil, data: <<>>}

      assert {:continue, :new_conn, _acc} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns :continue when no status yet" do
      ref = make_ref()
      responses = [{:headers, ref, []}]
      acc = %{status: nil, data: <<>>}

      assert {:continue, :new_conn, _acc} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns buffer_overflow for oversized data" do
      ref = make_ref()
      big = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)
      responses = [{:status, ref, 200}, {:data, ref, big}]
      acc = %{status: nil, data: <<>>}

      assert {:error, :buffer_overflow, :new_conn} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns stream_error on Mint error" do
      ref = make_ref()

      assert {:error, :stream_error, :err_conn} =
               Read.handle_first_batch_response(
                 {:error, :err_conn, :closed, []},
                 ref,
                 %{status: nil, data: <<>>}
               )
    end

    test "returns :continue on unknown message" do
      acc = %{status: nil, data: <<>>}

      assert {:continue, :conn, ^acc} =
               Read.handle_first_batch_response(:unknown, :conn, acc)
    end

    test "handles done with 200 and incomplete data as incomplete_frame" do
      ref = make_ref()
      responses = [{:status, ref, 200}, {:data, ref, <<0, 0, 10>>}, {:done, ref}]
      acc = %{status: nil, data: <<>>}

      assert {:error, :incomplete_frame, :new_conn} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns decode error when status 200 but frame contains bad protobuf" do
      ref = make_ref()
      # Build a non-terminal frame with garbage protobuf data
      frame = S2.S2S.Framing.encode("not valid protobuf")
      responses = [{:status, ref, 200}, {:data, ref, frame}]
      acc = %{status: nil, data: <<>>}

      assert {:error, {:decode_error, _}, :new_conn} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end

    test "returns error from handle_complete_response with decode error" do
      ref = make_ref()
      # Build a non-terminal frame with garbage protobuf, with done signal
      frame = S2.S2S.Framing.encode("not valid protobuf")
      responses = [{:status, ref, 200}, {:data, ref, frame}, {:done, ref}]
      acc = %{status: nil, data: <<>>}

      assert {:error, {:decode_error, _}, :new_conn} =
               Read.handle_first_batch_response({:ok, :new_conn, responses}, ref, acc)
    end
  end
end

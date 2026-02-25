defmodule S2 do
  @moduledoc """
  S2 Elixir SDK — Protobuf data plane + JSON control plane.

  ## Control Plane (JSON/Req)

  Basin, stream, and access token operations use generated typed structs and
  the `S2.Client` module for HTTP. Pass `server: client` in opts:

      config = S2.Config.new(base_url: "http://localhost:4243")
      client = S2.Client.new(config)

      {:ok, basin} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: "my-basin"}, server: client)
      {:ok, stream} = S2.Streams.create_stream(%S2.CreateStreamRequest{stream: "my-stream"}, server: client, basin: "my-basin")

  ## Data Plane (Protobuf/S2S/Mint)

  Append, read, and check_tail use S2S-framed protobuf over Mint HTTP/2.
  Open a connection first, then call operations:

      {:ok, conn} = S2.S2S.Connection.open("http://localhost:4243")

      # Unary append
      input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "hello"}]}
      {:ok, ack, conn} = S2.S2S.Append.call(conn, "my-basin", "my-stream", input)

      # Unary read
      {:ok, batch, conn} = S2.S2S.Read.call(conn, "my-basin", "my-stream", seq_num: 0)

      # Check tail
      {:ok, position, conn} = S2.S2S.CheckTail.call(conn, "my-basin", "my-stream")

  ## Streaming Sessions

  For long-lived streaming, use sessions:

      # Append session
      {:ok, session} = S2.S2S.AppendSession.open(conn, "my-basin", "my-stream")
      {:ok, ack, session} = S2.S2S.AppendSession.append(session, input)
      {:ok, session} = S2.S2S.AppendSession.close(session)

      # Read session
      {:ok, session} = S2.S2S.ReadSession.open(conn, "my-basin", "my-stream", seq_num: 0)
      {:ok, batch, session} = S2.S2S.ReadSession.next_batch(session)
      {:ok, session} = S2.S2S.ReadSession.close(session)

  Sessions are NOT safe to share across processes — the underlying Mint connection
  delivers messages to the owning process's mailbox.
  """
end

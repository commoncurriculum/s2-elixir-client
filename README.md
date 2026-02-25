# S2 Elixir SDK

Elixir client for the [S2](https://s2.dev) durable stream API. Protobuf data plane (append, read, check tail) over Mint HTTP/2 + JSON control plane (basins, streams, access tokens, metrics) over Req.

## Installation

```elixir
def deps do
  [
    {:s2, github: "commoncurriculum/s2-elixir-client"}
  ]
end
```

## Quick Start

```elixir
# Control plane client
config = S2.Config.new(base_url: "https://aws.s2.dev", token: "your-token")
client = S2.Client.new(config)

# Data plane connection (Mint HTTP/2)
{:ok, conn} = S2.S2S.Connection.open("https://aws.s2.dev", token: "your-token")
```

## Example: Chat App

A chat app where each room gets its own stream. Messages are Ecto embedded schemas, durably ordered, and listeners tail the stream in real time.

```elixir
# Usage
MyApp.Chat.create_room("general")

MyApp.Chat.send_message("general", "alice", "hey everyone!")
MyApp.Chat.send_message("general", "bob", "hi alice!")

# Listen to a room — streams messages as they arrive
MyApp.Chat.listen("general", fn %MyApp.Chat.Message{} = msg ->
  IO.puts("[#{msg.ts}] #{msg.user}: #{msg.text}")
end)
# [2026-02-25T14:30:00Z] alice: hey everyone!
# [2026-02-25T14:30:01Z] bob: hi alice!
# ... stays open, prints new messages as they arrive
```

Here's the implementation:

```elixir
# config/config.exs
config :my_app, :s2,
  base_url: "https://aws.s2.dev",
  token: System.get_env("S2_TOKEN")
```

```elixir
# lib/my_app/chat/message.ex
defmodule MyApp.Chat.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :user, :string
    field :text, :string
    field :ts, :string
  end

  def new(user, text) do
    %__MODULE__{user: user, text: text, ts: DateTime.utc_now() |> DateTime.to_iso8601()}
  end

  def changeset(message \\ %__MODULE__{}, attrs) do
    message
    |> cast(attrs, [:user, :text, :ts])
    |> validate_required([:user, :text])
  end

  def serializer do
    %{
      serialize: &Jason.encode!/1,
      deserialize: fn json ->
        json |> Jason.decode!() |> then(&changeset/1) |> apply_action!(:decode)
      end
    }
  end
end
```

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  s2_config = Application.fetch_env!(:my_app, :s2)

  children = [
    {MyApp.Chat, s2_config}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

```elixir
# lib/my_app/chat.ex
defmodule MyApp.Chat do
  use GenServer

  alias S2.Patterns.Serialization
  alias MyApp.Chat.Message

  @basin "my-app"

  def start_link(s2_config) do
    GenServer.start_link(__MODULE__, s2_config, name: __MODULE__)
  end

  def create_room(room) do
    GenServer.call(__MODULE__, {:create_room, room})
  end

  def send_message(room, user, text) do
    GenServer.call(__MODULE__, {:send, room, Message.new(user, text)})
  end

  # Spawns a process that tails the room stream from seq_num,
  # calling `callback` for each message as it arrives.
  def listen(room, callback, opts \\ []) do
    GenServer.call(__MODULE__, {:listen, room, callback, opts})
  end

  @impl true
  def init(s2_config) do
    {:ok, conn} = S2.S2S.Connection.open(s2_config[:base_url], token: s2_config[:token])

    {:ok, %{
      client: S2.Client.new(S2.Config.new(base_url: s2_config[:base_url], token: s2_config[:token])),
      conn: conn,
      s2_config: s2_config,
      writer: Serialization.writer(),
      serializer: Message.serializer()
    }}
  end

  @impl true
  def handle_call({:create_room, room}, _from, state) do
    result = S2.Streams.create_stream(
      %S2.CreateStreamRequest{stream: "chat/#{room}"},
      server: state.client, basin: @basin
    )
    {:reply, result, state}
  end

  def handle_call({:send, room, message}, _from, state) do
    {input, writer} = Serialization.prepare(state.writer, message, state.serializer)
    {:ok, session} = S2.S2S.AppendSession.open(state.conn, @basin, "chat/#{room}")
    {:ok, ack, session} = S2.S2S.AppendSession.append(session, input)
    {:ok, session} = S2.S2S.AppendSession.close(session)
    {:reply, {:ok, ack}, %{state | conn: session.conn, writer: writer}}
  end

  # Each listener gets its own connection and process — ReadSession
  # delivers TCP data to the owning process's mailbox.
  def handle_call({:listen, room, callback, opts}, _from, state) do
    serializer = state.serializer
    s2_config = state.s2_config
    seq_num = Keyword.get(opts, :from, 0)

    task = Task.async(fn ->
      {:ok, conn} = S2.S2S.Connection.open(s2_config[:base_url], token: s2_config[:token])
      {:ok, session} = S2.S2S.ReadSession.open(conn, @basin, "chat/#{room}", seq_num: seq_num)
      tail_loop(session, serializer, callback)
    end)

    {:reply, {:ok, task}, state}
  end

  defp tail_loop(session, serializer, callback, reader \\ Serialization.reader()) do
    case S2.S2S.ReadSession.next_batch(session) do
      {:ok, batch, session} ->
        {messages, reader} = Serialization.decode(reader, batch.records, serializer)
        Enum.each(messages, callback)
        tail_loop(session, serializer, callback, reader)

      {:error, :end_of_stream, _session} ->
        :ok
    end
  end
end
```

## Control Plane

All control plane functions take an opts keyword list with `server: client` (and `basin: "name"` where required).

### Basins

```elixir
{:ok, basins}  = S2.Basins.list_basins(server: client)
{:ok, basin}   = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: "my-basin"}, server: client)
{:ok, config}  = S2.Basins.get_basin_config("my-basin", server: client)
:ok            = S2.Basins.delete_basin("my-basin", server: client)
```

### Streams

```elixir
{:ok, streams} = S2.Streams.list_streams(server: client, basin: "my-basin")
{:ok, stream}  = S2.Streams.create_stream(%S2.CreateStreamRequest{stream: "my-stream"}, server: client, basin: "my-basin")
{:ok, config}  = S2.Streams.get_stream_config("my-stream", server: client, basin: "my-basin")
:ok            = S2.Streams.delete_stream("my-stream", server: client, basin: "my-basin")
```

### Access Tokens

```elixir
{:ok, token}  = S2.AccessTokens.issue_access_token(%S2.AccessTokenScope{...}, server: client)
{:ok, tokens} = S2.AccessTokens.list_access_tokens(server: client)
:ok           = S2.AccessTokens.revoke_access_token("token-id", server: client)
```

### Metrics

```elixir
{:ok, metrics} = S2.Metrics.account_metrics(server: client)
{:ok, metrics} = S2.Metrics.basin_metrics("my-basin", server: client)
{:ok, metrics} = S2.Metrics.stream_metrics("my-basin", "my-stream", server: client)
```

## Data Plane

Data plane operations use S2S-framed protobuf over a persistent Mint HTTP/2 connection. All calls return an updated `conn` for connection reuse.

### Single Request

```elixir
{:ok, conn} = S2.S2S.Connection.open("https://aws.s2.dev")

# Append records
input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "hello"}]}
{:ok, ack, conn} = S2.S2S.Append.call(conn, "my-basin", "my-stream", input)

# Read records
{:ok, batch, conn} = S2.S2S.Read.call(conn, "my-basin", "my-stream", seq_num: 0)

# Check tail position
{:ok, position, conn} = S2.S2S.CheckTail.call(conn, "my-basin", "my-stream")
```

### Streaming Append

```elixir
{:ok, session} = S2.S2S.AppendSession.open(conn, "my-basin", "my-stream")

input = %S2.V1.AppendInput{records: [%S2.V1.AppendRecord{body: "event-1"}]}
{:ok, ack, session} = S2.S2S.AppendSession.append(session, input)

{:ok, session} = S2.S2S.AppendSession.close(session)
```

### Streaming Read

```elixir
{:ok, session} = S2.S2S.ReadSession.open(conn, "my-basin", "my-stream", seq_num: 0)

{:ok, batch, session} = S2.S2S.ReadSession.next_batch(session)
# batch.records contains the records

{:ok, session} = S2.S2S.ReadSession.close(session)
```

Read options: `:seq_num`, `:count`, `:wait`, `:until`, `:clamp`, `:tail_offset`.

### Process Affinity

Streaming sessions are **not safe to share across processes**. The underlying Mint connection delivers TCP messages to the owning process's mailbox. Create and use sessions within the same process.

## Patterns

Higher-level helpers that handle chunking, framing, deduplication, and serialization so you don't have to work with raw `AppendRecord` structs. Mirrors the [TypeScript SDK patterns](https://github.com/s2-streamstore/s2-sdk-typescript/tree/main/packages/patterns).

### Writing

`Serialization.prepare/3` takes any term, serializes it, splits large messages into sub-1 MiB chunks, frames multi-chunk messages with reassembly headers, and stamps each record with a writer ID + sequence number for deduplication.

```elixir
alias S2.Patterns.Serialization

serializer = %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1}
writer = Serialization.writer()

{input, writer} = Serialization.prepare(writer, %{"event" => "signup", "user" => "alice"}, serializer)
{:ok, ack, conn} = S2.S2S.Append.call(conn, "my-basin", "my-stream", input)

# Large messages (> 1 MiB) are automatically chunked across multiple records
{input, writer} = Serialization.prepare(writer, %{"image" => large_binary}, serializer)
{:ok, ack, conn} = S2.S2S.Append.call(conn, "my-basin", "my-stream", input)
```

### Reading

`Serialization.decode/3` reassembles chunked messages, filters duplicates (from retried appends), and deserializes back into terms.

```elixir
reader = Serialization.reader()

{:ok, batch, conn} = S2.S2S.Read.call(conn, "my-basin", "my-stream", seq_num: 0)
{messages, reader} = Serialization.decode(reader, batch.records, serializer)
# messages is a list of decoded terms, with duplicates removed
```

### What the pipeline does

| Step | Write side | Read side |
|------|-----------|-----------|
| 1 | Serialize term to binary | Filter duplicate records |
| 2 | Chunk binary into sub-1 MiB pieces | Reassemble chunks into complete message |
| 3 | Frame chunks with reassembly headers | Deserialize binary back to term |
| 4 | Stamp with writer ID + dedupe sequence | |

## Architecture

| Layer | Transport | Encoding | Library |
|-------|-----------|----------|---------|
| Control plane (basins, streams, tokens, metrics) | HTTP/1.1 or 2 | JSON | Req |
| Data plane (append, read, check tail) | HTTP/2 | S2S-framed Protobuf | Mint |

## License

MIT

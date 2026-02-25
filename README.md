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

## Example: Chat App

A chat app where each room gets its own stream. Messages are Ecto embedded schemas, durably ordered, and listeners tail the stream in real time.

```elixir
alias MyApp.Chat
alias MyApp.Chat.Message

# Create rooms (each becomes its own S2 stream)
Chat.create_room("general")
Chat.create_room("random")

# Append typed messages
Chat.append("general", Message.new(user: "alice", text: "hey everyone!"))
Chat.append("general", Message.new(user: "bob", text: "hi alice!"))
Chat.append("random", Message.new(user: "alice", text: "anyone here?"))

# Listen to a room — tails the stream, calling your function for each message
Chat.listen("general", fn %Message{} = msg ->
  IO.puts("[#{msg.ts}] #{msg.user}: #{msg.text}")
end)
# [2026-02-25T14:30:00Z] alice: hey everyone!
# [2026-02-25T14:30:01Z] bob: hi alice!
# ... stays open, prints new messages as they arrive
```

Here's the implementation. `S2.Store` manages connections, serialization, and session lifecycle — like `Ecto.Repo` for streams.

```elixir
# config/config.exs
config :my_app, MyApp.S2,
  base_url: "https://aws.s2.dev",
  token: System.get_env("S2_TOKEN")
```

```elixir
# lib/my_app/s2.ex
defmodule MyApp.S2 do
  use S2.Store,
    otp_app: :my_app,
    basin: "my-app"
end
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

  def new(attrs) do
    %__MODULE__{}
    |> changeset(Map.new(attrs) |> Map.put_new(:ts, DateTime.utc_now() |> DateTime.to_iso8601()))
    |> apply_action!(:new)
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
  children = [
    MyApp.S2
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

```elixir
# lib/my_app/chat.ex
defmodule MyApp.Chat do
  use MyApp.S2, serializer: MyApp.Chat.Message.serializer()

  def create_room(room), do: create_stream("chat/#{room}")
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

### How `S2.Store` works

When you call `MyApp.S2.append("chat/general", message)`, here's what happens:

```
MyApp.S2 (Supervisor)
├── Registry          — maps stream names to worker pids
├── DynamicSupervisor — owns stream workers
│   ├── StreamWorker("chat/general")  — own connection + open AppendSession
│   ├── StreamWorker("chat/random")   — own connection + open AppendSession
│   └── ...started lazily on first append
├── ControlPlane      — shared JSON client for create/delete stream
└── listener Tasks    — each spawned with own connection + ReadSession
```

- **One process per stream.** Each stream gets its own `StreamWorker` GenServer with a dedicated Mint HTTP/2 connection and a persistent `AppendSession`. Appends to different streams run in parallel.
- **Workers start lazily.** The first `append("chat/general", ...)` starts a worker for that stream. Subsequent appends reuse the open session — no handshake overhead.
- **Listeners are independent.** Each `listen` call spawns a Task with its own connection and `ReadSession`, tailing the stream and calling your callback as messages arrive. This is required because Mint delivers TCP data to the owning process's mailbox.
- **Control plane is shared.** `create_stream` and `delete_stream` go through a single `ControlPlane` GenServer using the JSON/Req client. These are infrequent operations that don't need per-stream isolation.

### Protocol layers

| Layer | Transport | Encoding | Library |
|-------|-----------|----------|---------|
| `S2.Store` | Managed | Managed | — |
| Control plane (basins, streams, tokens, metrics) | HTTP/1.1 or 2 | JSON | Req |
| Data plane (append, read, check tail) | HTTP/2 | S2S-framed Protobuf | Mint |

`S2.Store` is the recommended way to use the SDK. The control and data plane modules below it are available if you need lower-level access.

## License

MIT

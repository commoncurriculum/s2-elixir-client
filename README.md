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

## Example: Event Log

Create a stream, write some events, and read them back.

```elixir
# Setup
config = S2.Config.new(base_url: "https://aws.s2.dev", token: "your-token")
client = S2.Client.new(config)

# Create a basin and stream
{:ok, _} = S2.Basins.create_basin(%S2.CreateBasinRequest{basin: "my-app"}, server: client)
{:ok, _} = S2.Streams.create_stream(%S2.CreateStreamRequest{stream: "events"},
  server: client, basin: "my-app")

# Connect to the data plane
{:ok, conn} = S2.S2S.Connection.open("https://aws.s2.dev", token: "your-token")

# Write some events
events = [
  %S2.V1.AppendRecord{body: Jason.encode!(%{type: "signup", user: "alice"})},
  %S2.V1.AppendRecord{body: Jason.encode!(%{type: "login", user: "alice"})},
  %S2.V1.AppendRecord{body: Jason.encode!(%{type: "signup", user: "bob"})}
]

input = %S2.V1.AppendInput{records: events}
{:ok, ack, conn} = S2.S2S.Append.call(conn, "my-app", "events", input)
# ack.start_seq_num is the sequence number of the first record written

# Read them back from the beginning
{:ok, batch, conn} = S2.S2S.Read.call(conn, "my-app", "events", seq_num: 0)

for record <- batch.records do
  IO.puts("seq=#{record.seq_num} #{record.body}")
end
# seq=0 {"type":"signup","user":"alice"}
# seq=1 {"type":"login","user":"alice"}
# seq=2 {"type":"signup","user":"bob"}
```

For high-throughput or long-lived workloads, use streaming sessions instead of single requests — see [Streaming Append](#streaming-append) and [Streaming Read](#streaming-read) below.

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

# S2 Elixir SDK

Elixir client for [S2](https://s2.dev), the durable stream API.

- **Data plane** (append, read, check tail, follow a stream): S2S-framed protobuf over HTTP/2 ([Mint](https://github.com/elixir-mint/mint)), from a small pool of connection processes.
- **Control plane** (basins, streams, access tokens, metrics): JSON over [Req](https://github.com/wojtekmach/req).

## Installation

```elixir
def deps do
  [
    {:s2_client, "~> 1.0"}
  ]
end
```

## Data plane

Start a client for one basin under your supervisor, with a name:

```elixir
children = [
  {S2,
   name: MyApp.S2,
   basin: "my-basin",
   token: System.fetch_env!("S2_TOKEN"),
   basin_endpoint: "https://{basin}.b.s2.dev"}
]
```

Then call it by that name from any process:

```elixir
records = [%S2.V1.AppendRecord{body: "hello"}]
{:ok, %S2.V1.AppendAck{start: %{seq_num: 0}, end: %{seq_num: 1}}} =
  S2.append(MyApp.S2, "chat/general", records)

{:ok, %S2.V1.ReadBatch{records: [%{seq_num: 0, body: "hello"}]}} =
  S2.read(MyApp.S2, "chat/general", seq_num: 0)

{:ok, %S2.V1.StreamPosition{seq_num: 1}} = S2.check_tail(MyApp.S2, "chat/general")
```

Follow a stream; the records come to the calling process as messages:

```elixir
{:ok, listener} = S2.listen(MyApp.S2, "chat/general", from: 0)   # or from: :tail

receive do
  {S2, ^listener, {:records, [%S2.V1.SequencedRecord{seq_num: 0, body: "hello"}]}} -> :ok
  {S2, ^listener, {:error, %S2.Error{}}} -> :refused_for_good
end

:ok = S2.stop_listener(MyApp.S2, "chat/general", listener)
```

What a caller can count on:

- **An append is one unit.** Its records (at most 1000 and 1 MiB) land together, in order, and the ack carries that call's own range.
- **`{:ok, ack}` or a real answer.** A dropped connection, a reset, or S2 asking to reconnect is retried on a new session with the same bytes. A caller only sees `{:error, %S2.Error{}}` when S2 refuses the records for good, or `{:error, :timeout}` when its `:timeout` (default 5 000 ms) passes, and then the records may or may not have been appended.
- **Retries can duplicate.** A batch S2 wrote but never acknowledged is written again. `S2.Patterns` (below) stamps records so readers drop the copies.
- **A listener never skips and never repeats.** A dropped or silent read session is opened again from after the last record it delivered. It ends only when S2 refuses the read, or the listening process exits.
- **Appends to one stream keep their order**, from any number of callers: a stream always uses the same connection.

### Options

| Option | Default | What it does |
|---|---|---|
| `:name` | required | The name every call takes. |
| `:basin` | required | |
| `:basin_endpoint` | `"http://localhost:4243"` | Where records go. `{basin}` is replaced by the basin's name; without it, the basin goes in an `s2-basin` header, as S2 Lite needs. |
| `:token` | `nil` | Bearer token. |
| `:pool_size` | `4` | HTTP/2 connections. |
| `:max_sent_bytes` | 5 MiB | Unacknowledged bytes per stream before new batches wait. |
| `:idle_after` | 5 000 ms | An append session with nothing to send this long is closed. |
| `:heartbeat_deadline` | 20 000 ms | A read session silent this long, or an append unacknowledged this long, drops the connection. S2 sends a heartbeat at least every 15 s. |
| `:connect_timeout`, `:transport_opts` | 5 000 ms, `[]` | Passed to Mint. |

### How it works

```
{S2, name: MyApp.S2}               Supervisor
├── MyApp.S2.Connection_0          S2.Connection: one HTTP/2 connection
│     appends   "chat/general" => S2.AppendStream + its append session
│     listeners  #Ref<...>     => pid, stream, next seq_num, read session
├── MyApp.S2.Connection_1
└── ...                            a stream always maps to phash2(stream, pool_size)
```

- **One process owns each socket**, the way [Finch](https://github.com/sneako/finch) does: callers `GenServer.call` it, and it handles the socket's messages. Mint delivers socket data to the owner's mailbox, so this is the only safe shape.
- **Many streams share a connection.** Each append session and read session is one HTTP/2 request on it, so a thousand followed streams cost a few sockets, not a thousand.
- **Appends batch themselves.** `S2.AppendStream` (pure, no socket) queues calls. With nothing in flight a call goes at once, alone; while batches are in flight, calls collect until they fill a batch (1000 records or 1 MiB, never splitting a call). Batches are pipelined up to `:max_sent_bytes`, as S2's own SDKs do.
- **Each batch is encoded once.** When a session fails, its unacknowledged batches go again first, byte for byte, then new ones. A refusal for good (a 4xx terminal frame) fails only the oldest batch's callers.
- **S2's drain signal is followed.** A frame flagged "reconnect" stops new sends on that session and half-closes it once what's out is sent; the next batches go on a new session.
- **Silence is a dead connection.** A read session gets a frame (records or a heartbeat) at least every 15 s. If one is silent past `:heartbeat_deadline`, or an append waits that long for its ack, the connection is dropped and made again with backoff from 100 ms to 5 s. Every session moves to the new connection.
- **The server's request limit is respected.** S2 allows 128 open requests per connection. At the limit, an append session with nothing in flight is closed to make room; with none idle, a stream waits for a request to end. Size `:pool_size` for the streams you append to and follow at once.
- **HTTP/2 flow control is respected.** Bytes beyond the send window wait for the server's window update.

## Patterns

Records go to S2 as given. `S2.Patterns` adds what a typed message stream needs on top, mirroring the [TypeScript SDK patterns](https://github.com/s2-streamstore/s2-sdk-typescript/tree/main/packages/patterns):

| Step | Write side | Read side |
|------|-----------|-----------|
| 1 | Serialize term to binary | Filter duplicate records |
| 2 | Chunk binary into sub-1 MiB pieces | Reassemble chunks into complete message |
| 3 | Frame chunks with reassembly headers | Deserialize binary back to term |
| 4 | Stamp with writer ID + dedupe sequence | |

```elixir
alias S2.Patterns.Serialization

serializer = %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1}

# Writing: serialize, chunk, frame, and stamp for dedupe
writer = Serialization.writer()
{input, writer} = Serialization.prepare(writer, %{"event" => "signup"}, serializer)
{:ok, _ack} = S2.append(MyApp.S2, "events", input.records)

# Reading: drop duplicates, reassemble, and deserialize
reader = Serialization.reader()
{:ok, listener} = S2.listen(MyApp.S2, "events", from: 0)

receive do
  {S2, ^listener, {:records, records}} ->
    {[%{"event" => "signup"}], reader} = Serialization.decode(reader, records, serializer)
end
```

Keep one writer per process that appends, so its dedupe sequence stays in order.

## Control Plane

All control plane functions take an opts keyword list with `server: client` (and `basin: "name"` where required).

First, create a client:

```elixir
config = S2.Config.new(base_url: "https://aws.s2.dev", token: "my-token")
client = S2.Client.new(config)
```

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

Issue scoped, expiring tokens for clients. Useful for giving a browser read-only access to a specific stream (e.g. for real-time updates over SSE or a WebSocket bridge).

```elixir
# Issue a read-only token scoped to a single basin
{:ok, resp} = S2.AccessTokens.issue_access_token(
  %S2.AccessTokenInfo{
    expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
    scope: %S2.AccessTokenScope{
      basins: %{"my-basin" => %{}},
      op_groups: %S2.PermittedOperationGroups{
        stream: %S2.ReadWritePermissions{read: true, write: false}
      }
    }
  },
  server: client
)

# resp.access_token is the bearer token string — send it to the client
# The client can then connect to the S2 data plane directly to read streams

{:ok, tokens} = S2.AccessTokens.list_access_tokens(server: client)
:ok           = S2.AccessTokens.revoke_access_token("token-id", server: client)
```

You can also scope tokens to specific operations via the `ops` field (e.g. `["read", "check-tail"]`) or to specific streams via the `streams` field.

### Metrics

```elixir
{:ok, metrics} = S2.Metrics.account_metrics(server: client)
{:ok, metrics} = S2.Metrics.basin_metrics("my-basin", server: client)
{:ok, metrics} = S2.Metrics.stream_metrics("my-basin", "my-stream", server: client)
```

## Testing

Tests run against [S2 Lite](https://github.com/s2-streamstore/s2) on `localhost:4243`. The `:proxy` tests also need [Toxiproxy](https://github.com/Shopify/toxiproxy) on `localhost:8474`, and put it between the client and S2 Lite to reset connections, black-hole them, and add latency:

```sh
mix test                   # without the Toxiproxy tests
mix test --include proxy   # everything, as CI runs it
```

## License

MIT

# S2

Elixir client library for the [S2](https://s2.dev) streaming data platform. Covers the full S2 HTTP API: basin and stream management, record append/read (batch, long-poll, SSE), and access token operations.

## Installation

Add `s2` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:s2, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Create a client
client = S2.client(base_url: "http://localhost:4243", token: "your-token")

# Create a basin and stream
{:ok, _} = S2.Basin.create(client, "my-basin")
{:ok, _} = S2.Stream.create(client, "my-basin", "my-stream")

# Append records (bodies are base64-encoded)
records = [%{body: Base.encode64("hello")}, %{body: Base.encode64("world")}]
{:ok, ack} = S2.Record.append(client, "my-basin", "my-stream", records)

# Read records (batch)
{:ok, batch} = S2.Record.read(client, "my-basin", "my-stream", seq_num: 0)

# Read records (long-poll)
{:ok, batch} = S2.Record.read(client, "my-basin", "my-stream", seq_num: 0, wait: 5)

# Read records (SSE streaming)
{:ok, event_stream} = S2.SSE.stream(client, "my-basin", "my-stream", seq_num: 0)
Enum.each(event_stream, fn event ->
  IO.inspect(event)  # %S2.SSE{event: "batch", data: "...", id: "..."}
end)

# Check tail
{:ok, tail} = S2.Record.check_tail(client, "my-basin", "my-stream")
```

## Module structure

- `lib/s2.ex` -- Top-level convenience API (`S2.client/1`)
- `lib/s2/config.ex` -- Connection config struct
- `lib/s2/client.ex` -- HTTP client (Req-based), auth headers, base URL routing, account/basin request helpers
- `lib/s2/error.ex` -- Error struct + response parser
- `lib/s2/basin.ex` -- Basin CRUD (create, list, delete, get_config, reconfigure)
- `lib/s2/stream.ex` -- Stream CRUD (create, list, delete, get_config, reconfigure)
- `lib/s2/record.ex` -- Append (with match_seq_num, fencing_token), read (batch, long-poll), check_tail
- `lib/s2/access_token.ex` -- Issue, list, revoke tokens
- `lib/s2/sse.ex` -- SSE stream parsing via ETS-backed message relay, lazy enumerable

## Testing

All tests run against s2-lite on localhost. No mocks, no spies, no Bypass.

```bash
# Start s2-lite
s2 lite --port 4243

# Run tests
mix test
```

Each test creates uniquely-named basins/streams and cleans up after itself.

## s2-lite limitations

The following behaviors differ from production S2 when running against s2-lite:

- **Basin/stream config endpoints return 404.** `get_config` and `reconfigure` for both basins and streams are not implemented.
- **Access token endpoints return "permission_denied" / "Not implemented".** `issue`, `list`, and `revoke` all fail.
- **Fencing tokens always return 412.** The `fencing_token` option on append always produces a `fencing_token_mismatch` error because fences must be set via command records, which s2-lite does not support.
- **Deleted streams still appear in list.** After deleting a stream, it remains in list results with a non-nil `deleted_at` field.
- **Reading an empty stream returns 416.** A `GET` on records with `seq_num: 0` when the stream has no records returns HTTP 416 (Range Not Satisfiable). With the `wait` param, it returns 200 with an empty records list instead.

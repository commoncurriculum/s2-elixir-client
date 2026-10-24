defmodule S2 do
  @moduledoc """
  Elixir client for [S2](https://s2.dev), the durable stream API.

  ## Data plane

  Start a client for one basin under your supervisor, with a name:

      children = [
        {S2,
         name: MyApp.S2,
         basin: "my-basin",
         token: System.fetch_env!("S2_TOKEN"),
         basin_endpoint: "https://{basin}.b.s2.dev"}
      ]

  Then call it by that name:

      records = [%S2.V1.AppendRecord{body: "hello"}]
      {:ok, %S2.V1.AppendAck{}} = S2.append(MyApp.S2, "my-stream", records)

      {:ok, %S2.V1.ReadBatch{records: records}} = S2.read(MyApp.S2, "my-stream", seq_num: 0)
      {:ok, %S2.V1.StreamPosition{seq_num: tail}} = S2.check_tail(MyApp.S2, "my-stream")

      {:ok, listener} = S2.listen(MyApp.S2, "my-stream", from: 0)

      receive do
        {S2, ^listener, {:records, records}} -> handle(records)
        {S2, ^listener, {:error, error}} -> give_up(error)
      end

      :ok = S2.stop_listener(MyApp.S2, "my-stream", listener)

  The client holds `pool_size` HTTP/2 connections (default 4), each an
  `S2.Connection` process carrying many streams. A stream always uses the
  same one, so its appends stay in order. Concurrent appends to a stream are
  batched and pipelined, and retried on a new session with the same bytes, so
  a caller only sees an error when its timeout passes or S2 refuses the
  records for good. Records go to S2 as given: `S2.Patterns` adds
  serialization, chunking and dedupe on top.

  ## Options

    * `:name` — required; the name every call takes.
    * `:basin` — required.
    * `:basin_endpoint` — where records go; `{basin}` is replaced by the
      basin's name (default `"http://localhost:4243"`, S2 Lite). Without
      `{basin}`, the basin goes in an `s2-basin` header, as S2 Lite needs.
    * `:token` — bearer token.
    * `:pool_size` — connections (default 4).
    * `:max_sent_bytes` — unacknowledged bytes per stream (default 5 MiB).
    * `:idle_after` — milliseconds before an idle append session closes
      (default 5 000).
    * `:heartbeat_deadline` — milliseconds a read session may stay silent
      before it's opened again (default 20 000; S2 sends a heartbeat at least
      every 15 s).
    * `:connect_timeout` (default 5 000) and `:transport_opts` (default `[]`),
      passed to Mint.

  ## Control plane

  Basins, streams and access tokens use the generated modules (`S2.Basins`,
  `S2.Streams`, `S2.AccessTokens`) with an `S2.Client`:

      client = S2.Client.new(S2.Config.new(base_url: "https://aws.s2.dev", token: token))
      {:ok, _info} = S2.Streams.create_stream(%S2.CreateStreamRequest{stream: "my-stream"}, server: client, basin: "my-basin")
  """

  use Supervisor

  def start_link(options) do
    name = Keyword.fetch!(options, :name)
    Supervisor.start_link(__MODULE__, options, name: name)
  end

  @impl true
  def init(options) do
    name = Keyword.fetch!(options, :name)
    pool_size = Keyword.get(options, :pool_size, 4)
    :persistent_term.put({__MODULE__, name}, pool_size)

    children =
      Enum.map(0..(pool_size - 1), fn index ->
        config = %{
          connection: connection(name, index),
          basin: Keyword.fetch!(options, :basin),
          basin_endpoint: Keyword.get(options, :basin_endpoint, "http://localhost:4243"),
          token: Keyword.get(options, :token),
          max_sent_bytes: Keyword.get(options, :max_sent_bytes, 5 * 1024 * 1024),
          idle_after: Keyword.get(options, :idle_after, 5_000),
          heartbeat_deadline: Keyword.get(options, :heartbeat_deadline, 20_000),
          connect_timeout: Keyword.get(options, :connect_timeout, 5_000),
          transport_opts: Keyword.get(options, :transport_opts, [])
        }

        Supervisor.child_spec({S2.Connection, config}, id: index)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Appends `records` (`S2.V1.AppendRecord` structs, at most 1000 and 1 MiB)
  to `stream`, as one unit. Returns `{:ok, ack}` with these records' own
  range, `{:error, %S2.Error{}}` when S2 refuses them, or `{:error, :timeout}`
  after `:timeout` milliseconds (default 5 000), when they may or may not
  have been appended.
  """
  def append(name, stream, records, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    call(name, stream, {:append, stream, records, deadline}, timeout)
  end

  @doc """
  Reads one batch of `stream`. Options are S2's read parameters: `:seq_num`,
  `:timestamp`, `:tail_offset`, `:count`, `:bytes`, `:until`, `:clamp`,
  `:wait` (seconds to wait for records at the tail), plus `:timeout`
  (milliseconds, default 5 000, so longer than any `:wait`).
  """
  def read(name, stream, options \\ []) do
    query =
      case Keyword.take(options, [
             :seq_num,
             :timestamp,
             :tail_offset,
             :count,
             :bytes,
             :until,
             :clamp,
             :wait
           ]) do
        [] -> ""
        parameters -> "?" <> URI.encode_query(parameters)
      end

    call(name, stream, {:read, stream, query}, Keyword.get(options, :timeout, 5_000))
  end

  @doc "The position after `stream`'s last record."
  def check_tail(name, stream, options \\ []),
    do: call(name, stream, {:check_tail, stream}, Keyword.get(options, :timeout, 5_000))

  @doc """
  Follows `stream`, sending the calling process
  `{S2, listener, {:records, [%S2.V1.SequencedRecord{}]}}` for each batch, in
  order, from `:from` (a sequence number, default 0, or `:tail`). A dropped or
  silent session is opened again after the last record received. When S2
  refuses the read for good, the caller gets `{S2, listener, {:error, error}}`
  and the listener ends. It also ends when the caller exits.
  """
  def listen(name, stream, options \\ []),
    do: call(name, stream, {:listen, stream, self(), Keyword.get(options, :from, 0)}, 5_000)

  @doc "Stops a listener."
  def stop_listener(name, stream, listener),
    do: call(name, stream, {:stop_listener, listener}, 5_000)

  defp call(name, stream, message, timeout) do
    pool_size = :persistent_term.get({__MODULE__, name})
    GenServer.call(connection(name, :erlang.phash2(stream, pool_size)), message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
  end

  defp connection(name, index), do: :"#{name}.Connection_#{index}"
end

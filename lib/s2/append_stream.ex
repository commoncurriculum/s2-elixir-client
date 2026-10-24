defmodule S2.AppendStream do
  @moduledoc """
  One stream's appends inside an `S2.Connection`: the calls waiting to be
  sent, and the batches sent and not yet acknowledged. Nothing here touches a
  socket, so the connection keeps it in its state.

  Calls queue in order. `take/2` turns them into batches of at most 1000
  records and 1 MiB, never splitting a call: at once when nothing is in
  flight, and while batches are in flight only when the queue fills a whole
  batch. So a busy stream batches itself and a quiet one never waits.

  Each batch is encoded once. When a session fails, `requeue/1` puts the
  unacknowledged batches back first, and they're sent again byte for byte.
  """

  alias S2.Framing

  @max_records 1000
  @max_bytes 1024 * 1024

  # queue: %{from:, records:, bytes:, deadline:}
  # sent and resend: %{callers: [{from, count}], frame:, bytes:}, oldest first
  defstruct queue: :queue.new(), sent: :queue.new(), resend: :queue.new(), sent_bytes: 0

  def new, do: %__MODULE__{}

  @doc """
  Queues one call's records, or refuses records that can't fit one batch.
  """
  def push(stream, from, records, deadline) do
    bytes = records |> Enum.map(&metered_bytes/1) |> Enum.sum()

    cond do
      records == [] ->
        {:error, :no_records}

      length(records) > @max_records or bytes > @max_bytes ->
        {:error, :batch_too_large}

      true ->
        call = %{from: from, records: records, bytes: bytes, deadline: deadline}
        {:ok, %{stream | queue: :queue.in(call, stream.queue)}}
    end
  end

  @doc """
  The frames to send now, in order, and the stream with them counted as sent.
  Calls whose deadline is before `now` are dropped unsent: their caller has
  given up. Batches to resend go first, and nothing new is sent while
  `max_sent_bytes` are unacknowledged.
  """
  def take(stream, now, max_sent_bytes \\ 5 * 1024 * 1024) do
    resend = :queue.to_list(stream.resend)

    stream = %{
      stream
      | queue: :queue.filter(&(&1.deadline > now), stream.queue),
        resend: :queue.new(),
        sent: :queue.join(stream.sent, stream.resend),
        sent_bytes: stream.sent_bytes + (resend |> Enum.map(& &1.bytes) |> Enum.sum())
    }

    {batched, stream} = batch(stream, max_sent_bytes, [])
    {Enum.map(resend, & &1.frame) ++ batched, stream}
  end

  @doc """
  Matches an acknowledgement to the oldest sent batch. Returns
  `{[{from, ack}], stream}`, with each call's own range of the batch.
  """
  def ack(stream, %S2.V1.AppendAck{} = ack) do
    {{:value, batch}, sent} = :queue.out(stream.sent)

    {replies, _next} =
      Enum.map_reduce(batch.callers, ack.start.seq_num, fn {from, count}, start ->
        own = %{
          ack
          | start: %{ack.start | seq_num: start},
            end: %{ack.end | seq_num: start + count}
        }

        {{from, own}, start + count}
      end)

    {replies, %{stream | sent: sent, sent_bytes: stream.sent_bytes - batch.bytes}}
  end

  @doc """
  The session ended: every unacknowledged batch is sent again, first.
  """
  def requeue(stream) do
    %{stream | resend: :queue.join(stream.sent, stream.resend), sent: :queue.new(), sent_bytes: 0}
  end

  @doc """
  S2 refused the oldest sent batch for good. Returns its callers and the
  stream with the other sent batches queued to be sent again.
  """
  def refuse(stream) do
    {{:value, batch}, sent} = :queue.out(stream.sent)
    {Enum.map(batch.callers, &elem(&1, 0)), requeue(%{stream | sent: sent})}
  end

  @doc "Whether anything is queued, to resend, or unacknowledged."
  def idle?(stream),
    do:
      :queue.is_empty(stream.queue) and :queue.is_empty(stream.resend) and sent?(stream) == false

  @doc "Whether any batch is waiting for an acknowledgement."
  def sent?(stream), do: not :queue.is_empty(stream.sent)

  # S2 meters a record as 8 bytes, plus each header's name and value, plus
  # its body.
  def metered_bytes(%S2.V1.AppendRecord{headers: headers, body: body}),
    do:
      8 + 2 * length(headers) +
        (headers |> Enum.map(&(byte_size(&1.name) + byte_size(&1.value))) |> Enum.sum()) +
        byte_size(body)

  defp batch(stream, max_sent_bytes, frames) do
    {calls, rest} = fill(stream.queue, [], 0, 0)
    bytes = calls |> Enum.map(& &1.bytes) |> Enum.sum()
    records = Enum.flat_map(calls, & &1.records)
    full = not :queue.is_empty(rest) or length(records) == @max_records

    if calls != [] and
         (not sent?(stream) or (full and stream.sent_bytes + bytes <= max_sent_bytes)) do
      {:ok, iodata, _size} = Protox.encode(%S2.V1.AppendInput{records: records})
      frame = Framing.encode(IO.iodata_to_binary(iodata))

      batch = %{
        callers: Enum.map(calls, &{&1.from, length(&1.records)}),
        frame: frame,
        bytes: bytes
      }

      stream = %{
        stream
        | queue: rest,
          sent: :queue.in(batch, stream.sent),
          sent_bytes: stream.sent_bytes + bytes
      }

      batch(stream, max_sent_bytes, [frame | frames])
    else
      {Enum.reverse(frames), stream}
    end
  end

  # The longest run of whole calls that fits one batch.
  defp fill(queue, calls, count, bytes) do
    case :queue.peek(queue) do
      {:value, call}
      when count + length(call.records) <= @max_records and bytes + call.bytes <= @max_bytes ->
        fill(:queue.drop(queue), [call | calls], count + length(call.records), bytes + call.bytes)

      _full_or_empty ->
        {Enum.reverse(calls), queue}
    end
  end
end

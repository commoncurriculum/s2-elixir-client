defmodule S2.Patterns.Serialization do
  @moduledoc """
  High-level serialize/deserialize pipeline for S2 records.

  Composes chunking, framing, and deduplication into two operations:

  - `prepare/3` — serialize a term into an `AppendInput` ready to send
  - `decode/3` — decode sequenced records back into terms, with dedup + reassembly

  Accepts a serializer map with `:serialize` and `:deserialize` functions:

      serializer = %{
        serialize: &Jason.encode!/1,
        deserialize: &Jason.decode!/1
      }

      writer = Serialization.writer()
      {input, writer} = Serialization.prepare(writer, %{"event" => "click"}, serializer)
      # input is an %S2.V1.AppendInput{} ready to append

      reader = Serialization.reader()
      {messages, reader} = Serialization.decode(reader, sequenced_records, serializer)
  """

  alias S2.Patterns.{Framing, Dedupe}

  @type serializer :: S2.Store.serializer()
  @type writer :: Dedupe.Writer.t()
  @type reader :: %{filter: Dedupe.Filter.t(), assembler: Framing.Assembler.t()}

  @spec writer() :: writer()
  def writer, do: Dedupe.Writer.new()

  @spec reader() :: reader()
  def reader, do: %{filter: Dedupe.Filter.new(), assembler: Framing.Assembler.new()}

  @spec prepare(writer(), term(), serializer()) :: {S2.V1.AppendInput.t(), writer()}
  def prepare(writer, message, serializer) do
    bytes = serializer.serialize.(message)
    records = Framing.frame(bytes)
    {stamped, writer} = Dedupe.Writer.stamp_records(writer, records)
    {%S2.V1.AppendInput{records: stamped}, writer}
  end

  @doc """
  Decode sequenced records back into terms with dedup + reassembly.

  Returns a list of results and the updated reader. Each result is either
  a successfully deserialized term or `{:error, {:deserialization_error, exception}}`
  if the deserializer raised. Assembler errors produce
  `{:error, {:assembly_error, reason}}`.

  Callers should pattern match on results to handle errors:

      {results, reader} = Serialization.decode(reader, records, serializer)
      Enum.each(results, fn
        {:error, reason} -> Logger.warning("decode error: \#{inspect(reason)}")
        message -> process(message)
      end)
  """
  @spec decode(reader(), [S2.V1.SequencedRecord.t()], serializer()) :: {[term()], reader()}
  def decode(reader, records, serializer) do
    {messages, reader} =
      Enum.reduce(records, {[], reader}, fn record, {msgs, reader} ->
        case Dedupe.Filter.check(reader.filter, record) do
          :duplicate ->
            {msgs, reader}

          {:ok, filter} ->
            reader = %{reader | filter: filter}

            case Framing.Assembler.add(reader.assembler, record) do
              {:ok, data, assembler} ->
                reader = %{reader | assembler: assembler}

                case safe_deserialize(serializer, data) do
                  {:ok, message} -> {msgs ++ [message], reader}
                  {:error, _} = err -> {msgs ++ [err], reader}
                end

              {:incomplete, assembler} ->
                {msgs, %{reader | assembler: assembler}}

              {:error, reason} ->
                {msgs ++ [{:error, {:assembly_error, reason}}], reader}
            end
        end
      end)

    {messages, reader}
  end

  defp safe_deserialize(serializer, data) do
    {:ok, serializer.deserialize.(data)}
  rescue
    e -> {:error, {:deserialization_error, e}}
  end
end

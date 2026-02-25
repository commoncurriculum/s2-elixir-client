defmodule S2.Patterns.Dedupe do
  @moduledoc false

  alias S2.Patterns.Constants

  defmodule Writer do
    @moduledoc false

    @type t :: %__MODULE__{writer_id: binary(), seq: non_neg_integer()}
    defstruct [:writer_id, seq: 0]

    @spec new() :: t()
    def new do
      %__MODULE__{writer_id: :crypto.strong_rand_bytes(16)}
    end

    @spec stamp(t(), S2.V1.AppendRecord.t()) :: {S2.V1.AppendRecord.t(), t()}
    def stamp(%__MODULE__{} = writer, %S2.V1.AppendRecord{} = record) do
      headers =
        record.headers ++
          [
            %S2.V1.Header{name: Constants.writer_id(), value: writer.writer_id},
            %S2.V1.Header{name: Constants.dedupe_seq(), value: <<writer.seq::unsigned-big-64>>}
          ]

      {%{record | headers: headers}, %{writer | seq: writer.seq + 1}}
    end

    @spec stamp_records(t(), [S2.V1.AppendRecord.t()]) :: {[S2.V1.AppendRecord.t()], t()}
    def stamp_records(%__MODULE__{} = writer, records) do
      {stamped, writer} =
        Enum.map_reduce(records, writer, fn record, w ->
          stamp(w, record)
        end)

      {stamped, writer}
    end
  end

  defmodule Filter do
    @moduledoc false

    @type t :: %__MODULE__{seen: %{binary() => non_neg_integer()}}
    defstruct seen: %{}

    @spec new() :: t()
    def new, do: %__MODULE__{}

    @spec check(t(), S2.V1.SequencedRecord.t()) :: {:ok, t()} | :duplicate
    def check(%__MODULE__{} = filter, record) do
      case extract_dedupe_info(record.headers) do
        nil ->
          {:ok, filter}

        {writer_id, seq} ->
          case Map.get(filter.seen, writer_id) do
            nil ->
              {:ok, %{filter | seen: Map.put(filter.seen, writer_id, seq)}}

            last_seq when seq > last_seq ->
              {:ok, %{filter | seen: Map.put(filter.seen, writer_id, seq)}}

            _last_seq ->
              :duplicate
          end
      end
    end

    defp extract_dedupe_info(headers) do
      writer_header = Enum.find(headers, fn h -> h.name == Constants.writer_id() end)
      seq_header = Enum.find(headers, fn h -> h.name == Constants.dedupe_seq() end)

      case {writer_header, seq_header} do
        {%{value: writer_id}, %{value: <<seq::unsigned-big-64>>}} ->
          {writer_id, seq}

        _ ->
          nil
      end
    end
  end
end

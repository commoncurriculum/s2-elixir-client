defmodule S2.Patterns.Framing do
  @moduledoc false

  alias S2.Patterns.{Chunking, Constants}

  @spec frame(binary()) :: [S2.V1.AppendRecord.t()]
  def frame(data) do
    chunks = Chunking.chunk(data)

    case chunks do
      [single] ->
        [%S2.V1.AppendRecord{headers: [], body: single}]

      _ ->
        total_bytes = byte_size(data)
        total_records = length(chunks)

        chunks
        |> Enum.with_index()
        |> Enum.map(fn {chunk, idx} ->
          headers =
            if idx == 0 do
              [
                %S2.V1.Header{name: Constants.frame_bytes(), value: encode_u64(total_bytes)},
                %S2.V1.Header{name: Constants.frame_records(), value: encode_u64(total_records)}
              ]
            else
              []
            end

          %S2.V1.AppendRecord{headers: headers, body: chunk}
        end)
    end
  end

  defp encode_u64(value), do: <<value::unsigned-big-64>>

  defmodule Assembler do
    @moduledoc false

    @type t :: %__MODULE__{pending: nil | pending()}
    @typep pending :: %{
             total_bytes: pos_integer(),
             total_records: pos_integer(),
             chunks: [binary()],
             received: non_neg_integer()
           }

    defstruct pending: nil

    @spec new() :: t()
    def new, do: %__MODULE__{}

    @spec add(t(), S2.V1.SequencedRecord.t()) ::
            {:ok, binary(), t()} | {:incomplete, t()} | {:error, :unexpected_record}
    def add(%__MODULE__{pending: nil} = assembler, record) do
      case extract_frame_headers(record.headers) do
        nil ->
          {:ok, record.body, assembler}

        {total_bytes, total_records} ->
          pending = %{
            total_bytes: total_bytes,
            total_records: total_records,
            chunks: [record.body],
            received: 1
          }

          maybe_complete(%{assembler | pending: pending})
      end
    end

    def add(%__MODULE__{pending: pending} = assembler, record) do
      case extract_frame_headers(record.headers) do
        nil ->
          # Continuation chunk — no framing headers expected
          pending = %{pending | chunks: pending.chunks ++ [record.body], received: pending.received + 1}
          maybe_complete(%{assembler | pending: pending})

        _headers ->
          # Got a new frame start while still assembling — something is wrong
          {:error, :unexpected_record}
      end
    end

    defp maybe_complete(%{pending: %{received: n, total_records: n} = pending} = assembler) do
      data = IO.iodata_to_binary(pending.chunks)

      if byte_size(data) != pending.total_bytes do
        {:error, {:frame_size_mismatch, expected: pending.total_bytes, got: byte_size(data)}}
      else
        {:ok, data, %{assembler | pending: nil}}
      end
    end

    defp maybe_complete(assembler) do
      {:incomplete, assembler}
    end

    defp extract_frame_headers(headers) do
      bytes_header = Enum.find(headers, fn h -> h.name == S2.Patterns.Constants.frame_bytes() end)
      records_header = Enum.find(headers, fn h -> h.name == S2.Patterns.Constants.frame_records() end)

      case {bytes_header, records_header} do
        {%{value: <<bytes::unsigned-big-64>>}, %{value: <<records::unsigned-big-64>>}} ->
          {bytes, records}

        _ ->
          nil
      end
    end
  end
end

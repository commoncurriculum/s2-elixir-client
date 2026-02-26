defmodule S2.Patterns.Constants do
  @moduledoc false

  @compile {:inline, frame_bytes: 0, frame_records: 0, dedupe_seq: 0, writer_id: 0}

  def frame_bytes, do: "_frame_bytes"
  def frame_records, do: "_frame_records"
  def dedupe_seq, do: "_dedupe_seq"
  def writer_id, do: "_writer_id"

  @spec find_header([S2.V1.Header.t()], String.t()) :: binary() | nil
  def find_header(headers, name) do
    Enum.find_value(headers, fn
      %{name: ^name, value: value} -> value
      _ -> nil
    end)
  end
end

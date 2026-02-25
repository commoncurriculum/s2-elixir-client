defmodule S2.ListStreamsResponse do
  @moduledoc """
  Provides struct and type for a ListStreamsResponse
  """

  @type t :: %__MODULE__{has_more: boolean, streams: [S2.StreamInfo.t()]}

  defstruct [:has_more, :streams]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [has_more: :boolean, streams: [{S2.StreamInfo, :t}]]
  end
end

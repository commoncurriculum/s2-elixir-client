defmodule S2.CreateStreamRequest do
  @moduledoc """
  Provides struct and type for a CreateStreamRequest
  """

  @type t :: %__MODULE__{config: S2.StreamConfig.t() | nil, stream: String.t()}

  defstruct [:config, :stream]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [config: {:union, [{S2.StreamConfig, :t}, :null]}, stream: :string]
  end
end

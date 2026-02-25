defmodule S2.TimestampingReconfiguration do
  @moduledoc """
  Provides struct and type for a TimestampingReconfiguration
  """

  @type t :: %__MODULE__{mode: String.t() | nil, uncapped: boolean | nil}

  defstruct [:mode, :uncapped]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mode: {:union, [{:enum, ["client-prefer", "client-require", "arrival"]}, :null]},
      uncapped: {:union, [:boolean, :null]}
    ]
  end
end

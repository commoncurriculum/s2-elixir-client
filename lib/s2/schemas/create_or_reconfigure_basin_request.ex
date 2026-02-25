defmodule S2.CreateOrReconfigureBasinRequest do
  @moduledoc """
  Provides struct and type for a CreateOrReconfigureBasinRequest
  """

  @type t :: %__MODULE__{config: S2.BasinReconfiguration.t() | nil, scope: String.t() | nil}

  defstruct [:config, :scope]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      config: {:union, [{S2.BasinReconfiguration, :t}, :null]},
      scope: {:union, [{:const, "aws:us-east-1"}, :null]}
    ]
  end
end

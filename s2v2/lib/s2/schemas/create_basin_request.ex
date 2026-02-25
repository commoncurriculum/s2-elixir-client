defmodule S2.CreateBasinRequest do
  @moduledoc """
  Provides struct and type for a CreateBasinRequest
  """

  @type t :: %__MODULE__{
          basin: String.t(),
          config: S2.BasinConfig.t() | nil,
          scope: String.t() | nil
        }

  defstruct [:basin, :config, :scope]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      basin: :string,
      config: {:union, [{S2.BasinConfig, :t}, :null]},
      scope: {:union, [{:const, "aws:us-east-1"}, :null]}
    ]
  end
end

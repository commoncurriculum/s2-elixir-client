defmodule S2.AccumulationMetric do
  @moduledoc """
  Provides struct and type for a AccumulationMetric
  """

  @type t :: %__MODULE__{
          interval: String.t(),
          name: String.t(),
          unit: String.t(),
          values: [[any]]
        }

  defstruct [:interval, :name, :unit, :values]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      interval: {:enum, ["minute", "hour", "day"]},
      name: :string,
      unit: {:enum, ["bytes", "operations"]},
      values: [[:unknown]]
    ]
  end
end

defmodule S2.GaugeMetric do
  @moduledoc """
  Provides struct and type for a GaugeMetric
  """

  @type t :: %__MODULE__{name: String.t(), unit: String.t(), values: [[any]]}

  defstruct [:name, :unit, :values]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [name: :string, unit: {:enum, ["bytes", "operations"]}, values: [[:unknown]]]
  end
end

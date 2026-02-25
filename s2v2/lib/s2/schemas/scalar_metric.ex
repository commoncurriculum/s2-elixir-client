defmodule S2.ScalarMetric do
  @moduledoc """
  Provides struct and type for a ScalarMetric
  """

  @type t :: %__MODULE__{name: String.t(), unit: String.t(), value: number}

  defstruct [:name, :unit, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [name: :string, unit: {:enum, ["bytes", "operations"]}, value: {:number, "double"}]
  end
end

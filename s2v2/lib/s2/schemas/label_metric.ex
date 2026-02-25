defmodule S2.LabelMetric do
  @moduledoc """
  Provides struct and type for a LabelMetric
  """

  @type t :: %__MODULE__{name: String.t(), values: [String.t()]}

  defstruct [:name, :values]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [name: :string, values: [:string]]
  end
end

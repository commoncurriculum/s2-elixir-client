defmodule S2.MetricSetResponse do
  @moduledoc """
  Provides struct and type for a MetricSetResponse
  """

  @type t :: %__MODULE__{values: [S2.MetricSetResponseValues.t()]}

  defstruct [:values]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [values: [{S2.MetricSetResponseValues, :t}]]
  end
end

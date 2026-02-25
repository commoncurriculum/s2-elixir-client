defmodule S2.MetricSetResponseValues do
  @moduledoc """
  Provides struct and types for a MetricSetResponseValues
  """

  @type t :: %__MODULE__{
          accumulation: S2.AccumulationMetric.t(),
          gauge: S2.GaugeMetric.t(),
          label: S2.LabelMetric.t(),
          scalar: S2.ScalarMetric.t()
        }

  defstruct [:accumulation, :gauge, :label, :scalar]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      accumulation: {S2.AccumulationMetric, :t},
      gauge: {S2.GaugeMetric, :t},
      label: {S2.LabelMetric, :t},
      scalar: {S2.ScalarMetric, :t}
    ]
  end
end

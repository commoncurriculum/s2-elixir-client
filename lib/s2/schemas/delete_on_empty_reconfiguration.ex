defmodule S2.DeleteOnEmptyReconfiguration do
  @moduledoc """
  Provides struct and type for a DeleteOnEmptyReconfiguration
  """

  @type t :: %__MODULE__{min_age_secs: integer | nil}

  defstruct [:min_age_secs]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [min_age_secs: {:union, [{:integer, "int64"}, :null]}]
  end
end

defmodule S2.DeleteOnEmptyConfig do
  @moduledoc """
  Provides struct and type for a DeleteOnEmptyConfig
  """

  @type t :: %__MODULE__{min_age_secs: integer | nil}

  defstruct [:min_age_secs]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [min_age_secs: {:integer, "int64"}]
  end
end

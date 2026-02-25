defmodule S2.ListBasinsResponse do
  @moduledoc """
  Provides struct and type for a ListBasinsResponse
  """

  @type t :: %__MODULE__{basins: [S2.BasinInfo.t()], has_more: boolean}

  defstruct [:basins, :has_more]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [basins: [{S2.BasinInfo, :t}], has_more: :boolean]
  end
end

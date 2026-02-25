defmodule S2.BasinInfo do
  @moduledoc """
  Provides struct and type for a BasinInfo
  """

  @type t :: %__MODULE__{name: String.t(), scope: String.t() | nil, state: String.t()}

  defstruct [:name, :scope, :state]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      name: :string,
      scope: {:union, [{:const, "aws:us-east-1"}, :null]},
      state: {:enum, ["active", "creating", "deleting"]}
    ]
  end
end

defmodule S2.ReadWritePermissions do
  @moduledoc """
  Provides struct and type for a ReadWritePermissions
  """

  @type t :: %__MODULE__{read: boolean | nil, write: boolean | nil}

  defstruct [:read, :write]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [read: :boolean, write: :boolean]
  end
end

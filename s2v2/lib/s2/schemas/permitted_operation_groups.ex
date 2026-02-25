defmodule S2.PermittedOperationGroups do
  @moduledoc """
  Provides struct and type for a PermittedOperationGroups
  """

  @type t :: %__MODULE__{
          account: S2.ReadWritePermissions.t() | nil,
          basin: S2.ReadWritePermissions.t() | nil,
          stream: S2.ReadWritePermissions.t() | nil
        }

  defstruct [:account, :basin, :stream]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: {:union, [{S2.ReadWritePermissions, :t}, :null]},
      basin: {:union, [{S2.ReadWritePermissions, :t}, :null]},
      stream: {:union, [{S2.ReadWritePermissions, :t}, :null]}
    ]
  end
end

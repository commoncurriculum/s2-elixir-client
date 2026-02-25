defmodule S2.AccessTokenScope do
  @moduledoc """
  Provides struct and type for a AccessTokenScope
  """

  @type t :: %__MODULE__{
          access_tokens: map | nil,
          basins: map | nil,
          op_groups: S2.PermittedOperationGroups.t() | nil,
          ops: [String.t()] | nil,
          streams: map | nil
        }

  defstruct [:access_tokens, :basins, :op_groups, :ops, :streams]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      access_tokens: {:union, [:map, :null]},
      basins: {:union, [:map, :null]},
      op_groups: {:union, [{S2.PermittedOperationGroups, :t}, :null]},
      ops:
        {:union,
         [
           [
             enum: [
               "list-basins",
               "create-basin",
               "delete-basin",
               "reconfigure-basin",
               "get-basin-config",
               "issue-access-token",
               "revoke-access-token",
               "list-access-tokens",
               "list-streams",
               "create-stream",
               "delete-stream",
               "get-stream-config",
               "reconfigure-stream",
               "check-tail",
               "append",
               "read",
               "trim",
               "fence",
               "account-metrics",
               "basin-metrics",
               "stream-metrics"
             ]
           ],
           :null
         ]},
      streams: {:union, [:map, :null]}
    ]
  end
end

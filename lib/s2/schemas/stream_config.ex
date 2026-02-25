defmodule S2.StreamConfig do
  @moduledoc """
  Provides struct and type for a StreamConfig
  """

  @type t :: %__MODULE__{
          delete_on_empty: S2.DeleteOnEmptyConfig.t() | nil,
          retention_policy: map | nil,
          storage_class: String.t() | nil,
          timestamping: S2.TimestampingConfig.t() | nil
        }

  defstruct [:delete_on_empty, :retention_policy, :storage_class, :timestamping]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      delete_on_empty: {:union, [{S2.DeleteOnEmptyConfig, :t}, :null]},
      retention_policy: {:union, [:map, :null]},
      storage_class: {:union, [{:enum, ["standard", "express"]}, :null]},
      timestamping: {:union, [{S2.TimestampingConfig, :t}, :null]}
    ]
  end
end

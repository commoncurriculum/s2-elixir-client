defmodule S2.StreamInfo do
  @moduledoc """
  Provides struct and type for a StreamInfo
  """

  @type t :: %__MODULE__{
          created_at: DateTime.t(),
          deleted_at: DateTime.t() | nil,
          name: String.t()
        }

  defstruct [:created_at, :deleted_at, :name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      created_at: {:string, "date-time"},
      deleted_at: {:union, [{:string, "date-time"}, :null]},
      name: :string
    ]
  end
end

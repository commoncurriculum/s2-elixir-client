defmodule S2.AccessTokenInfo do
  @moduledoc """
  Provides struct and type for a AccessTokenInfo
  """

  @type t :: %__MODULE__{
          auto_prefix_streams: boolean | nil,
          expires_at: DateTime.t() | nil,
          id: String.t(),
          scope: S2.AccessTokenScope.t()
        }

  defstruct [:auto_prefix_streams, :expires_at, :id, :scope]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      auto_prefix_streams: :boolean,
      expires_at: {:union, [{:string, "date-time"}, :null]},
      id: :string,
      scope: {S2.AccessTokenScope, :t}
    ]
  end
end

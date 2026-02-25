defmodule S2.IssueAccessTokenResponse do
  @moduledoc """
  Provides struct and type for a IssueAccessTokenResponse
  """

  @type t :: %__MODULE__{access_token: String.t()}

  defstruct [:access_token]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [access_token: :string]
  end
end

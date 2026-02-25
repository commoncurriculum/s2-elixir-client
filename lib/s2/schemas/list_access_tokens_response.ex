defmodule S2.ListAccessTokensResponse do
  @moduledoc """
  Provides struct and type for a ListAccessTokensResponse
  """

  @type t :: %__MODULE__{access_tokens: [S2.AccessTokenInfo.t()], has_more: boolean}

  defstruct [:access_tokens, :has_more]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [access_tokens: [{S2.AccessTokenInfo, :t}], has_more: :boolean]
  end
end

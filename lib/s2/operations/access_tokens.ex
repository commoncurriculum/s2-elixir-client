defmodule S2.AccessTokens do
  @moduledoc """
  Provides API endpoints related to access tokens
  """

  @default_client S2.Client

  @doc """
  Issue a new access token.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec issue_access_token(body :: S2.AccessTokenInfo.t(), opts :: keyword) ::
          {:ok, S2.IssueAccessTokenResponse.t()} | {:error, S2.ErrorInfo.t()}
  def issue_access_token(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {S2.AccessTokens, :issue_access_token},
      url: "/access-tokens",
      body: body,
      method: :post,
      request: [{"application/json", {S2.AccessTokenInfo, :t}}],
      response: [
        {201, {S2.IssueAccessTokenResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  List access tokens.

  ## Options

    * `prefix`: Filter to access tokens whose IDs begin with this prefix.
    * `start_after`: Filter to access tokens whose IDs lexicographically start after this string.
    * `limit`: Number of results, up to a maximum of 1000.

  """
  @spec list_access_tokens(opts :: keyword) ::
          {:ok, S2.ListAccessTokensResponse.t()} | {:error, S2.ErrorInfo.t()}
  def list_access_tokens(opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:limit, :prefix, :start_after])

    client.request(%{
      args: [],
      call: {S2.AccessTokens, :list_access_tokens},
      url: "/access-tokens",
      method: :get,
      query: query,
      response: [
        {200, {S2.ListAccessTokensResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Revoke an access token.
  """
  @spec revoke_access_token(id :: String.t(), opts :: keyword) :: :ok | {:error, S2.ErrorInfo.t()}
  def revoke_access_token(id, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [id: id],
      call: {S2.AccessTokens, :revoke_access_token},
      url: "/access-tokens/#{id}",
      method: :delete,
      response: [
        {204, :null},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end
end

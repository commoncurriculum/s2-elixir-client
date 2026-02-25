defmodule S2.Basins do
  @moduledoc """
  Provides API endpoints related to basins
  """

  @default_client S2.Client

  @doc """
  Create a basin.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec create_basin(body :: S2.CreateBasinRequest.t(), opts :: keyword) ::
          {:ok, S2.BasinInfo.t()} | {:error, S2.ErrorInfo.t()}
  def create_basin(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {S2.Basins, :create_basin},
      url: "/basins",
      body: body,
      method: :post,
      request: [{"application/json", {S2.CreateBasinRequest, :t}}],
      response: [
        {200, {S2.BasinInfo, :t}},
        {201, {S2.BasinInfo, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Create or reconfigure a basin.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec create_or_reconfigure_basin(
          basin :: String.t(),
          body :: S2.CreateOrReconfigureBasinRequest.t() | nil,
          opts :: keyword
        ) :: {:ok, S2.BasinInfo.t()} | {:error, S2.ErrorInfo.t()}
  def create_or_reconfigure_basin(basin, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [basin: basin, body: body],
      call: {S2.Basins, :create_or_reconfigure_basin},
      url: "/basins/#{basin}",
      body: body,
      method: :put,
      request: [{"application/json", {:union, [{S2.CreateOrReconfigureBasinRequest, :t}, :null]}}],
      response: [
        {200, {S2.BasinInfo, :t}},
        {201, {S2.BasinInfo, :t}},
        {400, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Delete a basin.
  """
  @spec delete_basin(basin :: String.t(), opts :: keyword) :: :ok | {:error, S2.ErrorInfo.t()}
  def delete_basin(basin, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [basin: basin],
      call: {S2.Basins, :delete_basin},
      url: "/basins/#{basin}",
      method: :delete,
      response: [
        {202, :null},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Get basin configuration.
  """
  @spec get_basin_config(basin :: String.t(), opts :: keyword) ::
          {:ok, S2.BasinConfig.t()} | {:error, S2.ErrorInfo.t()}
  def get_basin_config(basin, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [basin: basin],
      call: {S2.Basins, :get_basin_config},
      url: "/basins/#{basin}",
      method: :get,
      response: [
        {200, {S2.BasinConfig, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  List basins.

  ## Options

    * `prefix`: Filter to basins whose names begin with this prefix.
    * `start_after`: Filter to basins whose names lexicographically start after this string.
      It must be greater than or equal to the `prefix` if specified.
    * `limit`: Number of results, up to a maximum of 1000.

  """
  @spec list_basins(opts :: keyword) ::
          {:ok, S2.ListBasinsResponse.t()} | {:error, S2.ErrorInfo.t()}
  def list_basins(opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:limit, :prefix, :start_after])

    client.request(%{
      args: [],
      call: {S2.Basins, :list_basins},
      url: "/basins",
      method: :get,
      query: query,
      response: [
        {200, {S2.ListBasinsResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Reconfigure a basin.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec reconfigure_basin(
          basin :: String.t(),
          body :: S2.BasinReconfiguration.t(),
          opts :: keyword
        ) :: {:ok, S2.BasinConfig.t()} | {:error, S2.ErrorInfo.t()}
  def reconfigure_basin(basin, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [basin: basin, body: body],
      call: {S2.Basins, :reconfigure_basin},
      url: "/basins/#{basin}",
      body: body,
      method: :patch,
      request: [{"application/json", {S2.BasinReconfiguration, :t}}],
      response: [
        {200, {S2.BasinConfig, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end
end

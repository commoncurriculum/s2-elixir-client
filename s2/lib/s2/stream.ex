defmodule S2.Stream do
  alias S2.Client

  def create(%Client{} = client, basin, name, _opts \\ []) do
    Client.basin_request(client, basin, :post, "streams", json: %{stream: name})
  end

  def list(%Client{} = client, basin, opts \\ []) do
    params =
      opts
      |> Keyword.take([:prefix, :start_after, :limit])
      |> Enum.into(%{})

    Client.basin_request(client, basin, :get, "streams", params: params)
  end

  def delete(%Client{} = client, basin, name) do
    Client.basin_request(client, basin, :delete, "streams/#{name}")
  end

  def get_config(%Client{} = client, basin, name) do
    Client.basin_request(client, basin, :get, "streams/#{name}/config")
  end

  def reconfigure(%Client{} = client, basin, name, config) do
    Client.basin_request(client, basin, :put, "streams/#{name}/config", json: config)
  end
end

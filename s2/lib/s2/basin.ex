defmodule S2.Basin do
  alias S2.Client

  def create(%Client{} = client, name, _opts \\ []) do
    Client.account_request(client, :post, "basins", json: %{basin: name})
  end

  def list(%Client{} = client, opts \\ []) do
    params =
      opts
      |> Keyword.take([:prefix, :start_after, :limit])
      |> Enum.into(%{})

    Client.account_request(client, :get, "basins", params: params)
  end

  def delete(%Client{} = client, name) do
    Client.account_request(client, :delete, "basins/#{name}")
  end

  def get_config(%Client{} = client, name) do
    Client.account_request(client, :get, "basins/#{name}/config")
  end

  def reconfigure(%Client{} = client, name, config) do
    Client.account_request(client, :put, "basins/#{name}/config", json: config)
  end
end

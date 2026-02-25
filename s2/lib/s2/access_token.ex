defmodule S2.AccessToken do
  alias S2.Client

  def issue(%Client{} = client, id, opts \\ []) do
    body =
      %{id: id}
      |> maybe_put(:scope, opts[:scope])
      |> maybe_put(:expires_at, opts[:expires_at])

    Client.account_request(client, :post, "access-tokens", json: body)
  end

  def list(%Client{} = client, opts \\ []) do
    params =
      opts
      |> Keyword.take([:prefix, :start_after, :limit])
      |> Enum.into(%{})

    Client.account_request(client, :get, "access-tokens", params: params)
  end

  def revoke(%Client{} = client, id) do
    Client.account_request(client, :delete, "access-tokens/#{id}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

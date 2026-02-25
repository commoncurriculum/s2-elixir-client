defmodule S2.Record do
  alias S2.Client

  def check_tail(%Client{} = client, basin, stream) do
    case Client.basin_request(client, basin, :get, "streams/#{stream}/records/tail") do
      {:ok, %{"tail" => tail}} -> {:ok, tail}
      error -> error
    end
  end

  def append(%Client{} = client, basin, stream, records, opts \\ []) do
    body =
      %{records: records}
      |> maybe_put(:match_seq_num, opts[:match_seq_num])
      |> maybe_put(:fencing_token, opts[:fencing_token])

    Client.basin_request(client, basin, :post, "streams/#{stream}/records", json: body)
  end

  def read(%Client{} = client, basin, stream, opts \\ []) do
    params =
      opts
      |> Keyword.take([:seq_num, :timestamp, :count, :wait, :until])
      |> Enum.into(%{})

    Client.basin_request(client, basin, :get, "streams/#{stream}/records", params: params)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

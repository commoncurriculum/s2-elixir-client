defmodule S2.Client do
  defstruct [:config, :req]

  def new(%S2.Config{} = config) do
    headers = base_headers(config)

    req =
      Req.new(
        base_url: config.base_url <> "/v1",
        headers: headers
      )

    %__MODULE__{config: config, req: req}
  end

  def request(%{
        url: url,
        method: method,
        response: response_specs,
        opts: opts
      } = operation) do
    client = opts[:server] || raise "server is required in opts"
    query = Map.get(operation, :query, [])
    body = Map.get(operation, :body)
    basin = opts[:basin]

    headers = if basin, do: [{"s2-basin", basin}], else: []

    req_opts = [
      method: method,
      url: url,
      headers: headers
    ]

    req_opts = if Enum.any?(query), do: Keyword.put(req_opts, :params, query), else: req_opts

    req_opts =
      if body do
        Keyword.put(req_opts, :json, encode_body(body))
      else
        req_opts
      end

    case Req.request(client.req, req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        handle_response(status, resp_body, response_specs)

      {:error, exception} ->
        {:error, %S2.Error{status: 0, message: Exception.message(exception)}}
    end
  end

  defp handle_response(status, body, response_specs) do
    case List.keyfind(response_specs, status, 0) do
      {_, :null} ->
        :ok

      {_, {schema_mod, :t}} when status < 400 ->
        {:ok, decode_schema(body, schema_mod)}

      {_, {schema_mod, :t}} ->
        {:error, decode_schema(body, schema_mod)}

      nil ->
        {:error, S2.Error.from_response(%{status: status, body: body})}
    end
  end

  defp decode_schema(body, schema_mod) when is_map(body) do
    fields = schema_mod.__fields__(:t)

    attrs =
      for {field_name, type} <- fields, into: %{} do
        str_key = Atom.to_string(field_name)
        raw = Map.get(body, str_key)
        {field_name, decode_field(raw, type)}
      end

    struct(schema_mod, attrs)
  end

  defp decode_schema(body, _schema_mod), do: body

  defp decode_field(nil, _type), do: nil

  defp decode_field(values, [{schema_mod, :t}]) when is_list(values) do
    Enum.map(values, &decode_schema(&1, schema_mod))
  end

  defp decode_field(value, {schema_mod, :t}) when is_map(value) and is_atom(schema_mod) do
    decode_schema(value, schema_mod)
  end

  defp decode_field(value, {:union, variants}) do
    Enum.find_value(variants, value, fn
      :null -> if is_nil(value), do: nil
      {schema_mod, :t} when is_atom(schema_mod) and is_map(value) -> decode_schema(value, schema_mod)
      _ -> nil
    end)
  end

  defp decode_field(value, _type), do: value

  defp encode_body(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {k, encode_body(v)} end)
  end

  defp encode_body(values) when is_list(values), do: Enum.map(values, &encode_body/1)
  defp encode_body(body), do: body

  defp base_headers(%S2.Config{token: nil}), do: []

  defp base_headers(%S2.Config{token: token}) do
    [{"authorization", "Bearer #{token}"}]
  end
end

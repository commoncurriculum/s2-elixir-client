defmodule S2.Client do
  @type t :: %__MODULE__{config: S2.Config.t(), req: Req.Request.t()}

  defstruct [:config, :req]

  @spec new(S2.Config.t()) :: t()
  def new(%S2.Config{} = config) do
    headers = base_headers(config)

    req =
      Req.new(
        base_url: config.base_url <> "/v1",
        headers: headers
      )

    %__MODULE__{config: config, req: req}
  end

  @spec request(map()) :: {:ok, term()} | {:error, term()} | :ok
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

    # URL-encode path segments. Generated operations use raw interpolation
    # (e.g. "/basins/#{basin}"), so we encode here to handle special characters.
    encoded_url = encode_url_path(url)

    req_opts = [
      method: method,
      url: encoded_url,
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
        message =
          if is_exception(exception),
            do: Exception.message(exception),
            else: inspect(exception)

        {:error, %S2.Error{status: nil, message: message}}
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

  defp decode_schema(nil, _schema_mod), do: nil
  defp decode_schema(body, _schema_mod), do: body

  defp decode_field(nil, _type), do: nil

  defp decode_field(values, [{schema_mod, :t}]) when is_list(values) do
    Enum.map(values, &decode_schema(&1, schema_mod))
  end

  defp decode_field(value, {schema_mod, :t}) when is_map(value) and is_atom(schema_mod) do
    decode_schema(value, schema_mod)
  end

  defp decode_field(value, {:union, variants}) do
    Enum.find_value(variants, fn
      :null when is_nil(value) -> {:decoded, nil}
      {schema_mod, :t} when is_atom(schema_mod) and is_map(value) -> {:decoded, decode_schema(value, schema_mod)}
      {:const, const_value} when const_value == value -> {:decoded, value}
      _ -> nil
    end)
    |> case do
      {:decoded, result} -> result
      nil -> value
    end
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

  # Encode each path segment individually, preserving "/" separators.
  defp encode_url_path(url) do
    url
    |> String.split("/")
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end

  defp base_headers(%S2.Config{token: nil}), do: []

  defp base_headers(%S2.Config{token: token}) do
    [{"authorization", "Bearer #{token}"}]
  end
end

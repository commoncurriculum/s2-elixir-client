defmodule S2.Client do
  defstruct [:config, :req]

  @type t :: %__MODULE__{
          config: S2.Config.t(),
          req: Req.Request.t()
        }

  def new(%S2.Config{} = config) do
    headers = base_headers(config)

    req =
      Req.new(
        base_url: config.base_url <> "/v1",
        headers: headers,
        decode_body: :json
      )

    %__MODULE__{config: config, req: req}
  end

  def account_request(%__MODULE__{req: req}, method, path, opts \\ []) do
    req
    |> Req.merge(method: method, url: path)
    |> Req.merge(opts)
    |> Req.request()
    |> handle_response()
  end

  def basin_request(%__MODULE__{req: req}, basin, method, path, opts \\ []) do
    req
    |> Req.merge(method: method, url: path, headers: %{"s2-basin" => basin})
    |> Req.merge(opts)
    |> Req.request()
    |> handle_response()
  end

  defp base_headers(%S2.Config{token: nil}), do: %{}

  defp base_headers(%S2.Config{token: token}) do
    %{"authorization" => "Bearer #{token}"}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, S2.Error.from_response(%{status: status, body: body})}
  end

  defp handle_response({:error, exception}) do
    {:error, %S2.Error{message: Exception.message(exception), status: 0}}
  end
end

defmodule S2.ProxyHelper do
  @moduledoc false

  @proxy_name "s2_proxy"
  @proxy_port 19_999

  @doc """
  Puts Toxiproxy between the tests and S2 Lite, and returns the endpoint to
  use. In CI the services reach each other by name, so `S2_UPSTREAM` says
  where S2 Lite is.
  """
  def setup_proxy! do
    ToxiproxyEx.populate!([
      %{
        name: @proxy_name,
        upstream: System.get_env("S2_UPSTREAM", "localhost:4243"),
        listen: "0.0.0.0:#{@proxy_port}"
      }
    ])

    remove_all_toxics!()
    enable!(true)
    "http://localhost:#{@proxy_port}"
  end

  def add_toxic!(type, attributes, stream \\ :downstream) do
    ToxiproxyEx.Toxic.create(%ToxiproxyEx.Toxic{
      type: type,
      name: "#{type}_#{stream}",
      stream: stream,
      proxy_name: @proxy_name,
      attributes: Map.new(attributes),
      toxicity: 1.0
    })
  end

  @doc "While disabled, the proxy refuses connections and closes open ones."
  def enable!(enabled) do
    {:ok, %{status: 200}} =
      Req.post("http://localhost:8474/proxies/#{@proxy_name}", json: %{enabled: enabled})

    :ok
  end

  def remove_all_toxics! do
    {:ok, response} = Req.get("http://localhost:8474/proxies/#{@proxy_name}/toxics")

    Enum.each(response.body, fn toxic ->
      ToxiproxyEx.Toxic.destroy(%ToxiproxyEx.Toxic{name: toxic["name"], proxy_name: @proxy_name})
    end)
  end
end

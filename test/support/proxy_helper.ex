defmodule S2.ProxyHelper do
  @moduledoc false

  @proxy_name "s2_proxy"

  @doc """
  The upstream address for s2-lite.
  In CI (Docker), services reference each other by name.
  Locally, s2-lite runs on localhost.
  """
  def upstream do
    System.get_env("S2_UPSTREAM", "localhost:4243")
  end

  @proxy_listen_port 19_999

  @doc """
  Set up a toxiproxy proxy pointing at s2-lite.
  Returns the proxy's listen port for tests to connect through.
  Uses a fixed port so it can be mapped in CI Docker configs.
  """
  def setup_proxy! do
    ToxiproxyEx.populate!([
      %{name: @proxy_name, upstream: upstream(), listen: "0.0.0.0:#{@proxy_listen_port}"}
    ])

    @proxy_listen_port
  end

  @doc "Get the proxy struct for applying toxics."
  def proxy! do
    ToxiproxyEx.get!(@proxy_name)
  end

  @doc "Create a toxic directly on the proxy server. Removes existing toxic with same name first."
  def add_toxic!(type, stream \\ :downstream, attrs) do
    name = "#{type}_#{stream}"

    # Remove existing toxic with same name if present (avoids 409 conflict)
    try do
      ToxiproxyEx.Toxic.destroy(%ToxiproxyEx.Toxic{name: name, proxy_name: @proxy_name})
    rescue
      _ -> :ok
    end

    ToxiproxyEx.Toxic.create(%ToxiproxyEx.Toxic{
      type: type,
      name: name,
      stream: stream,
      proxy_name: @proxy_name,
      attributes: Map.new(attrs),
      toxicity: 1.0
    })
  end

  @doc "Remove all toxics from the proxy."
  def remove_all_toxics! do
    {:ok, resp} = Req.get("http://localhost:8474/proxies/#{@proxy_name}/toxics")

    for toxic <- resp.body do
      ToxiproxyEx.Toxic.destroy(%ToxiproxyEx.Toxic{
        name: toxic["name"],
        proxy_name: @proxy_name
      })
    end
  end

  @doc "Open an S2S connection through the proxy."
  def open_conn!(port) do
    {:ok, conn} = S2.S2S.Connection.open("http://localhost:#{port}")
    conn
  end

  @doc """
  Open an S2S connection and wait for HTTP/2 handshake to complete.
  Use this before applying latency toxics so the handshake isn't affected.
  """
  def open_conn_ready!(port) do
    conn = open_conn!(port)
    # Allow time for the HTTP/2 SETTINGS exchange to complete through the proxy
    Process.sleep(100)
    # Drain any pending messages through Mint to update connection state
    drain_messages(conn)
  end

  defp drain_messages(conn) do
    receive do
      message ->
        case Mint.HTTP2.stream(conn, message) do
          {:ok, conn, _responses} -> drain_messages(conn)
          _ -> conn
        end
    after
      50 -> conn
    end
  end
end

defmodule S2.S2S.Connection do
  def open(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    Mint.HTTP2.connect(scheme, uri.host, port)
  end

  def close(conn) do
    Mint.HTTP2.close(conn)
  end
end

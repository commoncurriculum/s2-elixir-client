defmodule S2.S2S.Connection do
  @moduledoc """
  Manages Mint HTTP/2 connections for S2S data plane operations.
  """

  @default_connect_timeout 5_000

  @spec open(String.t(), keyword()) :: {:ok, Mint.HTTP2.t()} | {:error, term()}
  def open(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_connect_timeout)
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    Mint.HTTP2.connect(scheme, uri.host, port, transport_opts: [timeout: timeout])
  end

  @spec close(Mint.HTTP2.t()) :: {:ok, Mint.HTTP2.t()}
  def close(conn) do
    Mint.HTTP2.close(conn)
  end
end

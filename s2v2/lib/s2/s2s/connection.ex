defmodule S2.S2S.Connection do
  @moduledoc """
  Manages Mint HTTP/2 connections for S2S data plane operations.
  """

  @spec open(String.t()) :: {:ok, Mint.HTTP2.t()} | {:error, term()}
  def open(url) do
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    Mint.HTTP2.connect(scheme, uri.host, port)
  end

  @spec close(Mint.HTTP2.t()) :: {:ok, Mint.HTTP2.t()}
  def close(conn) do
    Mint.HTTP2.close(conn)
  end
end

defmodule S2.S2S.Connection do
  @moduledoc """
  Manages Mint HTTP/2 connections for S2S data plane operations.
  """

  @default_connect_timeout 5_000

  @doc """
  Open a new Mint HTTP/2 connection.

  ## Options

    * `:timeout` — Connection timeout in milliseconds (default: 5000).
    * `:transport_opts` — Additional options passed to Mint's transport layer
      (e.g. TLS certificate options like `:cacertfile`, `:certfile`, `:verify`).
  """
  @spec open(String.t(), keyword()) :: {:ok, Mint.HTTP2.t()} | {:error, term()}
  def open(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_connect_timeout)
    extra_transport_opts = Keyword.get(opts, :transport_opts, [])
    uri = URI.parse(url)
    scheme = if uri.scheme == "https", do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    transport_opts = Keyword.merge([timeout: timeout], extra_transport_opts)
    Mint.HTTP2.connect(scheme, uri.host, port, transport_opts: transport_opts)
  end

  @spec close(Mint.HTTP2.t()) :: {:ok, Mint.HTTP2.t()}
  def close(conn) do
    Mint.HTTP2.close(conn)
  end
end

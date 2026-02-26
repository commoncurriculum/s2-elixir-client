defmodule S2.S2S.Connection do
  @moduledoc """
  Manages Mint HTTP/2 connections for S2S data plane operations.
  """

  @default_connect_timeout 5_000

  @doc """
  Open a new Mint HTTP/2 connection to the S2 data plane.

  This is the connection establishment timeout only — individual S2S operations
  (append, read, check tail) have their own `:recv_timeout` for waiting on
  responses.

  ## Options

    * `:timeout` — Connection establishment timeout in milliseconds (default: 5000).
    * `:token` — Bearer token for authentication. Not used at the connection level —
      individual S2S modules add the `authorization` header to each request.
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

  @doc """
  Build auth headers from a token. Returns an empty list if token is nil.
  """
  @spec auth_headers(String.t() | nil) :: [{String.t(), String.t()}]
  def auth_headers(nil), do: []
  def auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  @doc """
  Close a Mint HTTP/2 connection.
  """
  @spec close(Mint.HTTP2.t()) :: {:ok, Mint.HTTP2.t()}
  def close(conn) do
    Mint.HTTP2.close(conn)
  end
end

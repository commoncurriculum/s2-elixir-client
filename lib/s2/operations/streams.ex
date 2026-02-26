defmodule S2.Streams do
  @moduledoc """
  Provides API endpoints related to streams
  """

  @default_client S2.Client

  @doc """
  Create or reconfigure a stream.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec create_or_reconfigure_stream(
          stream :: String.t(),
          body :: S2.StreamReconfiguration.t() | nil,
          opts :: keyword
        ) :: {:ok, S2.StreamInfo.t()} | {:error, S2.Error.t()}
  def create_or_reconfigure_stream(stream, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [stream: stream, body: body],
      call: {S2.Streams, :create_or_reconfigure_stream},
      url: "/streams/#{stream}",
      body: body,
      method: :put,
      request: [{"application/json", {:union, [{S2.StreamReconfiguration, :t}, :null]}}],
      response: [
        {200, {S2.StreamInfo, :t}},
        {201, {S2.StreamInfo, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Create a stream.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec create_stream(body :: S2.CreateStreamRequest.t(), opts :: keyword) ::
          {:ok, S2.StreamInfo.t()} | {:error, S2.Error.t()}
  def create_stream(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {S2.Streams, :create_stream},
      url: "/streams",
      body: body,
      method: :post,
      request: [{"application/json", {S2.CreateStreamRequest, :t}}],
      response: [
        {201, {S2.StreamInfo, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Delete a stream.
  """
  @spec delete_stream(stream :: String.t(), opts :: keyword) :: :ok | {:error, S2.Error.t()}
  def delete_stream(stream, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [stream: stream],
      call: {S2.Streams, :delete_stream},
      url: "/streams/#{stream}",
      method: :delete,
      response: [
        {202, :null},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Get stream configuration.
  """
  @spec get_stream_config(stream :: String.t(), opts :: keyword) ::
          {:ok, S2.StreamConfig.t()} | {:error, S2.Error.t()}
  def get_stream_config(stream, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [stream: stream],
      call: {S2.Streams, :get_stream_config},
      url: "/streams/#{stream}",
      method: :get,
      response: [
        {200, {S2.StreamConfig, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  List streams.

  ## Options

    * `prefix`: Filter to streams whose names begin with this prefix.
    * `start_after`: Filter to streams whose names lexicographically start after this string.
      It must be greater than or equal to the `prefix` if specified.
    * `limit`: Number of results, up to a maximum of 1000.

  """
  @spec list_streams(opts :: keyword) ::
          {:ok, S2.ListStreamsResponse.t()} | {:error, S2.Error.t()}
  def list_streams(opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:limit, :prefix, :start_after])

    client.request(%{
      args: [],
      call: {S2.Streams, :list_streams},
      url: "/streams",
      method: :get,
      query: query,
      response: [
        {200, {S2.ListStreamsResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Reconfigure a stream.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec reconfigure_stream(
          stream :: String.t(),
          body :: S2.StreamReconfiguration.t(),
          opts :: keyword
        ) :: {:ok, S2.StreamConfig.t()} | {:error, S2.Error.t()}
  def reconfigure_stream(stream, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [stream: stream, body: body],
      call: {S2.Streams, :reconfigure_stream},
      url: "/streams/#{stream}",
      body: body,
      method: :patch,
      request: [{"application/json", {S2.StreamReconfiguration, :t}}],
      response: [
        {200, {S2.StreamConfig, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {404, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}},
        {409, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end
end

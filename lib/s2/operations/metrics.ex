defmodule S2.Metrics do
  @moduledoc """
  Provides API endpoints related to metrics
  """

  @default_client S2.Client

  @doc """
  Account-level metrics.

  ## Options

    * `set`: Metric set to return.
    * `start`: Start timestamp as Unix epoch seconds, if applicable for the metric set.
    * `end`: End timestamp as Unix epoch seconds, if applicable for the metric set.
    * `interval`: Interval to aggregate over for timeseries metric sets.

  """
  @spec account_metrics(opts :: keyword) ::
          {:ok, S2.MetricSetResponse.t()} | {:error, S2.Error.t()}
  def account_metrics(opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:end, :interval, :set, :start])

    client.request(%{
      args: [],
      call: {S2.Metrics, :account_metrics},
      url: "/metrics",
      method: :get,
      query: query,
      response: [
        {200, {S2.MetricSetResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Basin-level metrics.

  ## Options

    * `set`: Metric set to return.
    * `start`: Start timestamp as Unix epoch seconds, if applicable for the metric set.
    * `end`: End timestamp as Unix epoch seconds, if applicable for the metric set.
    * `interval`: Interval to aggregate over for timeseries metric sets.

  """
  @spec basin_metrics(basin :: String.t(), opts :: keyword) ::
          {:ok, S2.MetricSetResponse.t()} | {:error, S2.Error.t()}
  def basin_metrics(basin, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:end, :interval, :set, :start])

    client.request(%{
      args: [basin: basin],
      call: {S2.Metrics, :basin_metrics},
      url: "/metrics/#{basin}",
      method: :get,
      query: query,
      response: [
        {200, {S2.MetricSetResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end

  @doc """
  Stream-level metrics.

  ## Options

    * `set`: Metric set to return.
    * `start`: Start timestamp as Unix epoch seconds, if applicable for the metric set.
    * `end`: End timestamp as Unix epoch seconds, if applicable for metric set.
    * `interval`: Interval to aggregate over for timeseries metric sets.

  """
  @spec stream_metrics(basin :: String.t(), stream :: String.t(), opts :: keyword) ::
          {:ok, S2.MetricSetResponse.t()} | {:error, S2.Error.t()}
  def stream_metrics(basin, stream, opts \\ []) do
    client = opts[:client] || @default_client
    query = Keyword.take(opts, [:end, :interval, :set, :start])

    client.request(%{
      args: [basin: basin, stream: stream],
      call: {S2.Metrics, :stream_metrics},
      url: "/metrics/#{basin}/#{stream}",
      method: :get,
      query: query,
      response: [
        {200, {S2.MetricSetResponse, :t}},
        {400, {S2.ErrorInfo, :t}},
        {403, {S2.ErrorInfo, :t}},
        {408, {S2.ErrorInfo, :t}}
      ],
      opts: opts
    })
  end
end

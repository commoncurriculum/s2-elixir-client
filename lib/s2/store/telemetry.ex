defmodule S2.Store.Telemetry do
  @moduledoc """
  Telemetry events emitted by `S2.Store`.

  All events use `:telemetry.span/3` where possible, following the standard
  Erlang/Elixir telemetry span convention. This means each operation emits
  a `:start` event, then either a `:stop` or `:exception` event with timing
  measurements — compatible with `:telemetry.attach/4` and libraries like
  `Telemetry.Metrics` out of the box.

  All events follow the `[:s2, :store, ...]` prefix convention.

  ## Events

  ### `[:s2, :store, :append, :start | :stop | :exception]`
  Emitted as a span around each append operation.
  - Start measurements: `%{system_time: integer, monotonic_time: integer}`
  - Stop measurements: `%{duration: integer, monotonic_time: integer}`
  - Exception measurements: `%{duration: integer, monotonic_time: integer}`
  - Metadata: `%{stream: String.t()}`
  - Exception metadata adds: `kind`, `reason`, `stacktrace`

  ### `[:s2, :store, :reconnect, :start | :stop | :exception]`
  Emitted as a span around each reconnection attempt.
  - Same measurement pattern as append.
  - Metadata: `%{stream: String.t(), component: :writer | :listener, attempt: integer}`

  ### `[:s2, :store, :listener, :connect]`
  Emitted as a single event when a listener establishes its initial connection.
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{stream: String.t()}`

  ### `[:s2, :store, :listener, :failed]`
  Emitted when a listener fails to start (connection or session error).
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{stream: String.t(), reason: term()}`
  """

  @doc """
  Execute a function within a telemetry span.

  Delegates to `:telemetry.span/3`. The `fun` must return `{result, extra_metadata}`
  where `extra_metadata` is merged into the `:stop` event metadata. If `fun` raises,
  throws, or exits, the `:exception` event is emitted automatically by `:telemetry.span/3`.

  For operations that return error tuples (not exceptions), the span emits `:stop` —
  the operation completed, it just had an error result. Include error info in the
  returned metadata if you want it in the telemetry event.
  """
  def span(event_prefix, metadata, fun) do
    :telemetry.span(event_prefix, metadata, fun)
  end

  @doc false
  def event(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end
end

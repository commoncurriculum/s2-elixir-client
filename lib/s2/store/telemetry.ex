defmodule S2.Store.Telemetry do
  @moduledoc """
  Telemetry events emitted by `S2.Store`.

  All events follow the `[:s2, :store, ...]` prefix convention.

  ## Events

  ### `[:s2, :store, :append, :start]`
  Emitted when an append begins.
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{stream: String.t()}`

  ### `[:s2, :store, :append, :stop]`
  Emitted when an append succeeds.
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{stream: String.t()}`

  ### `[:s2, :store, :append, :exception]`
  Emitted when an append fails.
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{stream: String.t(), reason: term}`

  ### `[:s2, :store, :reconnect, :start]`
  Emitted when a reconnection attempt begins.
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{stream: String.t(), component: :writer | :listener, attempt: integer}`

  ### `[:s2, :store, :reconnect, :stop]`
  Emitted when a reconnection succeeds.
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{stream: String.t(), component: :writer | :listener, attempt: integer}`

  ### `[:s2, :store, :reconnect, :exception]`
  Emitted when a reconnection fails.
  - Measurements: `%{duration: integer}` (native time units)
  - Metadata: `%{stream: String.t(), component: :writer | :listener, attempt: integer, reason: term}`

  ### `[:s2, :store, :listener, :connect]`
  Emitted when a listener establishes its initial connection.
  - Measurements: `%{system_time: integer}`
  - Metadata: `%{stream: String.t()}`
  """

  @doc false
  def span(event, metadata, fun) do
    start_time = System.monotonic_time()
    :telemetry.execute(event ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time
      :telemetry.execute(event ++ [:stop], %{duration: duration}, metadata)
      result
    rescue
      e ->
        duration = System.monotonic_time() - start_time
        :telemetry.execute(event ++ [:exception], %{duration: duration}, Map.put(metadata, :reason, e))
        reraise e, __STACKTRACE__
    end
  end

  @doc false
  def event(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end
end

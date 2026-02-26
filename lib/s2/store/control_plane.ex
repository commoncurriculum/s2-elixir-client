defmodule S2.Store.ControlPlane do
  @moduledoc false
  use GenServer

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: Module.concat(config.store, ControlPlane))
  end

  @impl true
  def init(config) do
    s2_config = S2.Config.new(base_url: config.base_url, token: config.token)
    client = S2.Client.new(s2_config)
    {:ok, %{client: client, basin: config.basin}}
  end

  @impl true
  def handle_call({:create_stream, stream}, _from, state) do
    result = S2.Streams.create_stream(
      %S2.CreateStreamRequest{stream: stream},
      server: state.client, basin: state.basin
    )
    {:reply, result, state}
  end

  def handle_call({:delete_stream, stream}, _from, state) do
    result = S2.Streams.delete_stream(stream, server: state.client, basin: state.basin)
    {:reply, result, state}
  end
end

defmodule S2.Store.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: config.store)
  end

  @impl true
  def init(config) do
    :persistent_term.put({__MODULE__, config.store}, config)

    children = [
      {Registry, keys: :unique, name: registry_name(config.store)},
      {DynamicSupervisor, name: dynamic_sup_name(config.store), strategy: :one_for_one},
      {Task.Supervisor, name: task_sup_name(config.store)},
      {S2.Store.ControlPlane, config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  def get_config(store) do
    :persistent_term.get({__MODULE__, store})
  end

  def stream_worker_name(store, stream) do
    {:via, Registry, {registry_name(store), stream}}
  end

  def ensure_worker(store, stream) do
    name = stream_worker_name(store, stream)

    case GenServer.whereis(name) do
      nil -> start_worker(store, stream)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  def create_stream(store, stream) do
    GenServer.call(control_plane_name(store), {:create_stream, stream})
  end

  def delete_stream(store, stream) do
    GenServer.call(control_plane_name(store), {:delete_stream, stream})
  end

  def listen(store, stream, callback, opts) do
    config = get_config(store)
    seq_num = Keyword.get(opts, :from, 0)
    serializer = Keyword.get(opts, :serializer, config.serializer)

    listener_config = %{
      base_url: config.base_url,
      token: config.token,
      basin: config.basin,
      stream: stream,
      max_retries: config.max_retries,
      base_delay: config.base_delay
    }

    Task.Supervisor.start_child(task_sup_name(store), fn ->
      S2.Store.Telemetry.event([:s2, :store, :listener, :connect], %{system_time: System.system_time()}, %{stream: stream})
      {:ok, conn} = S2.S2S.Connection.open(config.base_url, token: config.token)
      {:ok, session} = S2.S2S.ReadSession.open(conn, config.basin, stream, seq_num: seq_num)
      S2.Store.StreamWorker.tail_loop(session, serializer, callback, listener_config)
    end)
  end

  def stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
      :ok
    else
      {:error, :not_found}
    end
  end

  defp start_worker(store, stream) do
    config = get_config(store)
    spec = {S2.Store.StreamWorker, {config, stream}}
    DynamicSupervisor.start_child(dynamic_sup_name(store), spec)
  end

  defp dynamic_sup_name(store), do: Module.concat(store, DynamicSupervisor)
  defp task_sup_name(store), do: Module.concat(store, TaskSupervisor)
  defp control_plane_name(store), do: Module.concat(store, ControlPlane)
  defp registry_name(store), do: Module.concat(store, Registry)
end

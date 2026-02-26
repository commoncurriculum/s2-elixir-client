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

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def get_config(store) do
    :persistent_term.get({__MODULE__, store})
  end

  def stream_worker_name(store, stream) do
    {:via, Registry, {registry_name(store), stream}}
  end

  def ensure_worker(store, stream) do
    config = get_config(store)
    spec = {S2.Store.StreamWorker, {config, stream}}

    case DynamicSupervisor.start_child(dynamic_sup_name(store), spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
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
    S2.Store.Listener.start(task_sup_name(store), config, stream, callback, opts)
  end

  def stop_listener(store, pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(task_sup_name(store), pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp dynamic_sup_name(store), do: Module.concat(store, DynamicSupervisor)
  defp task_sup_name(store), do: Module.concat(store, TaskSupervisor)
  defp control_plane_name(store), do: Module.concat(store, ControlPlane)
  defp registry_name(store), do: Module.concat(store, Registry)
end

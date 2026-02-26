defmodule S2.Store.Supervisor do
  @moduledoc false
  use Supervisor

  require Logger

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
    serializer = Keyword.get(opts, :serializer, config.serializer)

    listener_config = %{
      base_url: config.base_url,
      token: config.token,
      basin: config.basin,
      stream: stream,
      max_retries: config.max_retries,
      base_delay: config.base_delay,
      recv_timeout: config.recv_timeout
    }

    Task.Supervisor.start_child(task_sup_name(store), fn ->
      S2.Store.Telemetry.event([:s2, :store, :listener, :connect], %{system_time: System.system_time()}, %{stream: stream})

      with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
           {:ok, seq_num, conn} <- resolve_start_position(conn, config, stream, opts),
           {:ok, session} <- S2.S2S.ReadSession.open(conn, config.basin, stream, seq_num: seq_num, token: config.token, recv_timeout: config.recv_timeout) do
        S2.Store.TailLoop.run(session, serializer, callback, listener_config)
      else
        {:error, reason, _conn} ->
          Logger.error("S2 listener failed to start for #{stream}: #{inspect(reason)}")
          S2.Store.Telemetry.event([:s2, :store, :listener, :failed], %{system_time: System.system_time()}, %{stream: stream, reason: reason})
          {:error, reason}

        {:error, reason} ->
          Logger.error("S2 listener failed to start for #{stream}: #{inspect(reason)}")
          S2.Store.Telemetry.event([:s2, :store, :listener, :failed], %{system_time: System.system_time()}, %{stream: stream, reason: reason})
          {:error, reason}
      end
    end)
  end

  def stop_listener(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 ->
          Process.demonitor(ref, [:flush])
          {:error, :timeout}
      end
    else
      {:error, :not_found}
    end
  end

  defp resolve_start_position(conn, config, stream, opts) do
    case Keyword.get(opts, :from, 0) do
      :tail ->
        case S2.S2S.CheckTail.call(conn, config.basin, stream, token: config.token) do
          {:ok, position, conn} -> {:ok, position.seq_num, conn}
          {:error, reason, conn} -> {:error, reason, conn}
        end

      seq_num when is_integer(seq_num) and seq_num >= 0 ->
        {:ok, seq_num, conn}

      other ->
        {:error, {:invalid_from, other}, conn}
    end
  end

  defp dynamic_sup_name(store), do: Module.concat(store, DynamicSupervisor)
  defp task_sup_name(store), do: Module.concat(store, TaskSupervisor)
  defp control_plane_name(store), do: Module.concat(store, ControlPlane)
  defp registry_name(store), do: Module.concat(store, Registry)
end

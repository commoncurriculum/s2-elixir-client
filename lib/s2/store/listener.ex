defmodule S2.Store.Listener do
  @moduledoc false

  require Logger

  @doc """
  Start a listener task that tails a stream and calls `callback` for each message.

  Opens a connection, resolves the start position, opens a ReadSession, and
  runs the TailLoop. Returns `{:ok, pid}` via `Task.Supervisor.start_child`.
  """
  def start(task_supervisor, config, stream, callback, opts) do
    serializer = Keyword.get(opts, :serializer, config.serializer)

    listener_config = S2.Store.TailLoop.build_config(config, stream)

    Task.Supervisor.start_child(task_supervisor, fn ->
      :telemetry.execute(
        [:s2, :store, :listener, :connect],
        %{system_time: System.system_time()},
        %{stream: stream}
      )

      S2.S2S.Shared.open_session(config.base_url, [token: config.token], fn conn ->
        with {:ok, seq_num, conn} <- resolve_start_position(conn, config, stream, opts),
             {:ok, session} <-
               S2.S2S.ReadSession.open(conn, config.basin, stream,
                 seq_num: seq_num,
                 token: config.token,
                 recv_timeout: config.recv_timeout
               ) do
          {:ok, session}
        else
          {:error, reason, conn} -> {:error, reason, conn}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> case do
        {:ok, session} ->
          S2.Store.TailLoop.run(session, serializer, callback, listener_config)

        {:error, reason} ->
          start_failed(stream, reason)
      end
    end)
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

  defp start_failed(stream, reason) do
    Logger.error("S2 listener failed to start for #{stream}: #{inspect(reason)}")

    :telemetry.execute([:s2, :store, :listener, :failed], %{system_time: System.system_time()}, %{
      stream: stream,
      reason: reason
    })

    {:error, reason}
  end
end

defmodule S2.Store do
  @moduledoc """
  High-level store module, similar to `Ecto.Repo`.

  Define a store in your application:

      defmodule MyApp.S2 do
        use S2.Store,
          otp_app: :my_app,
          basin: "my-basin"
      end

  Add it to your supervision tree:

      # lib/my_app/application.ex
      children = [MyApp.S2]

  Configure in config:

      # config/config.exs
      config :my_app, MyApp.S2,
        base_url: "https://aws.s2.dev",
        token: System.get_env("S2_TOKEN")

  Then use it:

      MyApp.S2.append("my-stream", %{event: "click"})
      MyApp.S2.listen("my-stream", fn msg -> IO.inspect(msg) end)

  Each stream gets its own process with a persistent HTTP/2 connection
  and open `AppendSession`. Workers are started lazily on first use.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @otp_app Keyword.fetch!(opts, :otp_app)
      @basin Keyword.fetch!(opts, :basin)
      @serializer Keyword.get(opts, :serializer, %{serialize: &Jason.encode!/1, deserialize: &Jason.decode!/1})

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(_opts \\ []) do
        app_config = Application.get_env(@otp_app, __MODULE__, [])

        config = %{
          store: __MODULE__,
          basin: @basin,
          serializer: @serializer,
          base_url: Keyword.get(app_config, :base_url, "http://localhost:4243"),
          token: Keyword.get(app_config, :token)
        }

        S2.Store.Supervisor.start_link(config)
      end

      def config do
        %{basin: @basin, serializer: @serializer, otp_app: @otp_app}
      end

      def append(stream, message, serializer \\ @serializer) do
        S2.Store.Supervisor.ensure_worker(__MODULE__, stream)
        S2.Store.StreamWorker.append(__MODULE__, stream, message, serializer)
      end

      def create_stream(stream) do
        S2.Store.Supervisor.create_stream(__MODULE__, stream)
      end

      def delete_stream(stream) do
        S2.Store.Supervisor.delete_stream(__MODULE__, stream)
      end

      def listen(stream, callback, opts \\ []) do
        S2.Store.Supervisor.listen(__MODULE__, stream, callback, opts)
      end

      # Allow `use MyApp.S2, serializer: ...` in downstream modules
      # to bind stream functions to this store with a specific serializer.
      defmacro __using__(stream_opts) do
        store = __MODULE__

        serializer_ast =
          case Keyword.get(stream_opts, :serializer) do
            nil -> Macro.escape(@serializer)
            ast -> ast
          end

        quote do
          @__store__ unquote(store)

          @doc false
          def __serializer__, do: unquote(serializer_ast)

          def append(stream, message) do
            @__store__.append(stream, message, __serializer__())
          end

          def listen(stream, callback, opts \\ []) do
            opts = Keyword.put_new(opts, :serializer, __serializer__())
            @__store__.listen(stream, callback, opts)
          end

          def create_stream(stream) do
            @__store__.create_stream(stream)
          end

          def delete_stream(stream) do
            @__store__.delete_stream(stream)
          end
        end
      end

      defoverridable child_spec: 1
    end
  end
end

defmodule S2.Store.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: config.store)
  end

  @impl true
  def init(config) do
    # Store config in a persistent term so workers and callers can access it
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

    listener_config = %{base_url: config.base_url, token: config.token, basin: config.basin, stream: stream}

    Task.Supervisor.start_child(task_sup_name(store), fn ->
      {:ok, conn} = S2.S2S.Connection.open(config.base_url, token: config.token)
      {:ok, session} = S2.S2S.ReadSession.open(conn, config.basin, stream, seq_num: seq_num)
      S2.Store.StreamWorker.tail_loop(session, serializer, callback, listener_config)
    end)
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

defmodule S2.Store.StreamWorker do
  @moduledoc false
  use GenServer

  alias S2.Patterns.Serialization

  def start_link({config, stream}) do
    name = S2.Store.Supervisor.stream_worker_name(config.store, stream)
    GenServer.start_link(__MODULE__, {config, stream}, name: name)
  end

  def append(store, stream, message, serializer) do
    name = S2.Store.Supervisor.stream_worker_name(store, stream)
    GenServer.call(name, {:append, message, serializer})
  end

  @impl true
  def init({config, stream}) do
    {:ok, conn} = S2.S2S.Connection.open(config.base_url, token: config.token)
    {:ok, session} = S2.S2S.AppendSession.open(conn, config.basin, stream)

    {:ok, %{
      config: config,
      stream: stream,
      session: session,
      writer: Serialization.writer()
    }}
  end

  @impl true
  def handle_call({:append, message, serializer}, _from, state) do
    {input, writer} = Serialization.prepare(state.writer, message, serializer)

    case append_with_reconnect(state, input) do
      {:ok, ack, session} ->
        {:reply, {:ok, ack}, %{state | session: session, writer: writer}}

      {:error, reason, session} ->
        {:reply, {:error, reason}, %{state | session: session, writer: writer}}
    end
  end

  defp append_with_reconnect(state, input) do
    case S2.S2S.AppendSession.append(state.session, input) do
      {:ok, _ack, _session} = ok ->
        ok

      {:error, _reason, _session} ->
        case reconnect(state.config, state.stream) do
          {:ok, session} ->
            S2.S2S.AppendSession.append(session, input)

          {:error, reason} ->
            {:error, reason, state.session}
        end
    end
  end

  defp reconnect(config, stream) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.AppendSession.open(conn, config.basin, stream) do
      {:ok, session}
    end
  end

  def tail_loop(session, serializer, callback, config \\ nil, reader \\ Serialization.reader()) do
    do_tail_loop(session, serializer, callback, config, reader, 0)
  end

  defp do_tail_loop(session, serializer, callback, config, reader, seq_num) do
    case S2.S2S.ReadSession.next_batch(session) do
      {:ok, batch, session} ->
        {messages, reader} = Serialization.decode(reader, batch.records, serializer)
        Enum.each(messages, callback)
        next_seq = next_seq_num(batch.records, seq_num)
        do_tail_loop(session, serializer, callback, config, reader, next_seq)

      {:error, :end_of_stream, _session} ->
        :ok

      {:error, _reason, _session} when config != nil ->
        case reconnect_reader(config, seq_num) do
          {:ok, session} ->
            do_tail_loop(session, serializer, callback, config, reader, seq_num)

          {:error, _reason} ->
            :ok
        end

      {:error, _reason, _session} ->
        :ok
    end
  end

  defp next_seq_num([], seq_num), do: seq_num

  defp next_seq_num(records, _seq_num) do
    last = List.last(records)
    last.seq_num + 1
  end

  defp reconnect_reader(config, seq_num) do
    with {:ok, conn} <- S2.S2S.Connection.open(config.base_url, token: config.token),
         {:ok, session} <- S2.S2S.ReadSession.open(conn, config.basin, config.stream, seq_num: seq_num) do
      {:ok, session}
    end
  end
end

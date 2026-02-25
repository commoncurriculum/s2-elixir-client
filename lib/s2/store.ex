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
        S2.Store.Server.start_link(__MODULE__, @otp_app)
      end

      def config do
        %{basin: @basin, serializer: @serializer, otp_app: @otp_app}
      end

      def append(stream, message, serializer \\ @serializer) do
        GenServer.call(__MODULE__, {:append, stream, message, serializer})
      end

      def create_stream(stream) do
        GenServer.call(__MODULE__, {:create_stream, stream})
      end

      def delete_stream(stream) do
        GenServer.call(__MODULE__, {:delete_stream, stream})
      end

      def listen(stream, callback, opts \\ []) do
        S2.Store.Server.listen(__MODULE__, stream, callback, opts)
      end

      defoverridable child_spec: 1
    end
  end
end

defmodule S2.Store.Server do
  @moduledoc false
  use GenServer

  alias S2.Patterns.Serialization

  def start_link(store_mod, otp_app) do
    GenServer.start_link(__MODULE__, {store_mod, otp_app}, name: store_mod)
  end

  def listen(store_mod, stream, callback, opts) do
    config = GenServer.call(store_mod, :get_config)
    seq_num = Keyword.get(opts, :from, 0)
    serializer = Keyword.get(opts, :serializer, config.serializer)

    Task.start(fn ->
      {:ok, conn} = S2.S2S.Connection.open(config.base_url, token: config.token)
      {:ok, session} = S2.S2S.ReadSession.open(conn, config.basin, stream, seq_num: seq_num)
      tail_loop(session, serializer, callback)
    end)
  end

  @impl true
  def init({store_mod, otp_app}) do
    store_config = store_mod.config()
    app_config = Application.get_env(otp_app, store_mod, [])

    base_url = Keyword.get(app_config, :base_url, "http://localhost:4243")
    token = Keyword.get(app_config, :token)

    config = S2.Config.new(base_url: base_url, token: token)
    client = S2.Client.new(config)
    {:ok, conn} = S2.S2S.Connection.open(base_url, token: token)

    {:ok, %{
      client: client,
      conn: conn,
      base_url: base_url,
      token: token,
      basin: store_config.basin,
      serializer: store_config.serializer,
      writer: Serialization.writer()
    }}
  end

  @impl true
  def handle_call({:append, stream, message, serializer}, _from, state) do
    {input, writer} = Serialization.prepare(state.writer, message, serializer)

    case S2.S2S.Append.call(state.conn, state.basin, stream, input) do
      {:ok, ack, conn} ->
        {:reply, {:ok, ack}, %{state | conn: conn, writer: writer}}

      {:error, reason, conn} ->
        {:reply, {:error, reason}, %{state | conn: conn, writer: writer}}
    end
  end

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

  def handle_call(:get_config, _from, state) do
    {:reply, %{
      base_url: state.base_url,
      token: state.token,
      basin: state.basin,
      serializer: state.serializer
    }, state}
  end

  defp tail_loop(session, serializer, callback, reader \\ Serialization.reader()) do
    case S2.S2S.ReadSession.next_batch(session) do
      {:ok, batch, session} ->
        {messages, reader} = Serialization.decode(reader, batch.records, serializer)
        Enum.each(messages, callback)
        tail_loop(session, serializer, callback, reader)

      {:error, :end_of_stream, _session} ->
        :ok

      {:error, _reason, _session} ->
        :ok
    end
  end
end

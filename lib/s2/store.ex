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

  ## Options

    * `:max_retries` — Maximum reconnection attempts before giving up (default: `:infinity`).
    * `:base_delay` — Base delay in ms for exponential backoff between retries (default: 500).
    * `:max_queue_size` — Maximum pending appends per stream worker before returning `{:error, :overloaded}` (default: 1000).
    * `:recv_timeout` — Timeout in milliseconds for individual S2S data plane operations (default: 5000).
    * `:compression` — Compression for S2S frames: `:none`, `:gzip`, or `:zstd` (default: `:none`). Zstd requires the optional `:ezstd` dependency.
    * `:serializer` — A map with `:serialize` and `:deserialize` functions (default: JSON via Jason).

  ## Listener options

  `listen/3` accepts these additional options:

    * `:from` — Where to start reading: an integer sequence number (default: `0`) or `:tail` to start from the end of the stream.
    * `:serializer` — Override the store's default serializer for this listener.
  """

  @typedoc "A serializer map with `:serialize` and `:deserialize` functions."
  @type serializer :: %{
    serialize: (term() -> binary()),
    deserialize: (binary() -> term())
  }

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
          token: Keyword.get(app_config, :token),
          max_retries: Keyword.get(app_config, :max_retries, :infinity),
          base_delay: Keyword.get(app_config, :base_delay, 500),
          max_queue_size: Keyword.get(app_config, :max_queue_size, 1000),
          recv_timeout: Keyword.get(app_config, :recv_timeout, 5_000),
          compression: Keyword.get(app_config, :compression, :none)
        }

        S2.Store.Supervisor.start_link(config)
      end

      def config do
        %{basin: @basin, serializer: @serializer, otp_app: @otp_app}
      end

      def append(stream, message, serializer \\ @serializer) do
        with {:ok, _pid} <- S2.Store.Supervisor.ensure_worker(__MODULE__, stream) do
          S2.Store.StreamWorker.append(__MODULE__, stream, message, serializer)
        end
      end

      def append_batch(stream, messages, serializer \\ @serializer) when is_list(messages) do
        with {:ok, _pid} <- S2.Store.Supervisor.ensure_worker(__MODULE__, stream) do
          S2.Store.StreamWorker.append_batch(__MODULE__, stream, messages, serializer)
        end
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

      def stop_listener(pid) do
        S2.Store.Supervisor.stop_listener(pid)
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

          def append_batch(stream, messages) do
            @__store__.append_batch(stream, messages, __serializer__())
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

          def stop_listener(pid) do
            @__store__.stop_listener(pid)
          end
        end
      end

      defoverridable child_spec: 1
    end
  end
end

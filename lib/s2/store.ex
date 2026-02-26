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
    * `:call_timeout` — Timeout in milliseconds for `append/2` and `append_batch/2` calls (default: 5000). Set higher if appends may take longer due to large payloads or high latency.
    * `:serializer` — A map with `:serialize` and `:deserialize` functions (default: JSON via Jason).

  ## Listener options

  `listen/3` accepts these additional options:

    * `:from` — Where to start reading: an integer sequence number (default: `0`) or `:tail` to start from the end of the stream.
    * `:serializer` — Override the store's default serializer for this listener.

  ## Callbacks

  When you `use S2.Store`, the following functions are generated:

    * `start_link/1` — Start the store supervisor.
    * `child_spec/1` — Supervisor child specification.
    * `config/0` — Returns the compile-time store configuration.
    * `append/2` — Append a message to a stream.
    * `append/3` — Append a message with a custom serializer.
    * `append_batch/2` — Append multiple messages to a stream.
    * `append_batch/3` — Append multiple messages with a custom serializer.
    * `create_stream/1` — Create a stream via the control plane.
    * `delete_stream/1` — Delete a stream via the control plane.
    * `listen/2` — Start a listener on a stream.
    * `listen/3` — Start a listener with options.
    * `stop_listener/1` — Stop a running listener by PID.
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
      @serializer Keyword.get(opts, :serializer, %{
                    serialize: &Jason.encode!/1,
                    deserialize: &Jason.decode!/1
                  })

      @doc false
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      @doc "Start the store and its supervision tree."
      @spec start_link(keyword()) :: Supervisor.on_start()
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
          compression: Keyword.get(app_config, :compression, :none),
          call_timeout: Keyword.get(app_config, :call_timeout, 5_000)
        }

        S2.Store.Supervisor.start_link(config)
      end

      @doc "Returns compile-time store configuration (basin, serializer, otp_app)."
      @spec config() :: map()
      def config do
        %{basin: @basin, serializer: @serializer, otp_app: @otp_app}
      end

      @doc """
      Append a message to a stream.

      The message is serialized, framed, and deduplicated before being sent.
      Returns `{:ok, ack}` with an `S2.V1.AppendAck` on success.
      """
      @spec append(String.t(), term(), S2.Store.serializer()) ::
              {:ok, S2.V1.AppendAck.t()} | {:error, term()}
      def append(stream, message, serializer \\ @serializer) do
        with {:ok, _pid} <- S2.Store.Supervisor.ensure_worker(__MODULE__, stream) do
          timeout = S2.Store.Supervisor.get_config(__MODULE__).call_timeout
          S2.Store.StreamWorker.append(__MODULE__, stream, message, serializer, timeout)
        end
      end

      @doc """
      Append multiple messages to a stream in a single batch.

      All messages are serialized and sent as one `AppendInput`. Returns
      `{:ok, ack}` with an `S2.V1.AppendAck` on success.
      """
      @spec append_batch(String.t(), [term()], S2.Store.serializer()) ::
              {:ok, S2.V1.AppendAck.t()} | {:error, term()}
      def append_batch(stream, messages, serializer \\ @serializer) when is_list(messages) do
        with {:ok, _pid} <- S2.Store.Supervisor.ensure_worker(__MODULE__, stream) do
          timeout = S2.Store.Supervisor.get_config(__MODULE__).call_timeout
          S2.Store.StreamWorker.append_batch(__MODULE__, stream, messages, serializer, timeout)
        end
      end

      @doc "Create a stream via the control plane."
      @spec create_stream(String.t()) :: {:ok, S2.StreamInfo.t()} | {:error, S2.Error.t()}
      def create_stream(stream) do
        S2.Store.Supervisor.create_stream(__MODULE__, stream)
      end

      @doc "Delete a stream via the control plane."
      @spec delete_stream(String.t()) :: :ok | {:error, S2.Error.t()}
      def delete_stream(stream) do
        S2.Store.Supervisor.delete_stream(__MODULE__, stream)
      end

      @doc """
      Start a listener that calls `callback` for each message on the stream.

      The listener runs in a supervised task. Returns `{:ok, pid}` where the PID
      can be passed to `stop_listener/1`.

      ## Options

        * `:from` — Starting position: integer sequence number (default: `0`) or `:tail`.
        * `:serializer` — Override the store's default serializer.
      """
      @spec listen(String.t(), (term() -> any()), keyword()) :: {:ok, pid()}
      def listen(stream, callback, opts \\ []) do
        S2.Store.Supervisor.listen(__MODULE__, stream, callback, opts)
      end

      @doc "Stop a running listener by PID."
      @spec stop_listener(pid()) :: :ok | {:error, :not_found}
      def stop_listener(pid) do
        S2.Store.Supervisor.stop_listener(__MODULE__, pid)
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

          @spec append(String.t(), term()) :: {:ok, S2.V1.AppendAck.t()} | {:error, term()}
          def append(stream, message) do
            @__store__.append(stream, message, __serializer__())
          end

          @spec append_batch(String.t(), [term()]) ::
                  {:ok, S2.V1.AppendAck.t()} | {:error, term()}
          def append_batch(stream, messages) do
            @__store__.append_batch(stream, messages, __serializer__())
          end

          @spec listen(String.t(), (term() -> any()), keyword()) :: {:ok, pid()}
          def listen(stream, callback, opts \\ []) do
            opts = Keyword.put_new(opts, :serializer, __serializer__())
            @__store__.listen(stream, callback, opts)
          end

          @spec create_stream(String.t()) :: {:ok, S2.StreamInfo.t()} | {:error, S2.Error.t()}
          def create_stream(stream) do
            @__store__.create_stream(stream)
          end

          @spec delete_stream(String.t()) :: :ok | {:error, S2.Error.t()}
          def delete_stream(stream) do
            @__store__.delete_stream(stream)
          end

          @spec stop_listener(pid()) :: :ok | {:error, :not_found}
          def stop_listener(pid) do
            @__store__.stop_listener(pid)
          end
        end
      end

      defoverridable child_spec: 1
    end
  end
end

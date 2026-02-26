defmodule S2.Store.Connector do
  @moduledoc false

  @max_backoff 30_000

  @type status :: :disconnected | :connected | :reconnecting | :failed
  @type t :: %__MODULE__{
          status: status(),
          attempt: non_neg_integer(),
          base_delay: pos_integer(),
          max_retries: pos_integer() | :infinity,
          max_backoff: pos_integer()
        }

  defstruct status: :disconnected,
            attempt: 0,
            base_delay: 500,
            max_retries: :infinity,
            max_backoff: @max_backoff

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      base_delay: Keyword.get(opts, :base_delay, 500),
      max_retries: Keyword.get(opts, :max_retries, :infinity)
    }
  end

  @spec connected(t()) :: t()
  def connected(%__MODULE__{} = conn) do
    %{conn | status: :connected, attempt: 0}
  end

  @spec begin_reconnect(t()) :: {:retry, pos_integer(), t()} | {:error, :max_retries_exceeded}
  def begin_reconnect(%__MODULE__{max_retries: max, attempt: attempt})
      when max != :infinity and attempt >= max do
    {:error, :max_retries_exceeded}
  end

  def begin_reconnect(%__MODULE__{} = conn) do
    attempt = conn.attempt + 1
    delay = backoff_delay(conn.base_delay, attempt, conn.max_backoff)
    {:retry, delay, %{conn | status: :reconnecting, attempt: attempt}}
  end

  @spec backoff_delay(pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  defp backoff_delay(base_delay, attempt, max_backoff) do
    delay = min(base_delay * Integer.pow(2, attempt - 1), max_backoff)
    jitter = :rand.uniform(max(div(delay, 2), 1))
    delay + jitter
  end
end

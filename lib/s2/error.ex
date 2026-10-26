defmodule S2.Error do
  @moduledoc """
  Error struct returned by all S2 operations (both control plane and data plane).

  Implements the `Exception` behaviour so it can be raised if needed, but is
  typically returned in `{:error, %S2.Error{}}` tuples.

  ## Fields

    * `:status` — HTTP status code (integer). Always present for HTTP errors and
      terminal S2S errors. May be `nil` for transport-level errors.
    * `:code` — Application error code string from S2 (e.g., `"not_found"`).
      Present when the server returns a structured JSON error body.
    * `:message` — Human-readable error description. Always present.
  """

  @type t :: %__MODULE__{
          status: integer() | nil,
          code: String.t() | nil,
          message: String.t() | nil
        }

  defexception [:code, :message, :status]

  @impl true
  def message(%__MODULE__{status: nil, code: nil, message: msg}), do: msg || "unknown error"
  def message(%__MODULE__{status: nil, code: code, message: nil}), do: "(#{code})"
  def message(%__MODULE__{status: nil, code: code, message: msg}), do: "(#{code}): #{msg}"
  def message(%__MODULE__{status: status, code: nil, message: nil}), do: "HTTP #{status}"
  def message(%__MODULE__{status: status, code: nil, message: msg}), do: "HTTP #{status}: #{msg}"

  def message(%__MODULE__{status: status, code: code, message: nil}),
    do: "HTTP #{status} (#{code})"

  def message(%__MODULE__{status: status, code: code, message: msg}),
    do: "HTTP #{status} (#{code}): #{msg}"

  def from_response(%{status: status, body: %{"code" => code, "message" => message}}) do
    %__MODULE__{code: code, message: message, status: status}
  end

  def from_response(%{status: status, body: body}) when is_binary(body) do
    %__MODULE__{message: body, status: status}
  end

  def from_response(%{status: status, body: _body}) do
    %__MODULE__{status: status}
  end

  @doc "An error from an HTTP status and its JSON (or plain) body."
  def from_http(status, body) do
    case Jason.decode(body) do
      {:ok, %{"code" => code, "message" => message}} ->
        %__MODULE__{status: status, code: code, message: message}

      _other ->
        %__MODULE__{status: status, message: body}
    end
  end

  @doc "An error from a terminal S2S frame: a 2-byte status, then the JSON body."
  def from_terminal(<<status::16-big, body::binary>>), do: from_http(status, body)
  def from_terminal(body), do: %__MODULE__{message: "malformed terminal frame: #{inspect(body)}"}

  @doc """
  Whether trying again may succeed: a timeout, throttling, a server error
  (including `server_draining`), a `transaction_conflict` (as when appends
  race to create a stream), or no status at all (the connection failed).
  """
  def retryable?(%__MODULE__{status: status, code: code}),
    do: status in [nil, 408, 429] or status >= 500 or code == "transaction_conflict"
end

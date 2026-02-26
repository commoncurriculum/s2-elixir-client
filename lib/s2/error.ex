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
end

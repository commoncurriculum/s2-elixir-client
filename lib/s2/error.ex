defmodule S2.Error do
  @moduledoc """
  Error struct returned by S2 operations.

  Fields:
  - `status` — HTTP status code (integer). Always present for HTTP errors and
    terminal S2S errors. May be `nil` for transport-level errors.
  - `code` — Application error code string from S2 (e.g., `"not_found"`).
    Present when the server returns a structured JSON error body.
  - `message` — Human-readable error description. Always present.
  """

  @type t :: %__MODULE__{
          status: integer() | nil,
          code: String.t() | nil,
          message: String.t() | nil
        }

  defstruct [:code, :message, :status]

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

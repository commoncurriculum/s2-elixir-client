defmodule S2.Error do
  defstruct [:code, :message, :status]

  @type t :: %__MODULE__{
          code: String.t() | nil,
          message: String.t() | nil,
          status: integer()
        }

  def from_response(%{status: status, body: body}) when is_map(body) do
    %__MODULE__{
      code: body["code"],
      message: body["message"],
      status: status
    }
  end

  def from_response(%{status: status, body: body}) when is_binary(body) do
    %__MODULE__{
      status: status,
      message: body
    }
  end
end

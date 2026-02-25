defmodule S2.Error do
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

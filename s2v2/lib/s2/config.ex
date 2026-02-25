defmodule S2.Config do
  @type t :: %__MODULE__{base_url: String.t(), token: String.t() | nil}

  defstruct [:base_url, :token]

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    base_url = Keyword.get(opts, :base_url, "http://localhost:4243")
    validate_base_url!(base_url)

    %__MODULE__{
      base_url: base_url,
      token: Keyword.get(opts, :token)
    }
  end

  defp validate_base_url!(url) do
    case URI.parse(url) do
      %URI{scheme: nil} -> raise ArgumentError, "base_url must have a scheme (http or https)"
      %URI{host: nil} -> raise ArgumentError, "base_url must have a host"
      _ -> :ok
    end
  end
end

defmodule S2.Config do
  @moduledoc """
  Configuration for the S2 control plane client.

  ## Options

    * `:base_url` — S2 API base URL (default: `"http://localhost:4243"`).
    * `:token` — Bearer token for authentication (default: `nil`).
  """

  @type t :: %__MODULE__{base_url: String.t(), token: String.t() | nil}

  defstruct [:base_url, :token]

  @doc """
  Create a new config from keyword options.

  Validates that `base_url` has a scheme and host.

  ## Examples

      S2.Config.new(base_url: "https://aws.s2.dev", token: "my-token")
      S2.Config.new()  # defaults to localhost:4243
  """
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
      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        raise ArgumentError, "base_url must have a scheme (http or https), got: #{inspect(scheme)}"
      %URI{host: nil} -> raise ArgumentError, "base_url must have a host"
      %URI{host: ""} -> raise ArgumentError, "base_url must have a host"
      _ -> :ok
    end
  end
end

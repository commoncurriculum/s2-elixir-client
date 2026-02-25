defmodule S2.Config do
  defstruct [:base_url, :token]

  @type t :: %__MODULE__{
          base_url: String.t(),
          token: String.t() | nil
        }

  def new(opts \\ []) do
    %__MODULE__{
      base_url: Keyword.get(opts, :base_url, "http://localhost:4243"),
      token: Keyword.get(opts, :token)
    }
  end
end

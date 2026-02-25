defmodule S2.BasinConfig do
  @moduledoc """
  Provides struct and type for a BasinConfig
  """

  @type t :: %__MODULE__{
          create_stream_on_append: boolean | nil,
          create_stream_on_read: boolean | nil,
          default_stream_config: S2.StreamConfig.t() | nil
        }

  defstruct [:create_stream_on_append, :create_stream_on_read, :default_stream_config]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      create_stream_on_append: :boolean,
      create_stream_on_read: :boolean,
      default_stream_config: {:union, [{S2.StreamConfig, :t}, :null]}
    ]
  end
end

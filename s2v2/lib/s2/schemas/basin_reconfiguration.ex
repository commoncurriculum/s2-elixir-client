defmodule S2.BasinReconfiguration do
  @moduledoc """
  Provides struct and type for a BasinReconfiguration
  """

  @type t :: %__MODULE__{
          create_stream_on_append: boolean | nil,
          create_stream_on_read: boolean | nil,
          default_stream_config: S2.StreamReconfiguration.t() | nil
        }

  defstruct [:create_stream_on_append, :create_stream_on_read, :default_stream_config]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      create_stream_on_append: {:union, [:boolean, :null]},
      create_stream_on_read: {:union, [:boolean, :null]},
      default_stream_config: {:union, [{S2.StreamReconfiguration, :t}, :null]}
    ]
  end
end

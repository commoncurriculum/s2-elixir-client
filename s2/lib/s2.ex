defmodule S2 do
  @moduledoc """
  Elixir client library for the S2 streaming data platform.
  """

  def client(opts \\ []) do
    opts
    |> S2.Config.new()
    |> S2.Client.new()
  end
end

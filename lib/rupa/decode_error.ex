defmodule Rupa.DecodeError do
  @moduledoc """
  Raised by `Rupa.decode!/3` when the data does not match the schema.

  Carries every error the decode produced — one, under the default `on_error: :halt`.
  """

  alias Rupa.Error

  @type t :: %__MODULE__{errors: [Error.t()]}

  defexception errors: []

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{errors: errors}) do
    lines =
      Enum.map_join(errors, "\n", fn error ->
        "  " <> location(error) <> " " <> Error.message(error)
      end)

    "data does not match the schema:\n" <> lines
  end

  defp location(%Error{path: []}), do: "the value"
  defp location(error), do: Error.pointer(error)
end

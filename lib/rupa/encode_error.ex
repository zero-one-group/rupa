defmodule Rupa.EncodeError do
  @moduledoc """
  Raised by `Rupa.encode!/3` when a value does not match the schema it is being encoded against.

  Its own exception rather than a shared one, because the two failures mean different things:
  a decode error is the outside world being wrong, and an encode error is your own code being
  wrong about a value it built.
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

    "value does not match the schema:\n" <> lines
  end

  defp location(%Error{path: []}), do: "the value"
  defp location(error), do: Error.pointer(error)
end

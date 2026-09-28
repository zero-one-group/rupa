defmodule Rupa.SchemaError do
  @moduledoc """
  Raised by the bang variants when a schema is not well formed.

  Carries every error found, not just the first: a schema is small enough to check completely,
  and a list of five problems is worth more than five runs.
  """

  alias Rupa.Error

  @type t :: %__MODULE__{errors: [Error.t()]}

  defexception errors: []

  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{errors: errors}) do
    lines =
      Enum.map_join(errors, "\n", fn error ->
        "  " <> location(error) <> ": " <> Error.message(error)
      end)

    "schema is not well formed:\n" <> lines
  end

  defp location(%Error{path: []}), do: "at the root"
  defp location(error), do: "at " <> Error.pointer(error)
end

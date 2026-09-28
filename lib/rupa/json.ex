defmodule Rupa.Json do
  @moduledoc """
  The JSON edge: bytes in through OTP's `:json`, iodata out from the staged program.

  The two directions are not the same problem, and only one of them fuses.

  **Encoding does.** `Rupa.encode_json/3` walks the decoded value once and emits iodata, so the
  wire map `Rupa.encode/3` would have built is never built at all. Wire keys and constant values
  are rendered to binaries while the schema is staged, so what is left at run time is escaping
  the strings your value actually carries and consing the pieces together.

  **Decoding does not**, and the reason is the callback API rather than anything about Rupa.
  `:json.decode/3` hands a value's key to `object_push` only after that value is already built,
  so when a nested object starts, nothing in scope says which field it belongs to — and a field
  is exactly where a schema differs from a parser. The accumulator threads down through
  `object_start` and `array_start`, which is enough to direct the root and an array's elements,
  and not enough for an object's fields. So `Rupa.decode_json/3` is `:json.decode/3` followed by
  `Rupa.decode/3`, which is what the name promises and no more. `bench/json.exs` is the
  measurement; a Rupa-owned parser is the way past it, and not in 0.1.0.

  Nothing here is public API. `Rupa.decode_json/3` and `Rupa.encode_json/3` are.

  ## The iodata shape

  Both backends build an object or an array as a reversed list of entries, each one carrying its
  own leading comma, and the helper that closes the bracket drops the first comma again. That is
  how OTP's own encoder does it, and it is why a field costs one cons cell rather than a branch
  on whether it is the first.
  """

  alias Rupa.Error

  # =============================================
  # Bytes in
  # =============================================

  @doc false
  @spec parse(binary()) :: {:ok, term()} | {:error, [Error.t()]}
  def parse(binary) when is_binary(binary) do
    # `null: nil` rather than the default atom `null`: three states are present, absent and
    # null, and `nil` is the one Rupa decodes a JSON null to. It costs nothing — the parser
    # substitutes the term inline rather than calling anything.
    {value, :ok, rest} = :json.decode(binary, :ok, %{null: nil})

    if blank?(rest), do: {:ok, value}, else: invalid({:trailing, rest})
  rescue
    error in ErlangError -> invalid(error.original)
  end

  def parse(other), do: invalid({:not_text, other})

  defp invalid(reason), do: {:error, [Error.new([], :json, %{reason: reason})]}

  defp blank?(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\r, ?\n], do: blank?(rest)
  defp blank?(<<>>), do: true
  defp blank?(_rest), do: false

  # =============================================
  # Iodata out
  # =============================================

  # A string schema accepts any binary, but JSON text has to be UTF-8, so this is the boundary
  # that says so. `decode/3` and `encode/3` still take a non-UTF-8 binary -- only turning it into
  # JSON fails -- and it fails as a path-bearing error rather than an `ErlangError` out of the
  # encoder. The error carries an empty path; the field chain that called this stacks its own.
  @doc false
  @spec encode_string(binary()) :: {:ok, binary()} | {:error, [Error.t()]}
  def encode_string(value) do
    {:ok, :json.encode_binary(value)}
  rescue
    ErlangError -> {:error, [Error.new([], :invalid_utf8, %{value: value})]}
  end

  @doc false
  @spec key(String.t()) :: binary()
  def key(wire), do: IO.iodata_to_binary([:json.encode_binary(wire), ?:])

  @doc false
  @spec literal(term()) :: binary()
  def literal(term), do: IO.iodata_to_binary(:json.encode(term))

  # A whole entry that the schema already knows both halves of, rendered once at staging.
  @doc false
  @spec constant(String.t(), term()) :: binary()
  def constant(wire_key, wire_value),
    do: <<?,, key(wire_key)::binary, literal(wire_value)::binary>>

  @doc false
  @spec object([iodata()]) :: iodata()
  def object([]), do: "{}"
  def object([<<?,, first::binary>> | rest]), do: [?{, first, rest, ?}]
  def object([[_comma | first] | rest]), do: [?{, first, rest, ?}]

  @doc false
  @spec array([iodata()]) :: iodata()
  def array([]), do: "[]"
  def array([[_comma | first] | rest]), do: [?[, first, rest, ?]]

  # Closes an object over the accumulator its field chain built, which is in reverse.
  @doc false
  @spec wrap({:ok, [iodata()]} | {:error, [Error.t()]}) :: {:ok, iodata()} | {:error, [Error.t()]}
  def wrap({:ok, acc}), do: {:ok, object(:lists.reverse(acc))}
  def wrap({:error, _errors} = error), do: error

  # The same four key types `:json` itself accepts, so a map-of encodes to the same bytes whichever
  # route it took. A binary key is the one that can fail on its bytes -- a non-UTF-8 map key is
  # `:invalid_utf8` at the boundary rather than an `ErlangError` -- and anything else is
  # `:unsupported_key`: a decoded map may hold a tuple key, since `decode/3` reads a term as it
  # is, but a JSON object's names are strings and a tuple has no string form.
  @doc false
  @spec encode_key(term()) :: {:ok, iodata()} | {:error, [Error.t()]}
  def encode_key(key) when is_binary(key) do
    {:ok, :json.encode_binary(key)}
  rescue
    ErlangError -> {:error, [Error.new([], :invalid_utf8, %{value: key})]}
  end

  def encode_key(key) when is_atom(key), do: {:ok, :json.encode_binary(Atom.to_string(key))}
  def encode_key(key) when is_integer(key), do: {:ok, [?", :json.encode_integer(key), ?"]}
  def encode_key(key) when is_float(key), do: {:ok, [?", :json.encode_float(key), ?"]}
  def encode_key(key), do: {:error, [Error.new([], :unsupported_key, %{key: key})]}

  # `encode_key/1` for one entry of an object being emitted, with the names already written in
  # this object: two keys of different types can render to one JSON name (`1` and `"1"`, `:a` and
  # `"a"`), and an object carrying a name twice is one where the consumer decides which value
  # survived. So the second is `:duplicate_key` instead. `seen` is a map of rendered name to
  # `true`; the caller seeds it with the names it has already written and threads it through.
  @doc false
  @spec entry_key(term(), %{optional(String.t()) => true}) ::
          {:ok, iodata(), %{optional(String.t()) => true}} | {:error, [Error.t()]}
  def entry_key(key, seen) do
    with {:ok, wire} <- encode_key(key) do
      name = member_name(key)

      if Map.has_key?(seen, name),
        do: {:error, [Error.new([], :duplicate_key, %{key: name})]},
        else: {:ok, wire, Map.put(seen, name, true)}
    end
  end

  defp member_name(key) when is_binary(key), do: key
  defp member_name(key) when is_atom(key), do: Atom.to_string(key)
  defp member_name(key) when is_integer(key), do: Integer.to_string(key)
  defp member_name(key) when is_float(key), do: IO.iodata_to_binary(:json.encode_float(key))

  # `unknown: :keep` put the wire's extra keys in the decoded map, so encoding writes them back.
  # `claims` is the pair an object knows at staging: the keys its fields claim
  # (`IR.Field.claimed/1`, so an extra that *is* a field's name is skipped, as decode skipped it),
  # and the names its fields write, which seed the duplicate check so an extra cannot render to a
  # field's name. Kept values are written by `kept/2` rather than `:json.encode/2`: Rupa decodes
  # a JSON null to `nil`, which `:json` would write as the string `"nil"`; and a kept value that
  # cannot be JSON -- a non-UTF-8 binary, a tuple, a key with no string form -- is an error
  # carrying the path to it, under `mode`, rather than a raise or a path that stops at the object.
  @doc false
  @spec extra(
          :strip | :error | :keep,
          map(),
          {MapSet.t(), MapSet.t()},
          [iodata()],
          :halt | :collect
        ) ::
          {:ok, [iodata()]} | {:error, [Error.t()]}
  def extra(:keep, value, {known, names}, acc, mode) do
    seen = Map.from_keys(MapSet.to_list(names), true)

    value
    |> Rupa.IR.Field.extras(known)
    |> Enum.sort()
    |> entries(seen, mode, acc, [])
  end

  def extra(_policy, _value, _claims, acc, _mode), do: {:ok, acc}

  defp entries([], _seen, _mode, acc, []), do: {:ok, acc}
  defp entries([], _seen, _mode, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp entries([{key, held} | rest], seen, mode, acc, errors) do
    with {:ok, wire_key, seen} <- entry_key(key, seen),
         {:ok, wire} <- kept(held, mode) do
      entries(rest, seen, mode, [[?,, wire_key, ?: | wire] | acc], errors)
    else
      {:error, found} ->
        errors = Enum.reduce(prefix(found, key), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: entries(rest, seen, mode, acc, errors)
    end
  end

  # A kept value, as `:json.encode/1` would write it, except that `nil` is `null`, a struct is not
  # an object, and every failure is a path-bearing error.
  defp kept(nil, _mode), do: {:ok, "null"}
  defp kept(true, _mode), do: {:ok, "true"}
  defp kept(false, _mode), do: {:ok, "false"}
  defp kept(value, _mode) when is_binary(value), do: encode_string(value)
  defp kept(value, _mode) when is_integer(value), do: {:ok, :json.encode_integer(value)}
  defp kept(value, _mode) when is_float(value), do: {:ok, :json.encode_float(value)}

  defp kept(value, _mode) when is_atom(value),
    do: {:ok, :json.encode_binary(Atom.to_string(value))}

  defp kept(value, mode) when is_list(value), do: items(value, 0, mode, [], [])

  defp kept(value, mode) when is_map(value) and not is_struct(value) do
    with {:ok, acc} <- value |> Enum.sort() |> entries(%{}, mode, [], []) do
      {:ok, object(:lists.reverse(acc))}
    end
  end

  defp kept(value, _mode), do: {:error, [Error.new([], :unsupported_value, %{value: value})]}

  defp items([], _index, _mode, acc, []), do: {:ok, array(:lists.reverse(acc))}
  defp items([], _index, _mode, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp items([item | rest], index, mode, acc, errors) do
    case kept(item, mode) do
      {:ok, wire} ->
        items(rest, index + 1, mode, [[?, | wire] | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: items(rest, index + 1, mode, acc, errors)
    end
  end

  defp prefix(errors, segment), do: Enum.map(errors, &%{&1 | path: [segment | &1.path]})
end

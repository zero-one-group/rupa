defmodule Rupa.Error do
  @moduledoc """
  A structured error: where, what, and the few values the message needs.

  Nothing here renders a string until you ask for one. `message/1` builds the sentence from
  `code` and `meta` on demand, so a run that produces no errors never builds a message, and a
  run that produces a thousand pays for the ones you actually print.

  `path` locates the offending node. What it is a path *through* depends on who built the
  error: `Rupa.Schema.validate/1` returns paths through the schema, where `:of` is a list's
  element, an integer is a tuple position, a string is a tagged branch, and `:defs` leads into
  the definitions. Decoding returns paths through the data.
  """

  @type segment :: atom() | String.t() | non_neg_integer()
  @type t :: %__MODULE__{path: [segment()], code: atom(), meta: map()}

  @enforce_keys [:code]
  defstruct path: [], code: nil, meta: %{}

  @doc """
  Builds an error.

      iex> Rupa.Error.new([:age], :unknown_option, %{option: :fmt})
      %Rupa.Error{path: [:age], code: :unknown_option, meta: %{option: :fmt}}
  """
  @spec new([segment()], atom(), map()) :: t()
  def new(path, code, meta \\ %{}) do
    %__MODULE__{path: path, code: code, meta: meta}
  end

  @doc """
  Renders the error as a sentence.

      iex> [:name] |> Rupa.Error.new(:unknown_format, %{format: :ssn}) |> Rupa.Error.message()
      ":ssn is not one of Rupa's built-in formats"
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{code: code, meta: meta}), do: render(code, meta)

  @doc """
  The path as an RFC 6901 JSON pointer.

      iex> Rupa.Error.pointer(Rupa.Error.new([:addresses, 0, :street], :min))
      "/addresses/0/street"

      iex> Rupa.Error.pointer(Rupa.Error.new([], :unknown_type))
      ""

  A segment is a field name, an index or a wire key. A `map_of` key can be any term when the map
  came from Elixir rather than from JSON, so a segment with no string of its own -- a tuple, say
  -- is written the way `inspect/1` writes it, escaped like any other.

      iex> Rupa.Error.pointer(Rupa.Error.new([:by, {1, 2}], :type))
      "/by/{1, 2}"
  """
  @spec pointer(t()) :: String.t()
  def pointer(%__MODULE__{path: path}) do
    Enum.map_join(path, "", fn segment -> "/" <> escape(segment_text(segment)) end)
  end

  defp segment_text(segment) when is_binary(segment), do: segment
  defp segment_text(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp segment_text(nil), do: "nil"
  defp segment_text(segment) when is_atom(segment), do: Atom.to_string(segment)
  defp segment_text(segment), do: inspect(segment)

  defp escape(segment) do
    segment |> String.replace("~", "~0") |> String.replace("/", "~1")
  end

  defp render(:unknown_type, %{value: value}) do
    "#{inspect(value)} is not a Rupa schema"
  end

  defp render(:unknown_option, %{option: option, kind: kind}) do
    "#{kind} does not take the option #{inspect(option)}"
  end

  defp render(:invalid_option, %{option: option, value: value, expected: expected}) do
    "#{inspect(option)} expects #{expected}, got #{inspect(value)}"
  end

  defp render(:duplicate_option, %{option: option}) do
    "#{inspect(option)} is given more than once"
  end

  defp render(:conflicting_options, %{options: options}) do
    "#{list(options)} cannot be combined"
  end

  defp render(:contradictory_bounds, %{options: options}) do
    "no value satisfies both #{list(options)}"
  end

  defp render(:function_in_schema, %{option: option}) do
    "#{inspect(option)} holds a function; a schema is data all the way down"
  end

  defp render(:unknown_format, %{format: format}) do
    "#{inspect(format)} is not one of Rupa's built-in formats"
  end

  defp render(:invalid_pattern, %{reason: reason}) do
    "pattern does not compile: #{reason}"
  end

  defp render(:invalid_field_name, %{field: field}) do
    "object field names are atoms or strings, got #{inspect(field)}"
  end

  defp render(:invalid_def_name, %{name: name}) do
    "defs: names are atoms, because a ref names one, got #{inspect(name)}"
  end

  defp render(:mixed_field_names, %{}) do
    "an object's field names are all atoms or all strings, not both"
  end

  defp render(:struct_keys, %{names: :atom}) do
    "into: builds a struct, whose keys are atoms, so keys: :string cannot hold with it"
  end

  defp render(:struct_keys, %{names: :string}) do
    "into: builds a struct, whose keys are atoms, so a string-named object needs keys: :atom"
  end

  defp render(:struct_keeps_unknown, %{}) do
    "into: builds a struct, which has nowhere to put the keys unknown: :keep would carry"
  end

  defp render(:not_a_struct, %{module: module}) do
    "into: expects a module with a defstruct, loaded before the codec compiles; " <>
      "#{inspect(module)} is not one"
  end

  defp render(:struct_field_missing, %{module: module, keys: keys}) do
    "#{inspect(module)}'s fields do not include #{Enum.map_join(keys, ", ", &inspect/1)}; " <>
      "re-run mix rupa.gen.struct, or fix the schema"
  end

  defp render(:struct, %{expected: module, value: value}) do
    "expected %#{inspect(module)}{}, got #{inspect(value)}"
  end

  defp render(:unresolved_ref, %{name: name}) do
    "#{inspect(name)} has no entry in defs:"
  end

  defp render(:circular_ref, %{name: name}) do
    "#{inspect(name)} is a cycle of refs with no schema in it, so nothing could ever decode"
  end

  defp render(:invalid_default, %{value: value}) do
    "#{inspect(value)} is not a valid value for this field, so it cannot be its default"
  end

  defp render(:recursive_default, %{value: value}) do
    "default: #{inspect(value)} reaches this field again, so every time it fires it materialises " <>
      "one more level of itself and no value of it is ever stable; make the recursion optional, " <>
      "nullable or a list and default that instead"
  end

  defp render(:duplicate_def, %{name: name}) do
    "defs: declares #{inspect(name)} twice, with different schemas"
  end

  defp render(:misplaced_optional, %{}) do
    "T.optional/1 says a key may be absent, so it only means anything on an object field"
  end

  defp render(:nested_nullable, %{}) do
    "T.nullable/1 cannot wrap another T.nullable/1, or T.null/0 -- both already allow null"
  end

  defp render(:misplaced_rename, %{option: option}) do
    "#{inspect(option)} names an object field's wire key, so it belongs on the field's own term"
  end

  defp render(:misplaced_default, %{}) do
    "default: fires when an object field is absent, so it belongs on the field's own term and " <>
      "can never fire here"
  end

  defp render(:reserved_field_name, %{field: field}) do
    "#{inspect(field)} is the BEAM's struct tag, and a decoded map carrying it would pass for a " <>
      "struct; it cannot be a field name"
  end

  defp render(:reserved_def_name, %{name: name}) do
    "#{inspect(name)} is the name the schema itself answers to, so a defs: entry under it could " <>
      "only be shadowed; pick another name"
  end

  defp render(:duplicate_wire_key, %{key: key}) do
    "two fields map to the wire key #{inspect(key)}"
  end

  defp render(:nested_default, %{}) do
    "default: belongs on the outer term, not on what T.optional/1 or T.nullable/1 wraps"
  end

  defp render(:empty_enum, %{}) do
    "an enum needs at least one value"
  end

  defp render(:invalid_scalar, %{value: value}) do
    "expected a string, atom, number or boolean, got #{inspect(value)}"
  end

  defp render(:duplicate_enum_value, %{value: value}) do
    "#{inspect(value)} is listed twice"
  end

  defp render(:untagged_union_needs_opt_in, %{}) do
    "an untagged union costs one attempt per variant, so it is opt-in: pass tag: :none"
  end

  defp render(:union_too_small, %{}) do
    "a union needs at least two variants"
  end

  defp render(:invalid_tag, %{value: value}) do
    "tag: expects an atom other than :none, got #{inspect(value)}"
  end

  defp render(:tag_content_conflict, %{tag: tag}) do
    "tag: and content: are both #{inspect(tag)}, so the tag and the branch want the same key"
  end

  defp render(:tag_wire_conflict, %{key: key}) do
    "a branch field uses #{inspect(key)}, which is the tag's own wire key"
  end

  defp render(:untagged_branch, %{}) do
    "an internally tagged branch carries the tag, so every branch is an object"
  end

  defp render(:empty_branches, %{}) do
    "a tagged union needs at least one branch"
  end

  defp render(:invalid_branch_name, %{value: value}) do
    "tag values are strings, got #{inspect(value)}"
  end

  defp render(:type, %{expected: expected, value: value}) do
    "expected #{article(expected)}, got #{inspect(value)}"
  end

  defp render(:required, %{}) do
    "is required"
  end

  defp render(:min, %{min: min, unit: unit}) do
    "must have at least #{min} #{unit}"
  end

  defp render(:max, %{max: max, unit: unit}) do
    "must have at most #{max} #{unit}"
  end

  defp render(:len, %{len: len}) do
    "must be exactly #{len} characters"
  end

  defp render(:pattern, %{pattern: pattern}) do
    "must match #{pattern}"
  end

  defp render(:format, %{format: format}) do
    "is not a valid #{format}"
  end

  defp render(:invalid_utf8, %{value: value}) do
    "cannot be encoded as JSON: #{inspect(value)} is not valid UTF-8"
  end

  defp render(:duplicate_key, %{key: key}) do
    "cannot be encoded as JSON: two keys render to the name #{inspect(key)}, so the object " <>
      "would carry it twice and the reader would pick the value"
  end

  defp render(:unsupported_key, %{key: key}) do
    "cannot be encoded as JSON: an object's names are strings, and #{inspect(key)} has no " <>
      "string form (a string, an atom, an integer or a float does)"
  end

  defp render(:unsupported_value, %{value: value}) do
    "cannot be encoded as JSON: #{inspect(value)} has no JSON form"
  end

  defp render(:gte, %{gte: bound}), do: "must be at least #{bound}"
  defp render(:gt, %{gt: bound}), do: "must be greater than #{bound}"
  defp render(:lte, %{lte: bound}), do: "must be at most #{bound}"
  defp render(:lt, %{lt: bound}), do: "must be less than #{bound}"

  defp render(:multiple_of, %{multiple_of: step}) do
    "must be a multiple of #{step}"
  end

  defp render(:unique, %{}) do
    "must not repeat a value"
  end

  defp render(:const, %{value: value, allowed: allowed}) do
    "must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}, got #{inspect(value)}"
  end

  defp render(:unknown_key, %{key: key}) do
    "#{inspect(key)} is not a key this schema knows"
  end

  defp render(:unknown_tag, %{value: value, allowed: allowed}) do
    "#{inspect(value)} is not a branch of this union, which has " <>
      Enum.map_join(allowed, ", ", &inspect/1)
  end

  defp render(:no_variant, %{value: value, tried: tried}) do
    "none of the #{tried} variants of this union accepted #{inspect(value)}"
  end

  defp render(:tuple_size, %{expected: expected, actual: actual}) do
    "expected #{expected} elements, got #{actual}"
  end

  defp render(:ambiguous_const, %{values: values}) do
    "two of #{Enum.map_join(values, ", ", &inspect/1)} decode from the same wire value"
  end

  defp render(:already_compiled, %{name: name}) do
    "#{inspect(name)} is already a codec for a different schema; pass force: true to replace it"
  end

  defp render(:codec_in_use, %{name: name}) do
    "#{inspect(name)} cannot be replaced while a process is still running its code"
  end

  defp render(:name_taken, %{name: name}) do
    "#{inspect(name)} is already a module, and not one Rupa generated"
  end

  defp render(:unsupported_keyword, %{keyword: keyword}) do
    "#{keyword} has no equivalent in Rupa's vocabulary, which is JSON Schema's declarative subset"
  end

  defp render(:unsupported_schema, %{value: value}) do
    "#{inspect(value)} is not a schema Rupa can read"
  end

  defp render(:unsupported_type_union, %{types: types}) do
    "each of #{Enum.map_join(types, ", ", &inspect/1)} would need its own constraints, and " <>
      "the document does not say which belong to which"
  end

  defp render(:untyped_schema, %{}) do
    "a schema with no type constrains one kind of value and passes every other, which Rupa " <>
      "cannot say"
  end

  defp render(:unsupported_mixed_object, %{}) do
    "properties and additionalProperties together is an object and a map-of at once"
  end

  defp render(:unsupported_format_constraint, %{format: format, checks: checks}) do
    "a #{Enum.join(checks, "/")} check on the #{format} format cannot hold: the format decodes " <>
      "to a value and re-encodes to a canonical spelling, which the check on the incoming one " <>
      "need not match"
  end

  defp render(:unsupported_open_tuple, %{size: size}) do
    "prefixItems leaves the length open; a Rupa tuple is exactly #{size} long, so the " <>
      "document has to pin both ends"
  end

  defp render(:unsupported_bare_required, %{name: name}) do
    "#{inspect(name)} is required but not described, and Rupa cannot say that a key must be " <>
      "there and may hold anything"
  end

  defp render(:unsupported_ref, %{ref: ref}) do
    "#{inspect(ref)} is not a ref Rupa resolves, which is #/$defs/<name> and nothing else"
  end

  defp render(:unsupported_ref_siblings, %{}) do
    "a $ref beside other keywords would drop them, and Rupa has nowhere to fold them in"
  end

  defp render(:invalid_keyword, %{keyword: keyword}) do
    "the #{keyword} keyword does not hold a value of the right shape"
  end

  defp render(:unsupported_recursive_ref, %{name: name}) do
    "#{inspect(name)} is on a cycle, and a recursive ref needs a name Rupa would have to intern"
  end

  defp render(:json, %{reason: reason}), do: "invalid JSON: " <> json(reason)

  defp json({:invalid_byte, byte}), do: "unexpected byte 0x#{Integer.to_string(byte, 16)}"
  defp json({:unexpected_sequence, bytes}), do: "invalid escape #{inspect(bytes)}"
  defp json(:unexpected_end), do: "the text ends in the middle of a value"
  defp json({:trailing, rest}), do: "more text after the value: #{inspect(rest)}"
  defp json({:not_text, value}), do: "expected text, got #{inspect(value)}"

  defp article(kind) when kind in [:object, :array, :integer], do: "an #{kind}"
  defp article(kind), do: "a #{kind}"

  defp list(options) do
    options |> Enum.map(&inspect/1) |> Enum.join(" and ")
  end
end

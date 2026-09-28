defmodule Rupa.Closure do
  @moduledoc """
  The closure backend: `Rupa.IR` in, a tree of anonymous functions out.

  One function per IR node, each closing over everything the node decided at staging time —
  the compiled regex, the format's decoder, the wire key, the default. A decode is then a walk
  down a tree of calls with no interpretation and no lookups, except at a recursive ref, which
  is the one place a table is consulted.

  Every decoder has the same shape, `(value, ctx) -> {:ok, decoded} | {:error, [Rupa.Error])`,
  where `ctx` is `{mode, defs}`. Paths are built on the way back up: a leaf reports an error
  with an empty path and each parent prepends its own segment, so a successful decode allocates
  nothing for paths at all.
  """

  alias Rupa.Error
  alias Rupa.Format
  alias Rupa.IR
  alias Rupa.Json

  # The largest and smallest finite IEEE-754 double. A JSON integer outside this range is a valid
  # number but not a representable float, so it is a type error rather than an `ArithmeticError`
  # out of the `value * 1.0` that would coerce it.
  @float_max 1.7976931348623157e308
  @float_min -1.7976931348623157e308

  @type ctx :: {:halt | :collect, %{atom() => decoder()}}
  @type decoder :: (term(), ctx() -> {:ok, term()} | {:error, [Error.t()]})

  @doc """
  Builds the root decoder and the table the recursive refs resolve against.

  `Rupa.Codec.new/2` calls this and its two siblings; you reach what they build through
  `Rupa.decode/3` rather than by holding one:

      {:ok, program} = Rupa.Stage.run(%{name: Rupa.T.string()})
      {decode, defs} = Rupa.Closure.build(program)
      decode.(%{"name" => "Ada"}, {:halt, defs})
      #=> {:ok, %{name: "Ada"}}
  """
  @spec build(IR.program()) :: {decoder(), %{atom() => decoder()}}
  def build(%{root: root, defs: defs}) do
    {decoder(root), Map.new(defs, fn {name, ir} -> {name, decoder(ir)} end)}
  end

  @doc "The same as `build/1`, and used the same way, in the other direction."
  @spec build_encoder(IR.program()) :: {decoder(), %{atom() => decoder()}}
  def build_encoder(%{defs: defs} = program) do
    # An untagged union's encoder verifies its branch choice by decoding what it wrote (see
    # `union_encode/5`), so it is built with decoders in hand. `dd` threads that map down to the
    # union nodes; every other node ignores it. The table is the *symmetric* program's, the same
    # copy the union's own verifier is built from, so a renamed field inside a recursive definition
    # is read back through the name the encoder wrote rather than through its input name.
    {_root_decoder, dd} = build(IR.Rewrite.symmetric_program(program))
    {encoder(program.root, dd), Map.new(defs, fn {name, ir} -> {name, encoder(ir, dd)} end)}
  end

  @doc """
  The other direction again, straight to JSON iodata rather than to a wire term.

  Built and used exactly as `build/1` is; what it hands back emits bytes rather than a term.
  """
  @spec build_json(IR.program()) :: {decoder(), %{atom() => decoder()}}
  def build_json(%{defs: defs} = program) do
    # As in `build_encoder/1`: a union's JSON emitter verifies its branch by decoding, so it is
    # handed the symmetric program's decoders. `dd` threads that map down to the union nodes.
    {_root_decoder, dd} = build(IR.Rewrite.symmetric_program(program))
    {json(program.root, dd), Map.new(defs, fn {name, ir} -> {name, json(ir, dd)} end)}
  end

  # =============================================
  # Scalars
  # =============================================

  defp decoder(%IR.Scalar{kind: :string, checks: checks, format: format}) do
    checkers = Enum.map(checks, &string_check/1)
    convert = format_convert(format)

    fn
      value, _ctx when is_binary(value) -> run(value, checkers, convert)
      value, _ctx -> type_error(:string, value)
    end
  end

  defp decoder(%IR.Scalar{kind: :integer, checks: checks}) do
    checkers = Enum.map(checks, &number_check/1)

    fn
      value, _ctx when is_integer(value) -> run(value, checkers, nil)
      value, _ctx -> type_error(:integer, value)
    end
  end

  defp decoder(%IR.Scalar{kind: :float, checks: checks}) do
    checkers = Enum.map(checks, &number_check/1)

    fn
      value, _ctx when is_float(value) ->
        run(value, checkers, nil)

      value, _ctx when is_integer(value) and value >= @float_min and value <= @float_max ->
        run(value * 1.0, checkers, nil)

      value, _ctx ->
        type_error(:float, value)
    end
  end

  defp decoder(%IR.Scalar{kind: :boolean}) do
    fn
      value, _ctx when is_boolean(value) -> {:ok, value}
      value, _ctx -> type_error(:boolean, value)
    end
  end

  defp decoder(%IR.Scalar{kind: :null}) do
    fn
      nil, _ctx -> {:ok, nil}
      value, _ctx -> type_error(:null, value)
    end
  end

  defp decoder(%IR.Const{lookup: lookup, values: values}) do
    fn value, _ctx ->
      case Map.fetch(lookup, value) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> leaf(:const, %{value: value, allowed: values})
      end
    end
  end

  # =============================================
  # Containers
  # =============================================

  defp decoder(%IR.Object{fields: fields, unknown: unknown, into: nil}) do
    built = Enum.map(fields, fn field -> {field, decoder(field.ir)} end)
    known = known_keys(fields, unknown)

    fn
      value, ctx when is_map(value) -> object(value, built, unknown, known, ctx)
      value, _ctx -> type_error(:object, value)
    end
  end

  defp decoder(%IR.Object{fields: fields, unknown: unknown, into: module}) do
    built = Enum.map(fields, fn field -> {field, decoder(field.ir)} end)
    known = known_keys(fields, unknown)
    base = module.__struct__()

    fn
      value, ctx when is_map(value) -> object_into(value, built, unknown, known, base, ctx)
      value, _ctx -> type_error(:object, value)
    end
  end

  defp decoder(%IR.Array{of: inner, checks: checks}) do
    inner_decoder = decoder(inner)
    {check_unique, bounds} = Keyword.pop(checks, :unique, false)
    checkers = Enum.map(bounds, &array_check/1)

    fn
      value, ctx when is_list(value) and length(value) >= 0 ->
        # min/max are length checks and decoding never drops an element, so they run on the input.
        # Uniqueness is of the *decoded* values -- two wire elements that differ only where
        # decoding discards (a stripped extra key, an int that decodes like a float) collapse to
        # one, and it has to see that -- so it runs on the result.
        with {:ok, _value} <- run(value, checkers, nil),
             {:ok, decoded} <- elements(value, 0, inner_decoder, ctx, [], []) do
          if check_unique and not unique?(decoded),
            do: leaf(:unique, %{}),
            else: {:ok, decoded}
        end

      value, _ctx ->
        type_error(:array, value)
    end
  end

  defp decoder(%IR.Fixed{members: member_irs}) do
    built = Enum.map(member_irs, &decoder/1)
    size = length(built)

    fn
      value, ctx when is_list(value) and length(value) == size ->
        members(value, built, 0, ctx, [], [])

      value, _ctx when is_list(value) and length(value) >= 0 ->
        leaf(:tuple_size, %{expected: size, actual: length(value)})

      value, _ctx ->
        type_error(:array, value)
    end
  end

  defp decoder(%IR.Dict{of: inner}) do
    inner_decoder = decoder(inner)

    fn
      value, ctx when is_map(value) ->
        entries(Enum.sort(Map.to_list(value)), inner_decoder, ctx, [], [])

      value, _ctx ->
        type_error(:object, value)
    end
  end

  defp decoder(%IR.Nullable{of: inner}) do
    inner_decoder = decoder(inner)

    fn
      nil, _ctx -> {:ok, nil}
      value, ctx -> inner_decoder.(value, ctx)
    end
  end

  defp decoder(%IR.Union{members: members}) do
    built = Enum.map(members, &decoder/1)
    tried = length(built)

    fn value, {_mode, defs} -> attempt(built, value, {:halt, defs}, tried) end
  end

  defp decoder(%IR.Tagged{} = tagged) do
    parts = decode_parts(tagged)

    fn
      value, ctx when is_map(value) -> tagged(value, parts, ctx)
      value, _ctx -> type_error(:object, value)
    end
  end

  defp decoder(%IR.Ref{name: name}) do
    fn value, {_mode, defs} = ctx -> Map.fetch!(defs, name).(value, ctx) end
  end

  # =============================================
  # Encoding
  # =============================================
  #
  # The mirror image, and the same shape: `(value, ctx)` in, `{:ok, wire}` or errors with a path
  # out. What it checks is types and formats -- the things it has to look at anyway to turn a
  # `DateTime` back into a string and an atom back into its wire value. Constraints are not
  # re-run: decode already bought that, and paying twice buys nothing.

  defp encoder(%IR.Scalar{kind: :string, format: nil}, _dd) do
    fn
      value, _ctx when is_binary(value) -> {:ok, value}
      value, _ctx -> type_error(:string, value)
    end
  end

  defp encoder(%IR.Scalar{kind: :string, format: format}, _dd) do
    fn value, _ctx ->
      case Format.encode(format, value) do
        {:ok, encoded} -> {:ok, encoded}
        :error -> leaf(:format, %{format: format})
      end
    end
  end

  defp encoder(%IR.Scalar{kind: :integer}, _dd) do
    fn
      value, _ctx when is_integer(value) -> {:ok, value}
      value, _ctx -> type_error(:integer, value)
    end
  end

  defp encoder(%IR.Scalar{kind: :float}, _dd) do
    fn
      value, _ctx when is_number(value) -> {:ok, value}
      value, _ctx -> type_error(:float, value)
    end
  end

  defp encoder(%IR.Scalar{kind: :boolean}, _dd) do
    fn
      value, _ctx when is_boolean(value) -> {:ok, value}
      value, _ctx -> type_error(:boolean, value)
    end
  end

  defp encoder(%IR.Scalar{kind: :null}, _dd) do
    fn
      nil, _ctx -> {:ok, nil}
      value, _ctx -> type_error(:null, value)
    end
  end

  defp encoder(%IR.Const{reverse: reverse, values: values}, _dd) do
    fn value, _ctx ->
      case Map.fetch(reverse, value) do
        {:ok, wire} -> {:ok, wire}
        :error -> leaf(:const, %{value: value, allowed: values})
      end
    end
  end

  defp encoder(%IR.Object{fields: fields, unknown: unknown, into: nil}, dd) do
    built = Enum.map(fields, fn field -> {field, encoder(field.ir, dd), :plain} end)
    known = IR.Field.claimed(fields)

    fn
      value, ctx when is_map(value) -> encode_object(value, built, unknown, known, ctx)
      value, _ctx -> type_error(:object, value)
    end
  end

  defp encoder(%IR.Object{fields: fields, unknown: unknown, into: module}, dd) do
    built =
      Enum.map(fields, fn field ->
        mode = field_mode(field, module)

        {field, encoder(written(field, mode), dd), mode}
      end)

    known = IR.Field.claimed(fields)

    fn
      value, ctx when is_struct(value, module) ->
        encode_object(value, built, unknown, known, ctx)

      value, _ctx ->
        leaf(:struct, %{expected: module, value: value})
    end
  end

  defp encoder(%IR.Array{of: inner}, dd) do
    inner_encoder = encoder(inner, dd)

    fn
      value, ctx when is_list(value) and length(value) >= 0 ->
        encode_elements(value, 0, inner_encoder, ctx, [], [])

      value, _ctx ->
        type_error(:array, value)
    end
  end

  defp encoder(%IR.Fixed{members: member_irs}, dd) do
    built = Enum.map(member_irs, &encoder(&1, dd))
    size = length(built)

    fn
      value, ctx when is_tuple(value) and tuple_size(value) == size ->
        encode_members(Tuple.to_list(value), built, 0, ctx, [], [])

      value, _ctx when is_tuple(value) ->
        leaf(:tuple_size, %{expected: size, actual: tuple_size(value)})

      value, _ctx ->
        type_error(:tuple, value)
    end
  end

  defp encoder(%IR.Dict{of: inner}, dd) do
    inner_encoder = encoder(inner, dd)

    fn
      value, ctx when is_map(value) ->
        encode_entries(Enum.sort(Map.to_list(value)), inner_encoder, ctx, [], [])

      value, _ctx ->
        type_error(:object, value)
    end
  end

  defp encoder(%IR.Nullable{of: inner}, dd) do
    inner_encoder = encoder(inner, dd)

    fn
      nil, _ctx -> {:ok, nil}
      value, ctx -> inner_encoder.(value, ctx)
    end
  end

  # An untagged union's members overlap on the wire, so "the first encoder that succeeds" can
  # write the wrong branch -- an encoder checks types and formats, not the constraints that told
  # the branches apart at decode. So each branch is tried in order and its output is decoded back
  # through the whole union; the first branch whose wire decodes to the value again is the one
  # whose choice round-trips. `verify` is the union's own decoder, run against `dd`, the decoders
  # of the symmetric program (`build_encoder/1`), so a ref inside a member resolves to a decoder
  # that reads the names the encoder wrote.
  defp encoder(%IR.Union{members: members} = union, dd) do
    encoders = Enum.map(members, &encoder(&1, dd))
    verify = decoder(IR.Rewrite.symmetric(union))
    tried = length(encoders)

    fn value, {_mode, edefs} -> union_encode(encoders, value, edefs, verify, dd, tried) end
  end

  defp encoder(%IR.Tagged{} = tagged, dd) do
    parts = encode_parts(tagged, dd)

    fn value, ctx -> encode_tagged(value, parts, ctx) end
  end

  defp encoder(%IR.Ref{name: name}, _dd) do
    fn value, {_mode, defs} = ctx -> Map.fetch!(defs, name).(value, ctx) end
  end

  defp union_encode([], value, _edefs, _verify, _dd, tried) do
    leaf(:no_variant, %{value: value, tried: tried})
  end

  defp union_encode([encode | rest], value, edefs, verify, dd, tried) do
    with {:ok, wire} <- encode.(value, {:halt, edefs}),
         {:ok, ^value} <- verify.(wire, {:halt, dd}) do
      {:ok, wire}
    else
      _other -> union_encode(rest, value, edefs, verify, dd, tried)
    end
  end

  defp encode_object(value, built, unknown, known, ctx) do
    with {:ok, acc} <- encode_fields(built, value, ctx, [], []) do
      {:ok, kept(acc, value, unknown, known)}
    end
  end

  defp encode_fields([], _value, _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
  defp encode_fields([], _value, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  # `Map.fetch!/2` rather than `Map.fetch/2` in the two struct clauses: they are only reached
  # for a value the object's own head already matched as a struct of the module the schema
  # names, and a struct has every key. So there is no absence to handle, only a value that
  # stands for one -- and a map wearing the right `__struct__` without the keys raises here
  # exactly as it does in the generated module.
  defp encode_fields([{field, encode, {:absent, absent}} | rest], value, ctx, acc, errors) do
    case Map.fetch!(value, field.key) do
      ^absent -> encode_fields(rest, value, ctx, acc, errors)
      found -> encoded(encode.(found, ctx), field, rest, value, ctx, acc, errors)
    end
  end

  defp encode_fields([{field, encode, :struct} | rest], value, ctx, acc, errors) do
    found = Map.fetch!(value, field.key)

    encoded(encode.(found, ctx), field, rest, value, ctx, acc, errors)
  end

  defp encode_fields([{field, encode, :plain} | rest], value, ctx, acc, errors) do
    case Map.fetch(value, field.key) do
      {:ok, found} -> encoded(encode.(found, ctx), field, rest, value, ctx, acc, errors)
      :error -> unset(field, rest, value, ctx, acc, errors)
    end
  end

  defp encoded({:ok, wire}, field, rest, value, ctx, acc, errors) do
    encode_fields(rest, value, ctx, [{field.to, wire} | acc], errors)
  end

  defp encoded({:error, found}, field, rest, value, {mode, _defs} = ctx, acc, errors) do
    errors = Enum.reduce(prefix(found, field.key), errors, &[&1 | &2])

    if mode == :halt,
      do: {:error, Enum.reverse(errors)},
      else: encode_fields(rest, value, ctx, acc, errors)
  end

  defp unset(%IR.Field{presence: :optional}, rest, value, ctx, acc, errors) do
    encode_fields(rest, value, ctx, acc, errors)
  end

  defp unset(field, rest, value, {mode, _defs} = ctx, acc, errors) do
    errors = [Error.new([field.key], :required, %{}) | errors]

    if mode == :halt,
      do: {:error, Enum.reverse(errors)},
      else: encode_fields(rest, value, ctx, acc, errors)
  end

  # `unknown: :keep` put the wire's extra keys in the decoded map, so encoding puts them back.
  defp kept(acc, value, :keep, known), do: Map.merge(acc, Map.new(IR.Field.extras(value, known)))

  defp kept(acc, _value, _policy, _known), do: acc

  defp encode_elements([], _index, _encode, _ctx, acc, []), do: {:ok, Enum.reverse(acc)}

  defp encode_elements([], _index, _encode, _ctx, _acc, errors),
    do: {:error, Enum.reverse(errors)}

  defp encode_elements([item | rest], index, encode, {mode, _defs} = ctx, acc, errors) do
    case encode.(item, ctx) do
      {:ok, wire} ->
        encode_elements(rest, index + 1, encode, ctx, [wire | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: encode_elements(rest, index + 1, encode, ctx, acc, errors)
    end
  end

  defp encode_members([], [], _index, _ctx, acc, []), do: {:ok, Enum.reverse(acc)}
  defp encode_members([], [], _index, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp encode_members([item | rest], [encode | rest_encoders], index, ctx, acc, errors) do
    {mode, _defs} = ctx

    case encode.(item, ctx) do
      {:ok, wire} ->
        encode_members(rest, rest_encoders, index + 1, ctx, [wire | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: encode_members(rest, rest_encoders, index + 1, ctx, acc, errors)
    end
  end

  defp encode_entries([], _encode, _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
  defp encode_entries([], _encode, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp encode_entries([{key, item} | rest], encode, {mode, _defs} = ctx, acc, errors) do
    case encode.(item, ctx) do
      {:ok, wire} ->
        encode_entries(rest, encode, ctx, [{key, wire} | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, key), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: encode_entries(rest, encode, ctx, acc, errors)
    end
  end

  # =============================================
  # JSON
  # =============================================
  #
  # The encoder again, with iodata where the wire term was. Everything the schema already knows
  # is rendered to a binary here, while the tree is being built: a field's `"key":`, an enum's
  # wire value, a tagged branch's whole `,"type":"circle"`. What is left at run time is escaping
  # the strings the value carries, and consing.
  #
  # An object and an array are both accumulated in reverse with a comma on every entry, and
  # `Rupa.Json.object/1` and `array/1` drop the first one when they close the bracket -- so a
  # field costs one cons rather than a test for whether it is the first.

  defp json(%IR.Scalar{kind: :string, format: nil}, _dd) do
    fn
      value, _ctx when is_binary(value) -> Json.encode_string(value)
      value, _ctx -> type_error(:string, value)
    end
  end

  defp json(%IR.Scalar{kind: :string, format: format}, _dd) do
    fn value, _ctx ->
      case Format.encode(format, value) do
        {:ok, encoded} -> Json.encode_string(encoded)
        :error -> leaf(:format, %{format: format})
      end
    end
  end

  defp json(%IR.Scalar{kind: :integer}, _dd) do
    fn
      value, _ctx when is_integer(value) -> {:ok, :json.encode_integer(value)}
      value, _ctx -> type_error(:integer, value)
    end
  end

  # `encode/3` accepts any number where the schema says float, and `:json.encode/1` would then
  # emit an integer. Emitting one here too is what keeps the two routes byte-identical.
  defp json(%IR.Scalar{kind: :float}, _dd) do
    fn
      value, _ctx when is_float(value) -> {:ok, :json.encode_float(value)}
      value, _ctx when is_integer(value) -> {:ok, :json.encode_integer(value)}
      value, _ctx -> type_error(:float, value)
    end
  end

  defp json(%IR.Scalar{kind: :boolean}, _dd) do
    fn
      true, _ctx -> {:ok, "true"}
      false, _ctx -> {:ok, "false"}
      value, _ctx -> type_error(:boolean, value)
    end
  end

  defp json(%IR.Scalar{kind: :null}, _dd) do
    fn
      nil, _ctx -> {:ok, "null"}
      value, _ctx -> type_error(:null, value)
    end
  end

  defp json(%IR.Const{reverse: reverse, values: values}, _dd) do
    rendered = Map.new(reverse, fn {decoded, wire} -> {decoded, Json.literal(wire)} end)

    fn value, _ctx ->
      case Map.fetch(rendered, value) do
        {:ok, wire} -> {:ok, wire}
        :error -> leaf(:const, %{value: value, allowed: values})
      end
    end
  end

  defp json(%IR.Object{into: nil} = object, dd) do
    body = json_body(object, dd)

    fn
      value, ctx when is_map(value) -> Json.wrap(body.(value, ctx, []))
      value, _ctx -> type_error(:object, value)
    end
  end

  defp json(%IR.Object{into: module} = object, dd) do
    body = json_body(object, dd)

    fn
      value, ctx when is_struct(value, module) -> Json.wrap(body.(value, ctx, []))
      value, _ctx -> leaf(:struct, %{expected: module, value: value})
    end
  end

  defp json(%IR.Array{of: inner}, dd) do
    emit = json(inner, dd)

    fn
      value, ctx when is_list(value) and length(value) >= 0 ->
        json_items(value, 0, emit, ctx, [], [])

      value, _ctx ->
        type_error(:array, value)
    end
  end

  defp json(%IR.Fixed{members: member_irs}, dd) do
    built = Enum.map(member_irs, &json(&1, dd))
    size = length(built)

    fn
      value, ctx when is_tuple(value) and tuple_size(value) == size ->
        json_members(Tuple.to_list(value), built, 0, ctx, [], [])

      value, _ctx when is_tuple(value) ->
        leaf(:tuple_size, %{expected: size, actual: tuple_size(value)})

      value, _ctx ->
        type_error(:tuple, value)
    end
  end

  defp json(%IR.Dict{of: inner}, dd) do
    emit = json(inner, dd)

    fn
      value, ctx when is_map(value) ->
        json_entries(Enum.sort(Map.to_list(value)), emit, ctx, [], [], %{})

      value, _ctx ->
        type_error(:object, value)
    end
  end

  defp json(%IR.Nullable{of: inner}, dd) do
    emit = json(inner, dd)

    fn
      nil, _ctx -> {:ok, "null"}
      value, ctx -> emit.(value, ctx)
    end
  end

  # Same branch problem as the term encoder, same fix: emit each branch in order and decode the
  # bytes back through the whole union; the first branch whose JSON decodes to the value again is
  # the one that round-trips. `verify` is the union's decoder, run against the symmetric program's
  # decoders, as in `encoder/2`.
  defp json(%IR.Union{members: members} = union, dd) do
    emitters = Enum.map(members, &json(&1, dd))
    verify = decoder(IR.Rewrite.symmetric(union))
    tried = length(emitters)

    fn value, {_mode, jdefs} -> json_union(emitters, value, jdefs, verify, dd, tried) end
  end

  defp json(%IR.Tagged{} = tagged, dd) do
    parts = json_parts(tagged, dd)

    fn value, ctx -> json_tagged(value, parts, ctx) end
  end

  defp json(%IR.Ref{name: name}, _dd) do
    fn value, {_mode, defs} = ctx -> Map.fetch!(defs, name).(value, ctx) end
  end

  defp json_union([], value, _jdefs, _verify, _dd, tried) do
    leaf(:no_variant, %{value: value, tried: tried})
  end

  defp json_union([emit | rest], value, jdefs, verify, dd, tried) do
    with {:ok, iodata} <- emit.(value, {:halt, jdefs}),
         {:ok, parsed} <- Json.parse(IO.iodata_to_binary(iodata)),
         {:ok, ^value} <- verify.(parsed, {:halt, dd}) do
      {:ok, iodata}
    else
      _other -> json_union(rest, value, jdefs, verify, dd, tried)
    end
  end

  # The field chain on its own, so an internally tagged branch can start it with the tag already
  # in the accumulator instead of building the object and then copying the tag into it.
  defp json_body(%IR.Object{fields: fields, unknown: unknown, into: into}, dd) do
    built =
      Enum.map(fields, fn field ->
        mode = field_mode(field, into)

        {field, Json.key(field.to), json(written(field, mode), dd), mode}
      end)

    claims = {IR.Field.claimed(fields), MapSet.new(fields, & &1.to)}

    fn value, {mode, _defs} = ctx, acc ->
      with {:ok, acc} <- json_fields(built, value, ctx, acc, []) do
        Json.extra(unknown, value, claims, acc, mode)
      end
    end
  end

  defp json_seeded(%IR.Object{into: nil} = object, dd) do
    body = json_body(object, dd)

    fn
      value, ctx, acc when is_map(value) -> Json.wrap(body.(value, ctx, acc))
      value, _ctx, _acc -> type_error(:object, value)
    end
  end

  defp json_seeded(%IR.Object{into: module} = object, dd) do
    body = json_body(object, dd)

    fn
      value, ctx, acc when is_struct(value, module) -> Json.wrap(body.(value, ctx, acc))
      value, _ctx, _acc -> leaf(:struct, %{expected: module, value: value})
    end
  end

  defp json_fields([], _value, _ctx, acc, []), do: {:ok, acc}
  defp json_fields([], _value, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp json_fields([{field, key, emit, {:absent, absent}} | rest], value, ctx, acc, errors) do
    case Map.fetch!(value, field.key) do
      ^absent -> json_fields(rest, value, ctx, acc, errors)
      found -> json_put(emit.(found, ctx), {field.key, key}, rest, value, ctx, acc, errors)
    end
  end

  defp json_fields([{field, key, emit, :struct} | rest], value, ctx, acc, errors) do
    found = Map.fetch!(value, field.key)

    json_put(emit.(found, ctx), {field.key, key}, rest, value, ctx, acc, errors)
  end

  defp json_fields([{field, key, emit, :plain} | rest], value, ctx, acc, errors) do
    case Map.fetch(value, field.key) do
      {:ok, found} -> json_put(emit.(found, ctx), {field.key, key}, rest, value, ctx, acc, errors)
      :error -> json_unset(field, rest, value, ctx, acc, errors)
    end
  end

  defp json_put({:ok, wire}, {_name, key}, rest, value, ctx, acc, errors) do
    json_fields(rest, value, ctx, [[?,, key | wire] | acc], errors)
  end

  defp json_put({:error, found}, {name, _key}, rest, value, {mode, _defs} = ctx, acc, errors) do
    errors = Enum.reduce(prefix(found, name), errors, &[&1 | &2])

    if mode == :halt,
      do: {:error, Enum.reverse(errors)},
      else: json_fields(rest, value, ctx, acc, errors)
  end

  defp json_unset(%IR.Field{presence: :optional}, rest, value, ctx, acc, errors) do
    json_fields(rest, value, ctx, acc, errors)
  end

  defp json_unset(field, rest, value, {mode, _defs} = ctx, acc, errors) do
    errors = [Error.new([field.key], :required, %{}) | errors]

    if mode == :halt,
      do: {:error, Enum.reverse(errors)},
      else: json_fields(rest, value, ctx, acc, errors)
  end

  defp json_items([], _index, _emit, _ctx, acc, []), do: {:ok, Json.array(:lists.reverse(acc))}
  defp json_items([], _index, _emit, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp json_items([item | rest], index, emit, {mode, _defs} = ctx, acc, errors) do
    case emit.(item, ctx) do
      {:ok, wire} ->
        json_items(rest, index + 1, emit, ctx, [[?, | wire] | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: json_items(rest, index + 1, emit, ctx, acc, errors)
    end
  end

  defp json_members([], [], _index, _ctx, acc, []), do: {:ok, Json.array(:lists.reverse(acc))}
  defp json_members([], [], _index, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp json_members([item | rest], [emit | emitters], index, {mode, _defs} = ctx, acc, errors) do
    case emit.(item, ctx) do
      {:ok, wire} ->
        json_members(rest, emitters, index + 1, ctx, [[?, | wire] | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: json_members(rest, emitters, index + 1, ctx, acc, errors)
    end
  end

  # `seen` is the names written so far, for `Json.entry_key/2`'s duplicate check.
  defp json_entries([], _emit, _ctx, acc, [], _seen), do: {:ok, Json.object(:lists.reverse(acc))}
  defp json_entries([], _emit, _ctx, _acc, errors, _seen), do: {:error, Enum.reverse(errors)}

  defp json_entries([{key, item} | rest], emit, {mode, _defs} = ctx, acc, errors, seen) do
    with {:ok, wire} <- emit.(item, ctx),
         {:ok, wire_key, seen} <- Json.entry_key(key, seen) do
      json_entries(rest, emit, ctx, [[?,, wire_key, ?: | wire] | acc], errors, seen)
    else
      {:error, found} ->
        errors = Enum.reduce(prefix(found, key), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: json_entries(rest, emit, ctx, acc, errors, seen)
    end
  end

  # Internally tagged, the tag is the branch object's first entry, so the object is built once
  # with the tag already in it. Adjacently tagged, the two entries are both known shapes and the
  # branch can be any schema at all.
  defp json_parts(%IR.Tagged{content: nil} = tagged, dd) do
    table =
      Map.new(tagged.branches, fn branch ->
        {branch.tag, {Json.constant(tagged.tag_wire, branch.wire), json_seeded(branch.ir, dd)}}
      end)

    %{content: nil, content_key: nil, table: table, allowed: tags(tagged)}
  end

  defp json_parts(tagged, dd) do
    table =
      Map.new(tagged.branches, fn branch ->
        {branch.tag, {Json.constant(tagged.tag_wire, branch.wire), json(branch.ir, dd)}}
      end)

    %{
      content: tagged.content,
      content_key: Json.key(tagged.content_wire),
      table: table,
      allowed: tags(tagged)
    }
  end

  defp tags(%IR.Tagged{branches: branches}), do: Enum.map(branches, & &1.tag)

  defp json_tagged({tag, inner} = value, parts, ctx) when is_atom(tag) do
    json_branch(Map.fetch(parts.table, tag), value, inner, parts, ctx)
  end

  defp json_tagged(value, parts, _ctx) do
    leaf(:unknown_tag, %{value: value, allowed: parts.allowed})
  end

  defp json_branch(:error, value, _inner, parts, _ctx) do
    leaf(:unknown_tag, %{value: value, allowed: parts.allowed})
  end

  defp json_branch({:ok, {entry, seeded}}, _value, inner, %{content: nil}, ctx) do
    seeded.(inner, ctx, [entry])
  end

  defp json_branch({:ok, {entry, emit}}, _value, inner, parts, ctx) do
    json_content(emit.(inner, ctx), entry, parts)
  end

  defp json_content({:ok, wire}, entry, parts) do
    {:ok, Json.object([entry, [?,, parts.content_key | wire]])}
  end

  defp json_content({:error, errors}, _entry, parts), do: {:error, prefix(errors, parts.content)}

  # =============================================
  # Unions
  # =============================================
  #
  # A tagged union reads one key, looks the branch up once, and decodes it -- flat at any depth,
  # which is why it is the default. An untagged one has no key to read, so it tries the variants
  # in order and the first that takes the value wins; the order you wrote them in is part of the
  # schema.

  # Attempts run in `:halt` whatever the ambient mode. A variant that fails is one you will
  # never hear about, so collecting its errors costs a list per attempt and buys nothing, and a
  # variant that succeeds decodes to the same value either way.
  defp attempt([], value, _ctx, tried), do: leaf(:no_variant, %{value: value, tried: tried})

  defp attempt([run | rest], value, ctx, tried) do
    case run.(value, ctx) do
      {:ok, done} -> {:ok, done}
      {:error, _errors} -> attempt(rest, value, ctx, tried)
    end
  end

  # The tag's two names, the content's two, the branch table keyed by what the wire carries, and
  # the tags a message is allowed to list. Built once, per direction.
  defp decode_parts(%IR.Tagged{branches: branches} = tagged) do
    %{
      tag: tagged.tag,
      tag_wire: tagged.tag_wire,
      content: tagged.content,
      content_wire: tagged.content_wire,
      table: Map.new(branches, &{&1.wire, {&1.tag, decoder(&1.ir), &1.drop_tag}}),
      allowed: Enum.map(branches, & &1.wire)
    }
  end

  defp encode_parts(%IR.Tagged{branches: branches} = tagged, dd) do
    %{
      tag_wire: tagged.tag_wire,
      content: tagged.content,
      content_wire: tagged.content_wire,
      table: Map.new(branches, &{&1.tag, {&1.wire, encoder(&1.ir, dd)}}),
      allowed: Enum.map(branches, & &1.tag)
    }
  end

  defp tagged(value, parts, ctx) do
    case Map.fetch(value, parts.tag_wire) do
      {:ok, found} -> branch(Map.fetch(parts.table, found), found, value, parts, ctx)
      :error -> leaf_at(parts.tag, :required, %{})
    end
  end

  defp branch(:error, found, _value, parts, _ctx) do
    leaf_at(parts.tag, :unknown_tag, %{value: found, allowed: parts.allowed})
  end

  # Internally tagged: the branch's own fields are in the same map as the tag, so the branch
  # decodes that map. A branch that strips unknown keys ignores the tag for nothing; anything
  # else is handed the map without it, which is the only copy this path makes.
  defp branch({:ok, {tag, decode, drop?}}, _found, value, %{content: nil} = parts, ctx) do
    tagged_ok(decode.(without(value, parts.tag_wire, drop?), ctx), tag)
  end

  # Adjacently tagged: the branch's value is under its own key, so it can be any schema at all,
  # and its errors carry that key.
  defp branch({:ok, {tag, decode, _drop?}}, _found, value, parts, ctx) do
    case Map.fetch(value, parts.content_wire) do
      {:ok, inner} -> content_ok(decode.(inner, ctx), tag, parts.content)
      :error -> leaf_at(parts.content, :required, %{})
    end
  end

  defp tagged_ok({:ok, decoded}, tag), do: {:ok, {tag, decoded}}
  defp tagged_ok({:error, _errors} = error, _tag), do: error

  defp content_ok({:ok, decoded}, tag, _content), do: {:ok, {tag, decoded}}
  defp content_ok({:error, errors}, _tag, content), do: {:error, prefix(errors, content)}

  defp without(value, _tag_wire, false), do: value
  defp without(value, tag_wire, true), do: Map.delete(value, tag_wire)

  # Encoding takes the tuple decoding produced. Anything else -- a bare map, the wrong tag, a
  # three-element tuple -- is the same mistake and gets the same error: this is not one of the
  # branches.
  defp encode_tagged({tag, inner} = value, parts, ctx) when is_atom(tag) do
    encode_branch(Map.fetch(parts.table, tag), value, inner, parts, ctx)
  end

  defp encode_tagged(value, parts, _ctx) do
    leaf(:unknown_tag, %{value: value, allowed: parts.allowed})
  end

  defp encode_branch({:ok, {wire, encode}}, _value, inner, parts, ctx) do
    wired(encode.(inner, ctx), wire, parts)
  end

  defp encode_branch(:error, value, _inner, parts, _ctx) do
    leaf(:unknown_tag, %{value: value, allowed: parts.allowed})
  end

  defp wired({:error, errors}, _wire, %{content: nil}), do: {:error, errors}
  defp wired({:error, errors}, _wire, parts), do: {:error, prefix(errors, parts.content)}

  defp wired({:ok, encoded}, wire, %{content: nil} = parts) do
    {:ok, Map.put(encoded, parts.tag_wire, wire)}
  end

  defp wired({:ok, encoded}, wire, parts) do
    {:ok, %{parts.tag_wire => wire, parts.content_wire => encoded}}
  end

  # =============================================
  # Objects
  # =============================================

  defp object(value, built, unknown, known, ctx) do
    with {:ok, acc} <- fields(built, value, ctx, [], []) do
      unknown(acc, value, unknown, known, ctx)
    end
  end

  # An absent optional field left no entry, and a struct has every key regardless -- so what it
  # gets is the module's own `defstruct` default. Merging onto a base built once, when the codec
  # was, is what keeps that from costing a lookup per field. It is a separate function from the
  # one above rather than a `base` that may be `nil`, because the ordinary path should not pay a
  # tuple to unwrap and rebuild for a merge it is never going to do.
  defp object_into(value, built, unknown, known, base, ctx) do
    with {:ok, acc} <- fields(built, value, ctx, [], []),
         {:ok, decoded} <- unknown(acc, value, unknown, known, ctx) do
      {:ok, :maps.merge(base, decoded)}
    end
  end

  # Inside a struct there is no absent, so encoding has to recognise it: what decoding leaves
  # behind for a key that was not on the wire is the module's own `defstruct` default, and
  # writing that value back as absent is the only reading under which
  # `decode(encode(decode(w))) == decode(w)` still closes. Only an optional field with no
  # `default:` of its own has such a value -- every other field is set by decode whatever the
  # wire said -- and for a struct `mix rupa.gen.struct` wrote, that value is `nil`. Reading it
  # off the module rather than assuming `nil` is what makes a hand-written struct with a
  # default of its own round-trip too.
  defp field_mode(_field, nil), do: :plain

  defp field_mode(%IR.Field{presence: :optional, default: :none, key: key}, module) do
    {:absent, Map.fetch!(module.__struct__(), key)}
  end

  defp field_mode(%IR.Field{}, _module), do: :struct

  # Which node actually does the writing. When the absent value is `nil`, an optional field's
  # `nullable` has nothing left to say on the way out: the `nil` it exists to pass through is
  # the one the clause below already writes as absent. Decoding still needs it -- a wire `null`
  # has to be allowed in -- which is why this is an encoder's reading of the field rather than
  # something staging could settle. A non-`nil` absent value leaves the wrapper in place,
  # because then `nil` is a value like any other and does go out as `null`.
  defp written(%IR.Field{ir: %IR.Nullable{of: inner}}, {:absent, nil}), do: inner
  defp written(%IR.Field{ir: ir}, _mode), do: ir

  defp fields([], _value, _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
  defp fields([], _value, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp fields([{field, decoder} | rest], value, ctx, acc, errors) do
    case one(field, decoder, value, ctx) do
      :absent -> fields(rest, value, ctx, acc, errors)
      {:ok, decoded} -> fields(rest, value, ctx, [{field.key, decoded} | acc], errors)
      {:error, found} -> gather(found, field.key, rest, value, ctx, acc, errors)
    end
  end

  defp gather(found, segment, rest, value, {mode, _defs} = ctx, acc, errors) do
    errors = Enum.reduce(prefix(found, segment), errors, &[&1 | &2])

    if mode == :halt do
      {:error, Enum.reverse(errors)}
    else
      fields(rest, value, ctx, acc, errors)
    end
  end

  defp one(field, decoder, value, ctx) do
    case Map.fetch(value, field.from) do
      {:ok, found} -> decoder.(found, ctx)
      :error -> missing(field)
    end
  end

  defp missing(%IR.Field{default: {:value, default}}), do: {:ok, default}
  defp missing(%IR.Field{presence: :optional}), do: :absent
  defp missing(%IR.Field{}), do: leaf(:required, %{})

  # `unknown: :error` measures incoming keys against the ones fields read (`from`), so a decoded
  # key or a `to` cannot pass for one. `:keep` merges by all three claimed names, so a passthrough
  # extra never shadows a field; `:strip` never looks at the set.
  defp known_keys(fields, :error), do: IR.Field.inputs(fields)
  defp known_keys(fields, _policy), do: IR.Field.claimed(fields)

  defp unknown(acc, _value, :strip, _known, _ctx), do: {:ok, acc}

  defp unknown(acc, value, :keep, known, _ctx) do
    {:ok, Map.merge(acc, Map.new(IR.Field.extras(value, known)))}
  end

  defp unknown(acc, value, :error, known, {mode, _defs}) do
    extra = value |> IR.Field.extras(known) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    case {extra, mode} do
      {[], _mode} -> {:ok, acc}
      {[first | _rest], :halt} -> leaf(:unknown_key, %{key: first})
      {keys, :collect} -> {:error, Enum.map(keys, &Error.new([], :unknown_key, %{key: &1}))}
    end
  end

  # =============================================
  # Lists, tuples and maps
  # =============================================

  defp elements([], _index, _decoder, _ctx, acc, []), do: {:ok, Enum.reverse(acc)}
  defp elements([], _index, _decoder, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp elements([item | rest], index, decoder, {mode, _defs} = ctx, acc, errors) do
    case decoder.(item, ctx) do
      {:ok, decoded} ->
        elements(rest, index + 1, decoder, ctx, [decoded | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: elements(rest, index + 1, decoder, ctx, acc, errors)
    end
  end

  defp members([], [], _index, _ctx, acc, []), do: {:ok, acc |> Enum.reverse() |> List.to_tuple()}
  defp members([], [], _index, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp members([item | rest], [decoder | decoders], index, {mode, _defs} = ctx, acc, errors) do
    case decoder.(item, ctx) do
      {:ok, decoded} ->
        members(rest, decoders, index + 1, ctx, [decoded | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, index), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: members(rest, decoders, index + 1, ctx, acc, errors)
    end
  end

  defp entries([], _decoder, _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
  defp entries([], _decoder, _ctx, _acc, errors), do: {:error, Enum.reverse(errors)}

  defp entries([{key, item} | rest], decoder, {mode, _defs} = ctx, acc, errors) do
    case decoder.(item, ctx) do
      {:ok, decoded} ->
        entries(rest, decoder, ctx, [{key, decoded} | acc], errors)

      {:error, found} ->
        errors = Enum.reduce(prefix(found, key), errors, &[&1 | &2])

        if mode == :halt,
          do: {:error, Enum.reverse(errors)},
          else: entries(rest, decoder, ctx, acc, errors)
    end
  end

  # =============================================
  # Checks
  # =============================================

  defp run(value, [], nil), do: {:ok, value}
  defp run(value, [], convert), do: convert.(value)

  defp run(value, [check | rest], convert) do
    case check.(value) do
      :ok -> run(value, rest, convert)
      {:error, _errors} = error -> error
    end
  end

  # `String.length/1` walks grapheme clusters and allocates while it does. Byte size bounds it
  # from above -- a UTF-8 binary never holds more graphemes than bytes -- which settles most
  # comparisons for nothing, and settles `min: 1` outright, which is the constraint people
  # actually write.

  defp string_check({:min, 0}), do: fn _value -> :ok end

  defp string_check({:min, 1}) do
    fn value -> if value != "", do: :ok, else: short(1) end
  end

  defp string_check({:min, min}) do
    fn value ->
      if byte_size(value) >= min and String.length(value) >= min, do: :ok, else: short(min)
    end
  end

  defp string_check({:max, max}) do
    fn value ->
      if byte_size(value) <= max or String.length(value) <= max do
        :ok
      else
        leaf(:max, %{max: max, unit: "characters"})
      end
    end
  end

  defp string_check({:len, len}) do
    fn value ->
      if byte_size(value) >= len and String.length(value) == len,
        do: :ok,
        else: leaf(:len, %{len: len})
    end
  end

  defp string_check({:pattern, source}) do
    regex = Regex.compile!(source)

    fn value ->
      if Regex.match?(regex, value), do: :ok, else: leaf(:pattern, %{pattern: source})
    end
  end

  defp short(min), do: leaf(:min, %{min: min, unit: "characters"})

  defp number_check({:gte, bound}) do
    fn value -> if value >= bound, do: :ok, else: leaf(:gte, %{gte: bound}) end
  end

  defp number_check({:gt, bound}) do
    fn value -> if value > bound, do: :ok, else: leaf(:gt, %{gt: bound}) end
  end

  defp number_check({:lte, bound}) do
    fn value -> if value <= bound, do: :ok, else: leaf(:lte, %{lte: bound}) end
  end

  defp number_check({:lt, bound}) do
    fn value -> if value < bound, do: :ok, else: leaf(:lt, %{lt: bound}) end
  end

  defp number_check({:multiple_of, step}) do
    fn value ->
      if Rupa.Number.multiple?(value, step),
        do: :ok,
        else: leaf(:multiple_of, %{multiple_of: step})
    end
  end

  defp array_check({:min, min}) do
    fn value -> if length(value) >= min, do: :ok, else: leaf(:min, %{min: min, unit: "items"}) end
  end

  defp array_check({:max, max}) do
    fn value -> if length(value) <= max, do: :ok, else: leaf(:max, %{max: max, unit: "items"}) end
  end

  defp unique?(value), do: length(Enum.uniq(value)) == length(value)

  defp format_convert(nil), do: nil

  defp format_convert(format) do
    fn value ->
      case Format.decode(format, value) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> leaf(:format, %{format: format})
      end
    end
  end

  defp prefix(errors, segment) do
    Enum.map(errors, fn error -> %{error | path: [segment | error.path]} end)
  end

  defp leaf(code, meta), do: {:error, [Error.new([], code, meta)]}

  defp leaf_at(segment, code, meta), do: {:error, [Error.new([segment], code, meta)]}

  defp type_error(expected, value), do: leaf(:type, %{expected: expected, value: value})
end

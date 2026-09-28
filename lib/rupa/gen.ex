if Code.ensure_loaded?(StreamData) do
  defmodule Rupa.Gen do
    @moduledoc """
    StreamData generators built from a schema, for the round-trip property.

    Add `stream_data` to your own deps to use this — Rupa lists it as optional, so it is not
    forced on anyone who only wants to decode.

        property "encode and decode are inverses" do
          codec = Rupa.compile!(MyApp.Schemas.user())

          check all value <- Rupa.Gen.stream(codec) do
            assert {:ok, wire} = Rupa.encode(codec, value)
            assert {:ok, ^value} = Rupa.decode(codec, wire)
          end
        end

    What it generates is **decoded** values — what `Rupa.decode/3` returns and `Rupa.encode/3`
    takes — because that is the side the property is stated on. A field carrying `default:`
    is always generated, even though it is optional on the wire: leave it out and decoding
    fills it in, and the value that comes back is not the one you started with.

    ## What it refuses

    A generator that quietly skips half your schema is worse than one that will not start, so
    these raise with the path rather than being ignored:

      * `pattern:` — generating a string from a PCRE is a project of its own
      * `multiple_of:` on a float, or one that is not a whole number on an integer — the
        multiples of `0.1` are not representable, so the values it produced would fail the
        check they were generated to satisfy
      * a bound that nothing satisfies, such as `T.integer(gt: 1, lt: 2)` or a float interval
        with no double in it
      * a recursion with no case that stops, such as `%{child: T.ref(:root)}`, which has no
        finite value at all

    ## Untagged unions

    An untagged union generates from one of its variants at random, which round-trips only if
    the variants are disjoint — if two of them accept the same value, decoding picks the first
    and the property will tell you so. That is the cost `tag: :none` makes you opt into, and
    `Rupa.T.tagged/3` is the version with nothing to be ambiguous about.
    """

    alias Rupa.Codec
    alias Rupa.IR
    alias Rupa.Stage

    @doc """
    A generator of decoded values for a codec, a generated module, or a schema.

        iex> [value] = %{n: Rupa.T.integer(gte: 1, lte: 3)} |> Rupa.Gen.stream() |> Enum.take(1)
        iex> value.n in 1..3
        true
    """
    @spec stream(term()) :: StreamData.t(term())
    def stream(%Codec{program: program}), do: program(program)

    def stream(module) when is_atom(module) do
      if Code.ensure_loaded?(module) and function_exported?(module, :__rupa__, 1) do
        program(module.__rupa__(:program))
      else
        from_schema(module)
      end
    end

    def stream(schema), do: from_schema(schema)

    defp from_schema(schema) do
      case Stage.run(schema) do
        {:ok, program} -> program(program)
        {:error, errors} -> raise Rupa.SchemaError, errors: errors
      end
    end

    defp program(%{root: root, defs: defs}) do
      terminating!(defs)

      build(root, %{defs: defs, path: []})
    end

    # =============================================
    # Recursion
    # =============================================
    #
    # A recursive value terminates because something on the way back to the ref can be empty: a
    # list with no `min:`, a nullable, a map, or an optional field. If every path back is
    # through something that must be there, no finite value exists and generating one would
    # hang, so this is a build-time error rather than a test that never returns.

    defp terminating!(defs) do
      finite = fixpoint(defs, MapSet.new())

      case Enum.find(Map.keys(defs), &(not MapSet.member?(finite, &1))) do
        nil ->
          :ok

        name ->
          raise ArgumentError, """
          cannot generate values for this schema: the recursion at #{inspect(name)} has no case \
          that stops. Every path back to it is through a value that must be there, so no finite \
          value satisfies the schema. Put the recursion under a list, a nullable, or an \
          optional field.\
          """
      end
    end

    # Least fixpoint: start with nothing known to be finite and keep adding definitions whose
    # mandatory paths all bottom out in something already known, until a pass adds nothing. What
    # is left over is what has no finite value.
    defp fixpoint(defs, finite) do
      grown =
        Enum.reduce(defs, finite, fn {name, ir}, acc ->
          if finite?(ir, acc), do: MapSet.put(acc, name), else: acc
        end)

      if MapSet.size(grown) == MapSet.size(finite), do: grown, else: fixpoint(defs, grown)
    end

    defp finite?(%IR.Ref{name: name}, finite), do: MapSet.member?(finite, name)

    defp finite?(%IR.Object{fields: fields}, finite) do
      Enum.all?(fields, fn field -> not always?(field) or finite?(field.ir, finite) end)
    end

    defp finite?(%IR.Array{of: inner, checks: checks}, finite) do
      Keyword.get(checks, :min, 0) == 0 or finite?(inner, finite)
    end

    defp finite?(%IR.Fixed{members: members}, finite) do
      Enum.all?(members, &finite?(&1, finite))
    end

    # A union needs only one variant that stops, and a tagged union only one branch.
    defp finite?(%IR.Union{members: members}, finite) do
      Enum.any?(members, &finite?(&1, finite))
    end

    defp finite?(%IR.Tagged{branches: branches}, finite) do
      Enum.any?(branches, &finite?(&1.ir, finite))
    end

    defp finite?(_stops, _finite), do: true

    # A field carrying a default is always generated: leaving it out would make decoding fill
    # it in, and the round trip would come back with a value the generator never produced.
    defp always?(%IR.Field{presence: :required}), do: true
    defp always?(%IR.Field{default: {:value, _default}}), do: true
    defp always?(%IR.Field{}), do: false

    # =============================================
    # Nodes
    # =============================================

    defp build(%IR.Scalar{kind: :string} = scalar, context), do: string(scalar, context)
    defp build(%IR.Scalar{kind: :boolean}, _context), do: StreamData.boolean()
    defp build(%IR.Scalar{kind: :null}, _context), do: StreamData.constant(nil)

    defp build(%IR.Scalar{kind: :integer, checks: checks}, context) do
      whole(bounds(checks), Keyword.get(checks, :multiple_of, 1), context)
    end

    defp build(%IR.Scalar{kind: :float, checks: checks}, context) do
      if Keyword.has_key?(checks, :multiple_of), do: refuse!(context, "multiple_of: on a float")

      real(bounds(checks), context)
    end

    defp build(%IR.Const{values: values}, _context), do: StreamData.member_of(values)

    defp build(%IR.Nullable{of: inner}, context) do
      StreamData.one_of([StreamData.constant(nil), build(inner, context)])
    end

    defp build(%IR.Array{of: inner, checks: checks}, context) do
      inner_data = build(inner, at(context, :of))
      opts = length_opts(checks)

      if Keyword.get(checks, :unique, false) do
        StreamData.uniq_list_of(inner_data, opts)
      else
        StreamData.list_of(inner_data, opts)
      end
    end

    defp build(%IR.Fixed{members: members}, context) do
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} -> build(member, at(context, index)) end)
      |> StreamData.fixed_list()
      |> StreamData.map(&List.to_tuple/1)
    end

    defp build(%IR.Dict{of: inner}, context) do
      StreamData.map_of(
        StreamData.string(:alphanumeric, min_length: 1),
        build(inner, at(context, :of))
      )
    end

    defp build(%IR.Union{members: members}, context) do
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} -> build(member, at(context, index)) end)
      |> StreamData.one_of()
    end

    defp build(%IR.Tagged{branches: branches}, context) do
      branches
      |> Enum.map(fn branch ->
        branch.ir
        |> build(at(context, branch.wire))
        |> StreamData.map(&{branch.tag, &1})
      end)
      |> StreamData.one_of()
    end

    defp build(%IR.Object{fields: fields, into: into}, context) do
      data = Map.new(fields, fn field -> {field.key, build(field.ir, at(context, field.key))} end)

      maps =
        case Enum.reject(fields, &always?/1) do
          [] -> StreamData.fixed_map(data)
          optional -> StreamData.optional_map(data, Enum.map(optional, & &1.key))
        end

      structs(maps, into)
    end

    # Deferred, so the recursion is built as it is used rather than as it is defined. Each level
    # halves the size, which is what makes the lists above run out and the value finite.
    defp build(%IR.Ref{name: name}, context) do
      StreamData.sized(fn size ->
        StreamData.resize(build(Map.fetch!(context.defs, name), context), div(size, 2))
      end)
    end

    # `optional_map/2` still leaves keys out, which is what the round trip needs to exercise --
    # the struct is where they come back as the module's own default, so the property compares
    # two values that have already agreed absent and nil are one thing.
    defp structs(maps, nil), do: maps

    defp structs(maps, module) do
      base = module.__struct__()

      StreamData.map(maps, &:maps.merge(base, &1))
    end

    # =============================================
    # Strings
    # =============================================

    defp string(%IR.Scalar{checks: checks, format: format}, context) do
      if Keyword.has_key?(checks, :pattern), do: refuse!(context, "pattern:")

      case format do
        nil ->
          plain(checks)

        _named ->
          # A format's generator produces values of that format and cannot also honour a length --
          # an `email` generator has no way to reach 30 characters on demand -- so a `min:`/`max:`/
          # `len:` beside a format is refused rather than silently ignored, the same as `pattern:`.
          if Enum.any?([:min, :max, :len], &Keyword.has_key?(checks, &1)),
            do: refuse!(context, "a length constraint on a formatted string"),
            else: formatted(format)
      end
    end

    # Alphanumeric whenever a length matters: one grapheme per byte, so what the generator
    # counts and what `String.length/1` counts are the same number.
    defp plain(checks) do
      case length_opts(checks) do
        [] -> StreamData.string(:printable)
        opts -> StreamData.string(:alphanumeric, opts)
      end
    end

    defp length_opts(checks) do
      Enum.flat_map(checks, fn
        {:len, len} -> [length: len]
        {:min, min} -> [min_length: min]
        {:max, max} -> [max_length: max]
        _other -> []
      end)
    end

    # =============================================
    # Numbers
    # =============================================

    defp bounds(checks) do
      lower =
        cond do
          Keyword.has_key?(checks, :gte) -> {:closed, Keyword.fetch!(checks, :gte)}
          Keyword.has_key?(checks, :gt) -> {:open, Keyword.fetch!(checks, :gt)}
          true -> :none
        end

      upper =
        cond do
          Keyword.has_key?(checks, :lte) -> {:closed, Keyword.fetch!(checks, :lte)}
          Keyword.has_key?(checks, :lt) -> {:open, Keyword.fetch!(checks, :lt)}
          true -> :none
        end

      {lower, upper}
    end

    # The value is `index * step`, so each bound on the value becomes a bound on the index and
    # one piece of arithmetic covers the plain case (`step` is 1) and `multiple_of:` together.
    # Doing it the other way round — generate, then round to a multiple — is what puts a value
    # outside its own range when the range is negative.
    defp whole(range, step, context) do
      if is_float(step), do: refuse!(context, "a multiple_of: that is not a whole number")

      {low, high} = index_range(range, step)

      if is_integer(low) and is_integer(high) and low > high, do: refuse!(context, empty(step))

      low |> indices(high) |> scale(step)
    end

    defp empty(1), do: "a range with no integer in it"
    defp empty(step), do: "a range with no multiple of #{step} in it"

    defp index_range({lower, upper}, step), do: {low_index(lower, step), high_index(upper, step)}

    defp low_index(:none, _step), do: :none
    defp low_index({:closed, bound}, step), do: ceil_div(ceil(bound), step)
    defp low_index({:open, bound}, step), do: ceil_div(floor(bound) + 1, step)

    defp high_index(:none, _step), do: :none
    defp high_index({:closed, bound}, step), do: Integer.floor_div(floor(bound), step)
    defp high_index({:open, bound}, step), do: Integer.floor_div(ceil(bound) - 1, step)

    # `multiple_of:` is validated positive, so flooring the negated value rounds the other way.
    defp ceil_div(value, step), do: -Integer.floor_div(-value, step)

    defp indices(:none, :none), do: StreamData.integer()
    defp indices(low, :none), do: StreamData.map(StreamData.positive_integer(), &(&1 - 1 + low))
    defp indices(:none, high), do: StreamData.map(StreamData.positive_integer(), &(high - &1 + 1))
    defp indices(low, high), do: StreamData.integer(low..high)

    defp scale(data, 1), do: data
    defp scale(data, step), do: StreamData.map(data, &(&1 * step))

    # StreamData's float bounds are inclusive floats, and an integer bound rounds to the nearest
    # float on the way in -- which past 2^53 can land outside the interval it came from, so the
    # generator would hand out a value the codec rejects. Each bound is moved to the nearest float
    # *inside* the interval instead: for a closed bound the smallest float no less than it (or the
    # largest no greater), for an open one the float just past it. An interval with no float in it
    # is refused, like an integer range with no integer in it, rather than left to StreamData to
    # give up on. StreamData's own arithmetic can still round a value just over an exact bound at
    # that magnitude, so the bounds are also filtered -- which almost nothing fails, since they now
    # sit inside the interval.
    defp real({lower, upper}, context) do
      low = inward(lower, :up, context)
      high = inward(upper, :down, context)

      cond do
        is_float(low) and is_float(high) and low > high ->
          refuse!(context, "a range with no float in it")

        is_float(low) and low == high ->
          StreamData.constant(low)

        true ->
          (float_opts(:min, low) ++ float_opts(:max, high))
          |> StreamData.float()
          |> StreamData.filter(&within?(&1, low, high))
      end
    end

    defp float_opts(_key, :none), do: []
    defp float_opts(key, bound), do: [{key, bound}]

    defp within?(value, low, high) do
      (low == :none or value >= low) and (high == :none or value <= high)
    end

    defp inward(:none, _direction, _context), do: :none

    defp inward({:closed, bound}, direction, context) do
      nearest = bound * 1.0

      cond do
        direction == :up and below?(nearest, bound) -> step(nearest, :up, context)
        direction == :down and above?(nearest, bound) -> step(nearest, :down, context)
        true -> nearest
      end
    end

    defp inward({:open, bound}, direction, context) do
      case inward({:closed, bound}, direction, context) do
        nearest when is_float(bound) or (is_integer(bound) and trunc(nearest) == bound) ->
          step(nearest, direction, context)

        past ->
          past
      end
    end

    # `bound * 1.0` is exact below 2^53 and integral above it, so `trunc/1` compares exactly.
    defp below?(nearest, bound) when is_integer(bound), do: trunc(nearest) < bound
    defp below?(_nearest, _bound), do: false
    defp above?(nearest, bound) when is_integer(bound), do: trunc(nearest) > bound
    defp above?(_nearest, _bound), do: false

    # The adjacent double, by its bit pattern. Past the largest finite double there is none, and a
    # bound out there leaves no float on its side of the interval.
    @largest 1.7976931348623157e308

    defp step(float, :up, context) when float >= @largest,
      do: refuse!(context, "a range with no float in it")

    defp step(float, :down, context) when float <= -@largest,
      do: refuse!(context, "a range with no float in it")

    defp step(float, :up, _context) when float == 0.0, do: 5.0e-324
    defp step(float, :down, _context) when float == 0.0, do: -5.0e-324

    defp step(float, direction, _context) do
      <<bits::64>> = <<float::float>>
      # Toward +infinity is +1 on a positive pattern and -1 on a negative one, and the reverse.
      delta = if float > 0.0 == (direction == :up), do: 1, else: -1
      <<adjacent::float>> = <<bits + delta::64>>
      adjacent
    end

    # =============================================
    # Formats
    # =============================================

    @seconds 4_102_444_800

    defp formatted(:date_time) do
      StreamData.map(StreamData.integer(0..@seconds), &DateTime.from_unix!/1)
    end

    defp formatted(:date) do
      StreamData.map(StreamData.integer(0..@seconds), fn seconds ->
        seconds |> DateTime.from_unix!() |> DateTime.to_date()
      end)
    end

    defp formatted(:time) do
      StreamData.map(StreamData.integer(0..86_399), &Time.from_seconds_after_midnight/1)
    end

    # RFC 3339 has no fraction of a second and no week beside another unit, so a duration is
    # either weeks alone or whole units without them.
    defp formatted(:duration) do
      weeks = StreamData.map(StreamData.integer(1..52), &Duration.new!(week: &1))
      bounds = [0..5, 0..11, 0..27, 0..23, 0..59, 0..59]
      units = StreamData.fixed_list(Enum.map(bounds, &StreamData.integer/1))

      StreamData.frequency([{1, weeks}, {3, StreamData.map(units, &duration/1)}])
    end

    defp formatted(:uuid) do
      StreamData.map(StreamData.binary(length: 16), &uuid/1)
    end

    defp formatted(:email) do
      StreamData.map(StreamData.fixed_list([word(), word()]), fn [local, domain] ->
        "#{local}@#{domain}.example"
      end)
    end

    defp formatted(:uri) do
      StreamData.map(word(), &"https://example.com/#{&1}")
    end

    defp formatted(:ipv4) do
      octets = List.duplicate(StreamData.integer(0..255), 4)

      StreamData.map(StreamData.fixed_list(octets), &Enum.join(&1, "."))
    end

    defp formatted(:ipv6) do
      groups = List.duplicate(StreamData.integer(0..65_535), 8)

      StreamData.map(StreamData.fixed_list(groups), fn parts ->
        Enum.map_join(parts, ":", &String.downcase(Integer.to_string(&1, 16)))
      end)
    end

    defp formatted(:hostname) do
      StreamData.map(StreamData.fixed_list([word(), word()]), fn [label, domain] ->
        "#{label}.#{domain}.example"
      end)
    end

    defp word, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 8)

    defp duration([year, month, day, hour, minute, second]) do
      Duration.new!(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
      )
    end

    defp uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
      Enum.map_join([a, b, c, d, e], "-", &Base.encode16(&1, case: :lower))
    end

    defp at(context, segment), do: %{context | path: context.path ++ [segment]}

    defp refuse!(%{path: path}, what) do
      raise ArgumentError,
            "cannot generate values for #{what} at #{inspect(path)}: " <>
              "give the property a schema without it, or write that case by hand"
    end
  end
end

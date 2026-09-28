defmodule Rupa.GenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rupa.T

  defmodule Place do
    @moduledoc false
    defstruct [:city]
  end

  # `tags` is the case a generated struct never produces: an optional field whose defstruct
  # default is a value rather than nil, so the round trip has to recognise *that* as absent.
  defmodule Person do
    @moduledoc false
    defstruct [:name, :nick, :note, :home, :kids, rank: 0, tags: []]
  end

  # The roadmap's extra gate for M4b: a thousand values per property, every one of them checked
  # on both backends.
  @runs 1000

  # StreamData's generation size bounds every collection and string it builds, and it runs up
  # to 100 by default. `StreamData.map_of/3` is quadratic in the number of keys — 10 ms a value
  # at the default, 0.3 ms at 20 — and an inverse property learns nothing from a fifty-key map
  # that it does not learn from a small one. It wants many values, not large ones.
  @size 20

  # What a generator is for. Encode a generated value, decode what comes back, and get the value
  # you started with -- on the closure backend and the module backend, agreeing on the wire in
  # between. A generated value is already decoded, so unlike the wire there is nothing here that
  # a default is allowed to change.
  #
  # M7 added the second half: the same round trip through JSON text rather than through a wire
  # term. That is where escaping, float rendering and an object's key order would show up, and
  # a thousand generated values per property is a better search for those than any fixture.
  defp inverse!(codec, module, value) do
    assert {:ok, wire} = Rupa.encode(codec, value)
    assert Rupa.encode(module, value) == {:ok, wire}
    assert Rupa.decode(codec, wire) == {:ok, value}
    assert Rupa.decode(module, wire) == {:ok, value}

    assert {:ok, iodata} = Rupa.encode_json(codec, value)
    text = IO.iodata_to_binary(iodata)

    assert IO.iodata_to_binary(Rupa.encode_json!(module, value)) == text
    assert Rupa.decode_json(codec, text) == {:ok, value}
    assert Rupa.decode_json(module, text) == {:ok, value}
  end

  # `check all` documents a `:max_generation_size` option for exactly this, but stream_data
  # 1.4.0 rebuilds its options list without that key before reading it, so passing it there is
  # silently ignored. This is what it would have done.
  defp bounded(codec), do: StreamData.scale(Rupa.Gen.stream(codec), &min(&1, @size))

  defp backends(schema) do
    hash = :erlang.phash2(Rupa.Schema.normalize(schema))
    {:ok, module} = Rupa.compile(schema, as: Module.concat(Rupa.Conformance, "G#{hash}"))

    {Rupa.compile!(schema), module}
  end

  # =============================================
  # Round trips
  # =============================================

  property "scalars, with every shape of bound" do
    schema = %{
      free: T.string(),
      bounded: T.string(min: 2, max: 8),
      exact: T.string(len: 4),
      whole: T.integer(),
      from: T.integer(gte: 5),
      upto: T.integer(lte: 5),
      between: T.integer(gt: 0, lt: 100),
      stepped: T.integer(gte: -20, lte: -1, multiple_of: 3),
      real: T.float(),
      narrow: T.float(gte: 0.0, lte: 1.0),
      strict: T.float(gt: 0.0, lt: 1.0),
      flag: T.boolean(),
      nothing: T.null()
    }

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "containers, and the three states a field can be in" do
    schema = %{
      items: T.list(T.integer(gte: 0, lte: 9)),
      sized: T.list(T.string(len: 2), min: 1, max: 4),
      distinct: T.list(T.integer(), unique: true, max: 5),
      point: T.tuple([T.float(gte: -1.0, lte: 1.0), T.string(min: 1, max: 3)]),
      counts: T.map_of(T.integer(gte: 0, lte: 99)),
      maybe: T.nullable(T.string(min: 1, max: 4)),
      role: T.enum([:admin, :member], default: :member),
      version: T.literal("v2"),
      nickname: T.optional(T.string(min: 1, max: 6))
    }

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "every format" do
    schema = %{
      at: T.datetime(),
      on: T.date(),
      clock: T.time(),
      span: T.duration(),
      id: T.uuid(),
      mail: T.email(),
      link: T.uri(),
      four: T.ipv4(),
      six: T.ipv6(),
      host: T.hostname()
    }

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "recursion, through a list, a tuple and a nullable" do
    schema =
      T.object(
        %{tree: T.ref(:node)},
        defs: %{
          node: %{
            value: T.integer(gte: 0, lte: 9),
            pair: T.tuple([T.string(len: 1), T.list(T.ref(:node), max: 2)]),
            next: T.nullable(T.ref(:node))
          }
        }
      )

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "a renamed object, and one keyed by strings" do
    schema =
      T.object(
        %{
          first_name: T.string(min: 1, max: 6),
          last_name: T.string(from: "surname"),
          signed_up_at: T.datetime(),
          home_address: T.optional(T.object(%{post_code: T.string(len: 4)}, keys: :string))
        },
        rename_all: :camelCase
      )

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "an object whose field names are strings" do
    schema =
      {:object,
       %{
         "first_name" => T.string(min: 1, max: 6),
         "id" => T.string(from: "userId"),
         "nick" => T.optional(T.string()),
         "at" => T.datetime(),
         "nested" => {:object, %{"n" => T.integer(gte: 0)}, [keys: :atom]}
       }, [rename_all: :camelCase]}

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "unions, tagged both ways and untagged" do
    schema = %{
      shape:
        T.tagged(:type, %{
          "circle" => %{r: T.float(gte: 0.0, lte: 9.0)},
          "rect" => %{w: T.float(gte: 0.0, lte: 9.0), h: T.float(gte: 0.0, lte: 9.0)}
        }),
      event:
        T.tagged(:kind, %{"at" => T.datetime(), "count" => T.integer(gte: 0, lte: 9)},
          content: :value
        ),
      # Disjoint on purpose: an untagged union round-trips only when no two variants take the
      # same value, because decoding picks the first that does.
      either: T.union([T.integer(gte: 0, lte: 9), T.string(min: 1, max: 4)], tag: :none)
    }

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "a tagged union that recurses through its own branches" do
    schema =
      T.tagged(:type, %{
        "leaf" => %{v: T.integer(gte: 0, lte: 9)},
        "node" => %{kids: T.list(T.ref(:root), max: 2)}
      })

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      inverse!(codec, module, value)
    end
  end

  property "structs, nested and recursive" do
    # `into:` is the one feature where the generator has to hand back something other than a map,
    # and the round trip is where that matters: an absent optional key comes back as the module's
    # own default, so both sides have already agreed that absent and nil are one state.
    schema =
      T.object(
        %{
          name: T.string(min: 1, max: 6),
          nick: T.optional(T.string(min: 1, max: 4)),
          note: T.optional(T.nullable(T.string(min: 1, max: 4))),
          rank: T.integer(gte: 0, lte: 9, default: 0),
          home: T.object(%{city: T.string(min: 1, max: 6)}, into: Rupa.GenTest.Place),
          tags: T.optional(T.list(T.string(min: 1, max: 4), max: 2)),
          kids: T.list(T.ref(:root), max: 2)
        },
        into: Rupa.GenTest.Person
      )

    {codec, module} = backends(schema)

    check all(value <- bounded(codec), max_runs: @runs) do
      assert %Rupa.GenTest.Person{home: %Rupa.GenTest.Place{}} = value
      inverse!(codec, module, value)
    end
  end

  # =============================================
  # What it takes
  # =============================================

  describe "stream/1" do
    test "takes a codec, a generated module, or a schema" do
      schema = %{a: T.integer(gte: 1, lte: 3)}
      {codec, module} = backends(schema)

      for source <- [codec, module, schema] do
        assert [%{a: a}] = source |> Rupa.Gen.stream() |> Enum.take(1)
        assert a in 1..3
      end
    end

    test "says so when the schema is not one" do
      assert_raise Rupa.SchemaError, fn -> Rupa.Gen.stream(:not_a_schema) end
    end
  end

  # =============================================
  # What it refuses
  # =============================================

  describe "refusals" do
    test "a pattern, because generating a string from a PCRE is a project of its own" do
      schema = %{codes: T.list(T.string(pattern: "^[a-z]+$"))}

      assert_raise ArgumentError, ~r/pattern: at \[:codes, :of\]/, fn ->
        Rupa.Gen.stream(schema)
      end
    end

    # A format's generator produces values of that format and has no way to also reach a length on
    # demand, so a `min:`/`max:`/`len:` beside a format is refused rather than quietly dropped.
    test "a length constraint sitting beside a format" do
      assert_raise ArgumentError,
                   ~r/a length constraint on a formatted string at \[:code\]/,
                   fn ->
                     Rupa.Gen.stream(%{code: T.email(max: 30)})
                   end

      assert_raise ArgumentError, ~r/a length constraint on a formatted string/, fn ->
        Rupa.Gen.stream(T.uuid(len: 36))
      end
    end

    test "a multiple_of that cannot be hit exactly" do
      assert_raise ArgumentError, ~r/multiple_of: on a float/, fn ->
        Rupa.Gen.stream(T.float(multiple_of: 0.1))
      end

      assert_raise ArgumentError, ~r/not a whole number/, fn ->
        Rupa.Gen.stream(T.integer(multiple_of: 2.5))
      end
    end

    test "a bound that nothing satisfies" do
      assert_raise ArgumentError, ~r/no integer in it/, fn ->
        Rupa.Gen.stream(T.integer(gt: 1, lt: 2))
      end

      assert_raise ArgumentError, ~r/no multiple of 5 in it/, fn ->
        Rupa.Gen.stream(T.integer(gte: 1, lte: 2, multiple_of: 5))
      end

      # Past 2^53 an integer bound need not be a float, and the floats around it may all fall
      # outside the interval; between two adjacent floats there is none at all.
      assert_raise ArgumentError, ~r/no float in it/, fn ->
        Rupa.Gen.stream(T.float(gte: 9_007_199_254_740_993, lte: 9_007_199_254_740_993))
      end

      assert_raise ArgumentError, ~r/no float in it/, fn ->
        Rupa.Gen.stream(T.float(gt: 0.0, lt: 5.0e-324))
      end

      assert_raise ArgumentError, ~r/no float in it/, fn ->
        Rupa.Gen.stream(T.float(gt: 1.7976931348623157e308))
      end

      assert_raise ArgumentError, ~r/no float in it/, fn ->
        Rupa.Gen.stream(T.float(lt: -1.7976931348623157e308))
      end
    end

    # An integer bound rounds to the nearest float on the way into StreamData, which past 2^53 can
    # land outside the interval it came from. Each bound is moved to the nearest float inside it
    # instead, so every generated value satisfies the bound the codec will check.
    property "a float bound past 2^53 is honoured exactly, closed or open" do
      schemas = [
        T.float(gte: 9_007_199_254_740_993, lte: 9_007_199_254_740_994),
        T.float(gte: 9_007_199_254_740_993, lte: 9_007_199_254_741_000),
        T.float(gt: 9_007_199_254_740_992, lt: 9_007_199_254_740_996),
        T.float(gt: 9_007_199_254_740_993, lt: 9_007_199_254_741_000),
        T.float(lt: 0),
        T.float(gte: -9_007_199_254_740_994, lte: -9_007_199_254_740_993),
        T.float(gt: 0, lt: 1),
        T.float(gte: 1.0e308)
      ]

      for schema <- schemas do
        codec = Rupa.compile!(schema)

        check all(value <- Rupa.Gen.stream(codec), max_runs: 50) do
          assert Rupa.valid?(codec, value), "#{inspect(value)} fails #{inspect(schema)}"
        end
      end
    end

    test "a recursion with no case that stops" do
      schema = T.object(%{start: T.ref(:node)}, defs: %{node: %{child: T.ref(:node)}})

      assert_raise ArgumentError, ~r/recursion at :node has no case that stops/, fn ->
        Rupa.Gen.stream(schema)
      end
    end

    test "a union with no variant that stops" do
      schema =
        T.object(%{start: T.ref(:node)},
          defs: %{
            node: %{next: T.union([T.ref(:node), T.list(T.ref(:node), min: 1)], tag: :none)}
          }
        )

      # A union that can reach itself is nested by definition, so staging warns about it too.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise ArgumentError, ~r/no case that stops/, fn -> Rupa.Gen.stream(schema) end
      end)
    end

    test "and a tagged one with no branch that does" do
      schema =
        T.object(%{start: T.ref(:node)},
          defs: %{node: T.tagged(:type, %{"only" => %{next: T.ref(:node)}})}
        )

      assert_raise ArgumentError, ~r/no case that stops/, fn -> Rupa.Gen.stream(schema) end
    end

    test "and a mandatory list is not a case that stops either" do
      schema =
        T.object(%{start: T.ref(:node)},
          defs: %{node: %{kids: T.list(T.ref(:node), min: 1)}}
        )

      assert_raise ArgumentError, ~r/no case that stops/, fn -> Rupa.Gen.stream(schema) end
    end
  end
end

defmodule Rupa.JsonTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  # The same conformance rule as everywhere else: both backends, and they have to agree. Here
  # they have to agree on bytes, not just on a term, which is the stricter claim.
  defp json(schema, value, opts \\ []) do
    closure = flat(Rupa.encode_json(Rupa.compile!(schema), value, opts))
    module = flat(Rupa.encode_json(generated(schema), value, opts))

    assert closure == module, """
    the backends disagree.
      closure: #{inspect(closure)}
      module:  #{inspect(module)}
    """

    closure
  end

  defp flat({:ok, iodata}), do: {:ok, IO.iodata_to_binary(iodata)}
  defp flat({:error, _errors} = error), do: error

  defp codes(schema, value, opts \\ []) do
    assert {:error, errors} = json(schema, value, opts)
    Enum.map(errors, &{&1.path, &1.code})
  end

  defp code(schema, value) do
    assert [pair] = codes(schema, value)
    pair
  end

  defp generated(schema) do
    hash = :erlang.phash2(Rupa.Schema.normalize(schema))
    {:ok, name} = Rupa.compile(schema, as: Module.concat(Rupa.Conformance, "J#{hash}"))
    name
  end

  # `Rupa.encode/3` returns `nil` for a null, and `:json.encode/1` writes a bare atom as a
  # string — so the two-step it is being compared against needs an encoder that knows better.
  # bench/json.exs uses the same one and says why.
  defp nullable(nil, _encoder), do: "null"
  defp nullable(other, encoder), do: :json.encode_value(other, encoder)

  # What fusing is allowed to change, and what it is not. Not the document: the fused bytes and
  # the two-step's bytes decode to the same term. Only the order of an object's keys, which is
  # the schema's rather than a map's.
  defp agrees(schema, value) do
    codec = Rupa.compile!(schema)

    assert {:ok, fused} = flat(Rupa.encode_json(codec, value))
    assert {:ok, wire} = Rupa.encode(codec, value)
    two_step = IO.iodata_to_binary(:json.encode(wire, &nullable/2))

    assert :json.decode(fused) == :json.decode(two_step)

    fused
  end

  defp round_trips(schema, value) do
    codec = Rupa.compile!(schema)

    assert {:ok, iodata} = Rupa.encode_json(codec, value)
    assert {:ok, ^value} = Rupa.decode_json(codec, IO.iodata_to_binary(iodata))

    value
  end

  describe "encode_json/3, scalars" do
    test "emit themselves, and say so when the value is the wrong shape" do
      assert json(T.string(), "a") == {:ok, ~s("a")}
      assert code(T.string(), 1) == {[], :type}

      assert json(T.integer(), 1) == {:ok, "1"}
      assert code(T.integer(), 1.0) == {[], :type}

      assert json(T.float(), 1.5) == {:ok, "1.5"}
      assert code(T.float(), "2") == {[], :type}

      assert json(T.boolean(), true) == {:ok, "true"}
      assert json(T.boolean(), false) == {:ok, "false"}
      assert code(T.boolean(), "true") == {[], :type}

      assert json(T.null(), nil) == {:ok, "null"}
      assert code(T.null(), 0) == {[], :type}
    end

    test "a float slot takes any number, the same as encode/3 does" do
      assert json(T.float(), 2) == {:ok, "2"}
      assert agrees(T.float(), 2) == "2"
    end

    test "strings are escaped by :json itself" do
      assert json(T.string(), ~s(a "b" \n c)) == {:ok, ~s("a \\"b\\" \\n c")}
      assert json(T.string(), "ünïcode") == {:ok, ~s("ünïcode")}
    end

    test "a format writes its own wire shape" do
      assert json(T.datetime(), ~U[2026-09-16 10:00:00Z]) == {:ok, ~s("2026-09-16T10:00:00Z")}
      assert json(T.date(), ~D[2026-09-16]) == {:ok, ~s("2026-09-16")}
      assert code(T.datetime(), "already a string") == {[], :format}
    end

    test "an enum and a literal are rendered once, while the schema is staged" do
      assert json(T.enum([:admin, :member]), :admin) == {:ok, ~s("admin")}
      assert json(T.literal(7), 7) == {:ok, "7"}
      assert code(T.enum([:admin]), :nobody) == {[], :const}
    end
  end

  describe "encode_json/3, containers" do
    test "an object writes its fields in the schema's order" do
      schema = T.object(%{b: T.integer(), a: T.integer()})

      assert json(schema, %{a: 1, b: 2}) == {:ok, ~s({"a":1,"b":2})}
      assert agrees(schema, %{a: 1, b: 2})
      assert code(schema, "not a map") == {[], :type}
    end

    test "an empty object is two bytes" do
      assert json(T.object(%{}), %{}) == {:ok, "{}"}
    end

    test "an absent optional writes nothing, and a missing required one is an error" do
      schema = T.object(%{a: T.integer(), b: T.optional(T.integer())})

      assert json(schema, %{a: 1}) == {:ok, ~s({"a":1})}
      assert code(schema, %{b: 2}) == {[:a], :required}
    end

    test "the wire key is the renamed one" do
      schema =
        T.object(%{first_name: T.string(), id: T.string(to: "userId")}, rename_all: :camelCase)

      assert json(schema, %{first_name: "Ada", id: "1"}) ==
               {:ok, ~s({"firstName":"Ada","userId":"1"})}
    end

    test "keys: :string changes what is read, not what is written" do
      schema = T.object(%{first_name: T.string()}, keys: :string, rename_all: :camelCase)

      assert json(schema, %{"first_name" => "Ada"}) == {:ok, ~s({"firstName":"Ada"})}
    end

    test "unknown: :keep puts the extras back, and the other policies drop them" do
      kept = T.object(%{a: T.integer()}, unknown: :keep)

      assert json(kept, %{:a => 1, "x" => [1, 2]}) == {:ok, ~s({"a":1,"x":[1,2]})}
      assert agrees(kept, %{:a => 1, "x" => [1, 2]})

      assert json(T.object(%{a: T.integer()}), %{:a => 1, "x" => 2}) == {:ok, ~s({"a":1})}
    end

    # A kept value carries `nil` where the wire had `null`, so it has to be written back as
    # `null` rather than the bare atom `:json.encode/1` would render as the string "nil".
    test "unknown: :keep writes a kept null as null, nested ones included" do
      kept = T.object(%{a: T.integer()}, unknown: :keep)

      assert {:ok, decoded} =
               Rupa.decode_json(Rupa.compile!(kept), ~s({"a":1,"x":null,"y":{"z":null}}))

      assert json(kept, decoded) == {:ok, ~s({"a":1,"x":null,"y":{"z":null}})}
      assert agrees(kept, decoded)
    end

    test "an improper list is a type error, not a raise" do
      assert code(T.list(T.string()), ["a" | "b"]) == {[], :type}
      assert code(T.tuple([T.integer()]), [1 | 2]) == {[], :type}
    end

    test "lists and tuples are arrays, empty ones included" do
      assert json(T.list(T.string()), ["a", "b"]) == {:ok, ~s(["a","b"])}
      assert json(T.list(T.string()), []) == {:ok, "[]"}
      assert code(T.list(T.string()), "a") == {[], :type}

      assert json(T.tuple([T.integer(), T.string()]), {1, "x"}) == {:ok, ~s([1,"x"])}
      assert json(T.tuple([]), {}) == {:ok, "[]"}
      assert code(T.tuple([T.integer()]), {1, 2}) == {[], :tuple_size}
      assert code(T.tuple([T.integer()]), [1]) == {[], :type}
    end

    test "a map-of is an object, and its keys are written the way :json writes them" do
      schema = T.map_of(T.integer())

      assert json(schema, %{"b" => 2, "a" => 1}) == {:ok, ~s({"a":1,"b":2})}
      assert json(schema, %{}) == {:ok, "{}"}
      assert json(schema, %{:a => 1}) == {:ok, ~s({"a":1})}
      assert json(schema, %{1 => 1}) == {:ok, ~s({"1":1})}
      assert json(schema, %{1.5 => 1}) == {:ok, ~s({"1.5":1})}
      assert code(schema, "a") == {[], :type}
    end

    test "a nullable writes null, and so does a null inside a list" do
      assert json(T.nullable(T.string()), nil) == {:ok, "null"}
      assert json(T.nullable(T.string()), "a") == {:ok, ~s("a")}
      assert json(T.list(T.nullable(T.integer())), [1, nil]) == {:ok, "[1,null]"}
      assert agrees(T.object(%{a: T.nullable(T.string())}), %{a: nil})
    end
  end

  describe "encode_json/3, string field names" do
    test "a string-named object writes the same bytes an atom-named one would" do
      strings = {:object, %{"a" => T.string(), "n" => T.integer()}, []}
      atoms = T.object(%{a: T.string(), n: T.integer()})

      assert json(strings, %{"a" => "x", "n" => 1}) == {:ok, ~s({"a":"x","n":1})}
      assert json(atoms, %{a: "x", n: 1}) == {:ok, ~s({"a":"x","n":1})}
      assert agrees(strings, %{"a" => "x", "n" => 1})
      assert round_trips(strings, %{"a" => "x", "n" => 1})
    end

    test "renaming and keys: :atom reach it the same way" do
      schema = {:object, %{"first_name" => T.string()}, [keys: :atom, rename_all: :camelCase]}

      assert json(schema, %{first_name: "Ada"}) == {:ok, ~s({"firstName":"Ada"})}
    end

    test "unknown: :keep writes back only what no field claims" do
      schema = {:object, %{"a" => T.string(to: "b")}, [unknown: :keep]}

      assert json(schema, %{"a" => "x", "z" => 1}) == {:ok, ~s({"b":"x","z":1})}
      assert json(schema, %{"a" => "x", "b" => 1}) == {:ok, ~s({"b":"x"})}
    end
  end

  describe "encode_json/3, unions" do
    test "an internally tagged branch carries its tag as its first key" do
      schema = T.tagged(:kind, %{"circle" => T.object(%{r: T.float()})})

      assert json(schema, {:circle, %{r: 2.0}}) == {:ok, ~s({"kind":"circle","r":2.0})}
      assert agrees(schema, {:circle, %{r: 2.0}})
      assert code(schema, {:square, %{}}) == {[], :unknown_tag}
      assert code(schema, %{r: 2.0}) == {[], :unknown_tag}
      assert code(schema, {:circle, "not a map"}) == {[], :type}
    end

    test "a branch with no fields of its own is the tag and nothing else" do
      schema = T.tagged(:kind, %{"nothing" => T.object(%{})})

      assert json(schema, {:nothing, %{}}) == {:ok, ~s({"kind":"nothing"})}
      assert code(schema, {:nothing, "not a map"}) == {[], :type}
      assert round_trips(schema, {:nothing, %{}})
    end

    test "an adjacently tagged branch can be any schema at all" do
      schema = T.tagged(:k, %{"n" => T.integer()}, content: :v)

      assert json(schema, {:n, 1}) == {:ok, ~s({"k":"n","v":1})}
      assert agrees(schema, {:n, 1})
      assert code(schema, {:n, "x"}) == {[:v], :type}
    end

    test "an untagged union takes the first variant that fits" do
      schema = T.union([T.integer(), T.string()], tag: :none)

      assert json(schema, 1) == {:ok, "1"}
      assert json(schema, "x") == {:ok, ~s("x")}
      assert code(schema, true) == {[], :no_variant}
    end

    test "an untagged union emits the branch whose JSON decodes back to the value" do
      # Same round-trip selection as encode/3: the constraint-disjoint second branch is chosen so
      # data survives, rather than the first branch that would drop it.
      schema =
        T.union([%{n: T.integer(gt: 0)}, %{n: T.integer(lte: 0), data: T.string()}], tag: :none)

      assert json(schema, %{n: -1, data: "keep me"}) ==
               {:ok, ~s({"data":"keep me","n":-1})}

      # round_trips/2 here takes the decoded value (atom keys), not the wire.
      assert round_trips(schema, %{n: -1, data: "keep me"})
      assert code(schema, %{n: 0}) == {[], :no_variant}
    end

    test "a renamed field reached through a recursive definition still emits inside the union" do
      # As for encode/3: the verifier's refs resolve to the symmetric program's decoders, so the
      # branch's output name is not read back through the definition's input name.
      schema =
        T.object(%{item: T.union([T.integer(), T.ref(:node)], tag: :none)},
          defs: %{node: %{x: T.string(from: "old", to: "new"), kids: T.list(T.ref(:node))}}
        )

      assert json(schema, %{item: %{x: "x", kids: [%{x: "y", kids: []}]}}) ==
               {:ok, ~s({"item":{"kids":[{"kids":[],"new":"y"}],"new":"x"}})}
    end
  end

  describe "encode_json/3, refs" do
    test "recursion emits through the definition table, on both backends" do
      schema = T.object(%{value: T.integer(), children: T.list(T.ref(:root))})

      value = %{value: 1, children: [%{value: 2, children: []}]}

      assert json(schema, value) == {:ok, ~s({"children":[{"children":[],"value":2}],"value":1})}
      assert round_trips(schema, value)
    end

    test "recursion through a tagged union emits too" do
      schema =
        T.tagged(:kind, %{
          "leaf" => T.object(%{v: T.integer()}),
          "node" => T.object(%{kids: T.list(T.ref(:root))})
        })

      value = {:node, %{kids: [leaf: %{v: 1}]}}

      assert json(schema, value) ==
               {:ok, ~s({"kind":"node","kids":[{"kind":"leaf","v":1}]})}

      assert round_trips(schema, value)
    end
  end

  describe "encode_json/3, errors" do
    test "paths point at the offending node, through every kind of container" do
      schema =
        T.object(%{
          rows: T.list(T.object(%{n: T.integer()})),
          pair: T.tuple([T.integer()]),
          counts: T.map_of(T.integer())
        })

      value = %{rows: [%{n: "x"}], pair: {1}, counts: %{"a" => 1}}
      assert code(schema, value) == {[:rows, 0, :n], :type}

      value = %{rows: [], pair: {"x"}, counts: %{"a" => 1}}
      assert code(schema, value) == {[:pair, 0], :type}

      value = %{rows: [], pair: {1}, counts: %{"a" => "x"}}
      assert code(schema, value) == {[:counts, "a"], :type}
    end

    test "on_error: :collect keeps going, in every container" do
      schema = T.object(%{a: T.integer(), b: T.integer(), c: T.integer()})

      assert codes(schema, %{a: "x", b: "y"}, on_error: :collect) ==
               [{[:a], :type}, {[:b], :type}, {[:c], :required}]

      assert codes(T.list(T.integer()), ["x", "y"], on_error: :collect) ==
               [{[0], :type}, {[1], :type}]

      assert codes(T.tuple([T.integer(), T.integer()]), {"x", "y"}, on_error: :collect) ==
               [{[0], :type}, {[1], :type}]

      assert codes(T.map_of(T.integer()), %{"a" => "x", "b" => "y"}, on_error: :collect) ==
               [{["a"], :type}, {["b"], :type}]
    end

    test "an optional that is present and wrong is still an error in :collect" do
      schema = T.object(%{a: T.optional(T.integer()), b: T.integer()})

      assert codes(schema, %{a: "x"}, on_error: :collect) == [{[:a], :type}, {[:b], :required}]
    end

    # A string schema accepts any binary and decode/encode both take a non-UTF-8 one, but JSON
    # text must be UTF-8. Encoding it to JSON is a path-bearing error on both backends, not an
    # ErlangError out of the encoder.
    test "a string that is not valid UTF-8 is an :invalid_utf8 error, not a raise" do
      assert code(%{s: T.string()}, %{s: <<255>>}) == {[:s], :invalid_utf8}

      # The same binary decodes and encodes fine -- only turning it into JSON text fails.
      codec = Rupa.compile!(T.string())
      assert Rupa.decode(codec, <<255>>) == {:ok, <<255>>}
      assert Rupa.encode(codec, <<255>>) == {:ok, <<255>>}
    end

    # The plain-string node is not the only route to JSON text: a map-of key, and a kept extra's
    # key and value all reach OTP's encoder too, and each is now a path-bearing :invalid_utf8
    # rather than an ErlangError -- on both backends. A formatted string never gets that far:
    # every format is ASCII, so the format itself refuses the byte.
    test "the format, map-of-key and kept-extra routes refuse a non-UTF-8 byte too" do
      assert code(%{email: T.email()}, %{email: <<255>> <> "@example.com"}) == {[:email], :format}

      assert {_key_path, :invalid_utf8} = code(T.map_of(T.integer()), %{<<255>> => 1})

      keep = T.object(%{}, unknown: :keep)
      assert {_value_path, :invalid_utf8} = code(keep, %{"bad" => <<255>>})
      assert {_key_path, :invalid_utf8} = code(keep, %{<<255>> => 1})
    end

    # A decoded map may hold keys of any type -- `decode/3` reads a term as it is -- but a JSON
    # object's names are strings, and two keys of different types can render to one name. Writing
    # the name twice would leave the reader to pick the survivor, so it is refused instead; a
    # term-level `encode/3` is untouched, since a term map holds both keys apart.
    test "two keys that render to one JSON name are :duplicate_key, not a duplicated member" do
      assert code(T.map_of(T.integer()), %{1 => 2, "1" => 3}) == {["1"], :duplicate_key}
      assert code(T.map_of(T.integer()), %{"a" => 2, a: 1}) == {["a"], :duplicate_key}
      assert code(T.map_of(T.integer()), %{1.0 => 1, "1.0" => 2}) == {["1.0"], :duplicate_key}

      assert {:ok, %{1 => 2, "1" => 3}} =
               Rupa.encode(Rupa.compile!(T.map_of(T.integer())), %{1 => 2, "1" => 3})

      # Distinct names of mixed types are fine, whatever their types.
      assert {:ok, text} = json(T.map_of(T.integer()), %{1 => 1, "2" => 2, :c => 3, 4.5 => 4})
      assert :json.decode(text) == %{"1" => 1, "2" => 2, "c" => 3, "4.5" => 4}
    end

    test "a struct under unknown: :keep writes its fields and never its tag" do
      schema = T.object(%{path: T.string()}, unknown: :keep)

      assert {:ok, text} = json(schema, %URI{path: "/p", port: 1})
      decoded = :json.decode(text)
      assert decoded["path"] == "/p" and decoded["port"] == 1
      refute Map.has_key?(decoded, "__struct__")
    end

    test "a kept extra cannot render to a field's name, or to another extra's" do
      keep = T.object(%{"x" => T.integer()}, unknown: :keep)
      assert code(keep, %{"x" => 1, :x => 2}) == {[:x], :duplicate_key}

      keep = T.object(%{}, unknown: :keep)
      assert code(keep, %{1 => 1, "1" => 2}) == {["1"], :duplicate_key}

      # An extra under a field's own key is skipped, the way decode skipped a wire key that would
      # have shadowed the field; it is not written and so cannot collide.
      keep = T.object(%{x: T.integer()}, unknown: :keep)
      assert {:ok, ~s({"x":1})} = json(keep, %{"x" => 2, x: 1})
    end

    test "a key with no string form is :unsupported_key, not a raise" do
      assert code(T.map_of(T.integer()), %{{1, 2} => 3}) == {[{1, 2}], :unsupported_key}
      assert code(T.object(%{}, unknown: :keep), %{{1, 2} => 3}) == {[{1, 2}], :unsupported_key}

      # ...and only turning it into JSON fails: the same map decodes and encodes as a term.
      codec = Rupa.compile!(T.map_of(T.integer()))
      assert Rupa.decode(codec, %{{1, 2} => 3}) == {:ok, %{{1, 2} => 3}}
      assert Rupa.encode(codec, %{{1, 2} => 3}) == {:ok, %{{1, 2} => 3}}
    end

    # Kept extras are written by Rupa rather than handed whole to OTP's encoder, so a failure
    # inside one names the key it was under -- however deep -- and :collect collects them.
    test "errors in kept extras carry their path, distinguish their cause, and collect" do
      schema = %{data: T.object(%{}, unknown: :keep)}

      assert code(schema, %{data: %{"bad" => <<255>>}}) == {[:data, "bad"], :invalid_utf8}
      assert code(schema, %{data: %{"t" => {1, 2}}}) == {[:data, "t"], :unsupported_value}
      assert code(schema, %{data: %{"t" => %URI{}}}) == {[:data, "t"], :unsupported_value}

      assert code(schema, %{data: %{"n" => %{"deep" => [1, <<255>>]}}}) ==
               {[:data, "n", "deep", 1], :invalid_utf8}

      assert code(schema, %{data: %{"n" => %{1 => 1, "1" => 2}}}) ==
               {[:data, "n", "1"], :duplicate_key}

      assert codes(schema, %{data: %{"bad" => <<255>>, "worse" => <<254>>}}, on_error: :collect) ==
               [{[:data, "bad"], :invalid_utf8}, {[:data, "worse"], :invalid_utf8}]

      assert codes(schema, %{data: %{"l" => [<<255>>, <<254>>]}}, on_error: :collect) ==
               [{[:data, "l", 0], :invalid_utf8}, {[:data, "l", 1], :invalid_utf8}]

      # Nested nulls, booleans, atoms and numbers in a kept value still come out as JSON.
      assert {:ok, text} =
               json(schema, %{
                 data: %{
                   "k" => %{
                     "n" => nil,
                     "b" => true,
                     "no" => false,
                     "a" => :x,
                     "f" => 1.5,
                     "l" => [nil, 1]
                   }
                 }
               })

      assert :json.decode(text) == %{
               "data" => %{
                 "k" => %{
                   "n" => :null,
                   "b" => true,
                   "no" => false,
                   "a" => "x",
                   "f" => 1.5,
                   "l" => [:null, 1]
                 }
               }
             }
    end
  end

  describe "encode_json!/3" do
    test "returns iodata, and raises rather than returning errors" do
      codec = Rupa.compile!(%{n: T.integer()})

      assert codec |> Rupa.encode_json!(%{n: 1}) |> IO.iodata_to_binary() == ~s({"n":1})
      assert_raise Rupa.EncodeError, fn -> Rupa.encode_json!(codec, %{n: "x"}) end
    end
  end

  describe "decode_json/3" do
    test "parses and then decodes, on both backends" do
      schema = %{name: T.string(), at: T.datetime(), home: T.nullable(T.string())}
      text = ~s({"name":"Ada","at":"2026-09-16T10:00:00Z","home":null})
      expected = %{name: "Ada", at: ~U[2026-09-16 10:00:00Z], home: nil}

      assert Rupa.decode_json(Rupa.compile!(schema), text) == {:ok, expected}
      assert Rupa.decode_json(generated(schema), text) == {:ok, expected}
    end

    test "a JSON null is nil, not the atom :null" do
      assert Rupa.decode_json(Rupa.compile!(T.nullable(T.integer())), "null") == {:ok, nil}
    end

    test "the schema's own errors come back unchanged" do
      codec = Rupa.compile!(%{n: T.integer()})

      assert {:error, [error]} = Rupa.decode_json(codec, ~s({"n":"x"}))
      assert {error.path, error.code} == {[:n], :type}
    end

    test "on_error: reaches decode/3 the way it does anywhere else" do
      codec = Rupa.compile!(%{a: T.integer(), b: T.integer()})

      assert {:error, errors} = Rupa.decode_json(codec, ~s({"a":"x"}), on_error: :collect)
      assert length(errors) == 2
    end

    test "trailing whitespace is fine, and trailing anything else is not" do
      codec = Rupa.compile!(%{})

      assert Rupa.decode_json(codec, "{}\n  ") == {:ok, %{}}
      assert reason(codec, "{} []") == {:trailing, " []"}
    end

    test "text that is not JSON is an error rather than a raise" do
      codec = Rupa.compile!(%{})

      assert reason(codec, "{oops") == {:invalid_byte, ?o}
      assert reason(codec, "{") == :unexpected_end
      assert reason(codec, ~S("\uZZZZ")) == {:unexpected_sequence, "\\uZZZZ"}
      assert reason(codec, :not_text) == {:not_text, :not_text}
    end

    test "every reason renders a sentence" do
      codec = Rupa.compile!(%{})

      for text <- ["{oops", "{", ~S("\uZZZZ"), "{} []", :not_text] do
        assert {:error, [error]} = Rupa.decode_json(codec, text)
        assert "invalid JSON: " <> _rest = Rupa.Error.message(error)
      end
    end
  end

  describe "decode_json!/3" do
    test "raises rather than returning errors" do
      codec = Rupa.compile!(%{n: T.integer()})

      assert Rupa.decode_json!(codec, ~s({"n":1})) == %{n: 1}
      assert_raise Rupa.DecodeError, fn -> Rupa.decode_json!(codec, "{oops") end
    end
  end

  describe "the two directions together" do
    test "round-trip the whole vocabulary" do
      schema =
        T.object(%{
          id: T.uuid(),
          name: T.string(min: 1),
          active: T.boolean(),
          score: T.float(gte: 0),
          nick: T.optional(T.string()),
          role: T.enum([:admin, :member]),
          at: T.datetime(),
          home: T.nullable(T.string()),
          pair: T.tuple([T.integer(), T.string()]),
          counts: T.map_of(T.integer()),
          tags: T.list(T.string()),
          shape: T.tagged(:kind, %{"circle" => T.object(%{r: T.float()})}),
          when: T.tagged(:k, %{"n" => T.integer()}, content: :v),
          either: T.union([T.integer(), T.string()], tag: :none),
          nothing: T.null()
        })

      value = %{
        id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        name: "Ada",
        active: true,
        score: 9.5,
        role: :member,
        at: ~U[2026-09-16 10:00:00Z],
        home: nil,
        pair: {1, "x"},
        counts: %{"a" => 1},
        tags: ["a", "b"],
        shape: {:circle, %{r: 2.0}},
        when: {:n, 1},
        either: "x",
        nothing: nil
      }

      assert round_trips(schema, value)
      assert agrees(schema, value)
      assert json(schema, value)
    end
  end

  defp reason(codec, text) do
    assert {:error, [error]} = Rupa.decode_json(codec, text)
    assert error.code == :json
    error.meta.reason
  end
end

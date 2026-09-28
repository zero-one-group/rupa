defmodule Rupa.EncodeTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  # The same conformance rule as decoding: both backends, and they have to agree.
  defp encode(schema, value, opts \\ []) do
    closure = Rupa.encode(Rupa.compile!(schema), value, opts)
    module = Rupa.encode(generated(schema), value, opts)

    assert closure == module, """
    the backends disagree.
      closure: #{inspect(closure)}
      module:  #{inspect(module)}
    """

    closure
  end

  defp codes(schema, value, opts \\ []) do
    assert {:error, errors} = encode(schema, value, opts)
    Enum.map(errors, &{&1.path, &1.code})
  end

  defp code(schema, value) do
    assert [pair] = codes(schema, value)
    pair
  end

  defp generated(schema) do
    hash = :erlang.phash2(Rupa.Schema.normalize(schema))
    {:ok, name} = Rupa.compile(schema, as: Module.concat(Rupa.Conformance, "E#{hash}"))
    name
  end

  # What "a true inverse" means, precisely: encoding a decoded value and decoding it again
  # gives the value back. It is not the identity on the *wire*, because a default that was
  # absent comes back materialised — which is the whole point of a default.
  defp round_trips(schema, wire) do
    codec = Rupa.compile!(schema)

    assert {:ok, decoded} = Rupa.decode(codec, wire)
    assert {:ok, encoded} = Rupa.encode(codec, decoded)
    assert {:ok, ^decoded} = Rupa.decode(codec, encoded)

    encoded
  end

  describe "scalars" do
    test "pass through, and say so when the value is the wrong shape" do
      assert encode(T.string(), "a") == {:ok, "a"}
      assert code(T.string(), 1) == {[], :type}

      assert encode(T.integer(), 1) == {:ok, 1}
      assert code(T.integer(), 1.0) == {[], :type}

      assert encode(T.float(), 1.5) == {:ok, 1.5}
      assert encode(T.float(), 2) == {:ok, 2}
      assert code(T.float(), "2") == {[], :type}

      assert encode(T.boolean(), true) == {:ok, true}
      assert code(T.boolean(), "true") == {[], :type}

      assert encode(T.null(), nil) == {:ok, nil}
      assert code(T.null(), 0) == {[], :type}
    end

    test "constraints are not re-run, because decoding already bought them" do
      assert encode(T.string(min: 5), "ab") == {:ok, "ab"}
      assert encode(T.integer(gte: 0), -1) == {:ok, -1}
    end
  end

  describe "formats" do
    test "the four that change the value go back to strings" do
      assert encode(T.datetime(), ~U[2026-09-16 10:00:00Z]) == {:ok, "2026-09-16T10:00:00Z"}
      assert encode(T.date(), ~D[2026-09-16]) == {:ok, "2026-09-16"}
      assert encode(T.time(), ~T[10:00:00]) == {:ok, "10:00:00Z"}
      assert code(T.datetime(), "2026-09-16T10:00:00Z") == {[], :format}
    end

    test "the six that validate do it on the way out too" do
      uuid = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

      assert encode(T.uuid(), uuid) == {:ok, uuid}
      assert code(T.uuid(), "nope") == {[], :format}
      assert code(T.email(), 1) == {[], :format}
    end

    test "every one of them round-trips" do
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

      wire = %{
        "at" => "2026-09-16T10:00:00Z",
        "on" => "2026-09-16",
        "clock" => "10:00:00Z",
        "span" => "P1Y2M4DT5H6M7S",
        "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "mail" => "ada@example.com",
        "link" => "https://example.com/a",
        "four" => "192.168.0.1",
        "six" => "2001:db8::1",
        "host" => "api.example.com"
      }

      assert round_trips(schema, wire) == wire
    end
  end

  describe "enum and literal" do
    test "the atom goes back to the wire string it came from" do
      assert encode(T.enum([:admin, :member]), :admin) == {:ok, "admin"}
      assert encode(T.literal("v2"), "v2") == {:ok, "v2"}
      assert code(T.enum([:admin]), :root) == {[], :const}
    end
  end

  describe "objects" do
    test "atom keys become wire keys" do
      assert encode(%{a: T.string(), b: T.integer()}, %{a: "x", b: 1}) ==
               {:ok, %{"a" => "x", "b" => 1}}
    end

    test "an absent optional is omitted; an absent required one is an error" do
      schema = %{a: T.string(), b: T.optional(T.string())}

      assert encode(schema, %{a: "x"}) == {:ok, %{"a" => "x"}}
      assert code(schema, %{b: "y"}) == {[:a], :required}
    end

    test "unknown: :keep puts the extras back" do
      schema = T.object(%{a: T.string()}, unknown: :keep)

      assert encode(schema, %{:a => "x", "extra" => 9}) == {:ok, %{"a" => "x", "extra" => 9}}
    end

    test "unknown: :keep on a struct keeps its other fields and never its tag" do
      schema = T.object(%{path: T.string()}, unknown: :keep)
      uri = %URI{path: "/p", host: "h"}

      assert {:ok, wire} = encode(schema, uri)
      assert wire["path"] == "/p"
      assert wire[:host] == "h"
      refute Map.has_key?(wire, :__struct__)
    end

    test "the other policies leave anything extra behind" do
      schema = T.object(%{a: T.string()}, unknown: :error)

      assert encode(schema, %{:a => "x", "extra" => 9}) == {:ok, %{"a" => "x"}}
    end

    test "anything that is not a map, and nesting" do
      assert code(%{a: T.string()}, "nope") == {[], :type}
      assert code(%{o: %{i: T.integer()}}, %{o: %{i: "x"}}) == {[:o, :i], :type}
      assert encode(%{}, %{}) == {:ok, %{}}
    end
  end

  describe "wire names" do
    test "rename_all: writes the renamed key" do
      schema = T.object(%{first_name: T.string(), id: T.integer()}, rename_all: :camelCase)

      assert encode(schema, %{first_name: "Ada", id: 1}) ==
               {:ok, %{"firstName" => "Ada", "id" => 1}}
    end

    test "to: is the one encode writes, and one option on its own sets both" do
      schema = %{a: T.string(from: "in", to: "out"), b: T.string(from: "b_in")}

      assert encode(schema, %{a: "x", b: "y"}) == {:ok, %{"out" => "x", "b_in" => "y"}}
    end

    test "keys: :string reads back the string key it decoded to" do
      schema = T.object(%{first_name: T.string()}, rename_all: :camelCase, keys: :string)

      assert encode(schema, %{"first_name" => "Ada"}) == {:ok, %{"firstName" => "Ada"}}
      assert code(schema, %{}) == {["first_name"], :required}
      assert code(schema, %{"first_name" => 1}) == {["first_name"], :type}
    end

    test "keys: :string with unknown: :keep and an optional field" do
      schema =
        T.object(%{a: T.string(), b: T.optional(T.string())}, keys: :string, unknown: :keep)

      assert encode(schema, %{"a" => "x", "extra" => 9}) == {:ok, %{"a" => "x", "extra" => 9}}
    end
  end

  describe "containers" do
    test "an improper list is a type error, not a raise" do
      assert code(T.list(T.integer()), [1 | 2]) == {[], :type}
      assert code(T.tuple([T.integer()]), [1 | 2]) == {[], :type}
    end

    test "lists, tuples, maps and nullables" do
      assert encode(T.list(T.integer()), [1, 2]) == {:ok, [1, 2]}
      assert code(T.list(T.integer()), "nope") == {[], :type}
      assert code(T.list(T.integer()), ["x"]) == {[0], :type}

      assert encode(T.tuple([T.float(), T.string()]), {1.0, "a"}) == {:ok, [1.0, "a"]}
      assert code(T.tuple([T.float()]), {1.0, 2.0}) == {[], :tuple_size}
      assert code(T.tuple([T.float()]), [1.0]) == {[], :type}
      assert code(T.tuple([T.integer()]), {"x"}) == {[0], :type}
      assert encode(T.tuple([]), {}) == {:ok, []}

      assert encode(T.map_of(T.integer()), %{"k" => 1}) == {:ok, %{"k" => 1}}
      assert code(T.map_of(T.integer()), "nope") == {[], :type}
      assert code(T.map_of(T.integer()), %{"k" => "x"}) == {["k"], :type}

      assert encode(T.nullable(T.string()), nil) == {:ok, nil}
      assert encode(T.nullable(T.string()), "x") == {:ok, "x"}
    end

    test "recursion, in both directions" do
      schema = %{v: T.integer(), c: T.list(T.ref(:root))}

      assert encode(schema, %{v: 1, c: [%{v: 2, c: []}]}) ==
               {:ok, %{"v" => 1, "c" => [%{"v" => 2, "c" => []}]}}

      assert code(schema, %{v: 1, c: [%{c: []}]}) == {[:c, 0, :v], :required}
    end
  end

  describe "unions" do
    @shapes T.tagged(:type, %{"circle" => %{r: T.float()}, "rect" => %{w: T.float()}})
    @adjacent T.tagged(:kind, %{"n" => T.integer(), "s" => T.string()}, content: :value)

    test "the tag goes back into the branch's own map" do
      assert encode(@shapes, {:circle, %{r: 1.0}}) == {:ok, %{"type" => "circle", "r" => 1.0}}
    end

    test "content: puts it back in the envelope it came out of" do
      assert encode(@adjacent, {:n, 1}) == {:ok, %{"kind" => "n", "value" => 1}}
    end

    test "a tag that is not a branch, and a value that is not a tagged one at all" do
      assert code(@shapes, {:tri, %{}}) == {[], :unknown_tag}
      assert code(@shapes, %{r: 1.0}) == {[], :unknown_tag}
      assert code(@shapes, {"circle", %{r: 1.0}}) == {[], :unknown_tag}
    end

    test "a branch's errors carry the branch's path, and the content key when there is one" do
      assert code(@shapes, {:circle, %{r: "x"}}) == {[:r], :type}
      assert code(@shapes, {:circle, %{}}) == {[:r], :required}
      assert code(@adjacent, {:n, "x"}) == {[:value], :type}
    end

    test "an untagged union encodes under the first variant that takes the value" do
      either = T.union([T.integer(), T.string()], tag: :none)

      assert encode(either, 1) == {:ok, 1}
      assert encode(either, "x") == {:ok, "x"}
      assert code(either, true) == {[], :no_variant}
    end

    test "an untagged union picks the branch whose wire decodes back to the value" do
      # The branches are disjoint on a constraint, so encode cannot pick by type alone: n = -1
      # decoded as the second branch (keeping data), so it has to encode as the second branch too.
      # The first branch would write %{n: -1} and drop data, and that no longer decodes.
      schema =
        T.union([%{n: T.integer(gt: 0)}, %{n: T.integer(lte: 0), data: T.string()}], tag: :none)

      assert encode(schema, %{n: -1, data: "keep me"}) ==
               {:ok, %{"n" => -1, "data" => "keep me"}}

      assert round_trips(schema, %{"n" => -1, "data" => "keep me"})

      # the positive branch still round-trips as the first branch
      assert encode(schema, %{n: 5}) == {:ok, %{"n" => 5}}

      # a value no branch round-trips is a no_variant encode error, not silent data loss
      assert code(schema, %{n: 0}) == {[], :no_variant}
    end

    test "a branch that renames a field still encodes inside the union" do
      # from: ≠ to: makes a branch's encode deliberately not its decode's inverse. Branch selection
      # decodes what it encoded to confirm the choice, so it does that against a name-symmetric copy
      # -- otherwise a value this branch legitimately produced would be read back under the wrong
      # key and rejected as :no_variant.
      schema = T.union([%{x: T.string(from: "old", to: "new")}, T.integer()], tag: :none)

      assert encode(schema, %{x: "value"}) == {:ok, %{"new" => "value"}}
      assert encode(schema, 5) == {:ok, 5}
    end

    test "a renamed field reached through a recursive definition still encodes inside the union" do
      # The verifier's refs resolve to decoders of the symmetric program, not of the original one:
      # otherwise the branch's output ("new") is read back through the definition's input ("old")
      # and a legitimately decoded value is :no_variant.
      schema =
        T.object(%{item: T.union([T.integer(), T.ref(:node)], tag: :none)},
          defs: %{node: %{x: T.string(from: "old", to: "new"), kids: T.list(T.ref(:node))}}
        )

      wire = %{"item" => %{"old" => "x", "kids" => [%{"old" => "y", "kids" => []}]}}
      assert {:ok, value} = Rupa.decode(Rupa.compile!(schema), wire)

      assert encode(schema, value) ==
               {:ok, %{"item" => %{"new" => "x", "kids" => [%{"new" => "y", "kids" => []}]}}}

      assert encode(schema, %{item: 3}) == {:ok, %{"item" => 3}}

      # ...and through the root itself, which nests the union in itself and so warns once.
      root = %{
        x: T.string(from: "old", to: "new"),
        kids: T.list(T.union([T.integer(), T.ref(:root)], tag: :none))
      }

      wire = %{"old" => "a", "kids" => [%{"old" => "b", "kids" => []}]}

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, value} = Rupa.decode(Rupa.compile!(root), wire)

        assert encode(root, value) ==
                 {:ok, %{"new" => "a", "kids" => [%{"new" => "b", "kids" => []}]}}
      end)
    end

    test "the same union shape in two fields shares one verifier and still round-trips" do
      # The module backend generates a branch-verifier per union; an identical shape reused
      # elsewhere shares that verifier rather than regenerating it, and both fields must still work.
      u = T.union([%{a: T.string()}, T.integer()], tag: :none)
      schema = %{x: u, y: u}

      assert encode(schema, %{x: %{a: "hi"}, y: 5}) == {:ok, %{"x" => %{"a" => "hi"}, "y" => 5}}
      assert encode(schema, %{x: 7, y: %{a: "bye"}}) == {:ok, %{"x" => 7, "y" => %{"a" => "bye"}}}
    end

    test "a branch can be a map-of, a tuple or a tagged union, and selection still round-trips" do
      # The branch-selection verifier walks the whole union, so every container kind has to survive
      # the walk -- the value is encoded under the first branch whose wire decodes back to it.
      schema =
        T.union(
          [
            T.map_of(T.integer()),
            T.tuple([T.string()]),
            T.tagged(:k, %{"a" => %{n: T.integer(gte: 0)}})
          ],
          tag: :none
        )

      assert encode(schema, %{"x" => 1}) == {:ok, %{"x" => 1}}
      assert encode(schema, {"hi"}) == {:ok, ["hi"]}
    end
  end

  describe "on_error" do
    test "halt gives one, collect gives every field that failed" do
      schema = %{a: T.integer(), b: T.integer(), c: T.integer()}

      assert codes(schema, %{a: "x", b: "y"}) == [{[:a], :type}]

      assert codes(schema, %{a: "x", b: "y"}, on_error: :collect) ==
               [{[:a], :type}, {[:b], :type}, {[:c], :required}]
    end

    test "and it reaches inside every container" do
      assert codes(T.list(T.integer()), ["x", "y"], on_error: :collect) ==
               [{[0], :type}, {[1], :type}]

      assert codes(T.tuple([T.integer(), T.integer()]), {"x", "y"}, on_error: :collect) ==
               [{[0], :type}, {[1], :type}]

      assert codes(T.map_of(T.integer()), %{"a" => "x", "b" => "y"}, on_error: :collect) ==
               [{["a"], :type}, {["b"], :type}]
    end
  end

  describe "string field names" do
    test "an object named with strings encodes from string keys" do
      schema = {:object, %{"a" => T.string(), "n" => T.integer()}, []}

      assert encode(schema, %{"a" => "x", "n" => 1}) == {:ok, %{"a" => "x", "n" => 1}}
      assert code(schema, %{"a" => 1, "n" => 1}) == {["a"], :type}
      assert code(schema, %{"a" => "x"}) == {["n"], :required}
    end

    test "keys: :atom reads atoms and still writes the wire's own names" do
      schema = {:object, %{"first_name" => T.string()}, [keys: :atom, rename_all: :camelCase]}

      assert encode(schema, %{first_name: "Ada"}) == {:ok, %{"firstName" => "Ada"}}
    end

    test "unknown: :keep writes back only what no field claims" do
      schema = {:object, %{"a" => T.string(to: "b")}, [unknown: :keep]}

      assert encode(schema, %{"a" => "x", "z" => 1}) == {:ok, %{"b" => "x", "z" => 1}}
      assert encode(schema, %{"a" => "x", "b" => 1}) == {:ok, %{"b" => "x"}}
    end

    test "the round trip closes, with and without keys: :atom" do
      strings = {:object, %{"a" => T.string(), "at" => T.datetime()}, []}
      atoms = {:object, %{"a" => T.string()}, [keys: :atom]}

      assert round_trips(strings, %{"a" => "x", "at" => "2026-09-16T10:00:00Z"})
      assert round_trips(atoms, %{"a" => "x"})
    end
  end

  describe "round trips" do
    test "across the whole vocabulary" do
      schema =
        T.object(
          %{
            id: T.uuid(),
            age: T.optional(T.integer(gte: 0, lte: 150)),
            nickname: T.nullable(T.string()),
            role: T.enum([:admin, :member], default: :member),
            version: T.literal("v2"),
            scores: T.list(T.float(gt: 0), max: 5),
            counts: T.map_of(T.integer()),
            point: T.tuple([T.float(), T.float()]),
            flag: T.boolean(),
            nothing: T.null(),
            tree: T.list(T.ref(:node))
          },
          defs: %{node: %{value: T.integer(), children: T.list(T.ref(:node))}}
        )

      wire = %{
        "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "age" => 40,
        "nickname" => nil,
        "role" => "admin",
        "version" => "v2",
        "scores" => [1.5, 2.5],
        "counts" => %{"k" => 1},
        "point" => [1.0, 2.0],
        "flag" => true,
        "nothing" => nil,
        "tree" => [%{"value" => 1, "children" => []}]
      }

      assert round_trips(schema, wire) == wire
    end

    test "through a renamed object, and one keyed by strings" do
      schema =
        T.object(
          %{
            first_name: T.string(),
            last_name: T.string(from: "surname"),
            signed_up_at: T.datetime(),
            age: T.optional(T.integer())
          },
          rename_all: :camelCase
        )

      wire = %{
        "firstName" => "Ada",
        "surname" => "Lovelace",
        "signedUpAt" => "2026-09-16T10:00:00Z"
      }

      assert round_trips(schema, wire) == wire

      keyed = T.object(%{first_name: T.string()}, rename_all: :camelCase, keys: :string)

      assert round_trips(keyed, %{"firstName" => "Ada"}) == %{"firstName" => "Ada"}
    end

    test "through both tagging styles, and a recursive branch" do
      tree =
        T.tagged(:type, %{
          "leaf" => %{v: T.integer()},
          "node" => %{kids: T.list(T.ref(:root))}
        })

      wire = %{"type" => "node", "kids" => [%{"type" => "leaf", "v" => 1}]}
      assert round_trips(tree, wire) == wire

      adjacent = T.tagged(:kind, %{"at" => T.datetime()}, content: :value)
      envelope = %{"kind" => "at", "value" => "2026-09-16T10:00:00Z"}

      assert round_trips(adjacent, envelope) == envelope
    end

    test "a default absent from the wire comes back materialised, which is the point" do
      schema = %{a: T.string(), role: T.enum([:admin, :member], default: :member)}

      assert round_trips(schema, %{"a" => "x"}) == %{"a" => "x", "role" => "member"}
    end
  end

  describe "encode!/3" do
    test "returns the wire value" do
      assert Rupa.encode!(Rupa.compile!(%{a: T.integer()}), %{a: 1}) == %{"a" => 1}
    end

    test "raises, saying where and what" do
      codec = Rupa.compile!(%{a: %{b: T.integer()}})

      error = assert_raise Rupa.EncodeError, fn -> Rupa.encode!(codec, %{a: %{b: "x"}}) end

      assert Exception.message(error) == """
             value does not match the schema:
               /a/b expected an integer, got "x"\
             """
    end

    test "says the value when the failure is the whole thing" do
      error =
        assert_raise Rupa.EncodeError, fn ->
          Rupa.encode!(Rupa.compile!(T.integer()), "nope")
        end

      assert Exception.message(error) =~ ~s(the value expected an integer, got "nope")
    end
  end
end

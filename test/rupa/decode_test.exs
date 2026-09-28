defmodule Rupa.DecodeTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  # Every decode test runs on both backends and asserts they agree, so a feature cannot land on
  # one and not the other, and neither can a fix. The module backend is named after a hash of
  # the schema, so a repeat is a lookup rather than a recompile.
  defp decode(schema, data, opts \\ []) do
    closure = Rupa.decode(Rupa.compile!(schema), data, opts)
    module = Rupa.decode(generated(schema), data, opts)

    assert closure == module, """
    the backends disagree.
      closure: #{inspect(closure)}
      module:  #{inspect(module)}
    """

    closure
  end

  defp generated(schema) do
    hash = :erlang.phash2(Rupa.Schema.normalize(schema))
    {:ok, name} = Rupa.compile(schema, as: Module.concat(Rupa.Conformance, "C#{hash}"))
    name
  end

  defp codes(schema, data, opts \\ []) do
    assert {:error, errors} = decode(schema, data, opts)
    Enum.map(errors, &{&1.path, &1.code})
  end

  defp code(schema, data) do
    assert [pair] = codes(schema, data)
    pair
  end

  describe "scalars" do
    test "each kind accepts its own and nothing else" do
      assert decode(T.string(), "a") == {:ok, "a"}
      assert code(T.string(), 1) == {[], :type}

      assert decode(T.integer(), 1) == {:ok, 1}
      assert code(T.integer(), 1.0) == {[], :type}

      assert decode(T.boolean(), true) == {:ok, true}
      assert code(T.boolean(), "true") == {[], :type}

      assert decode(T.null(), nil) == {:ok, nil}
      assert code(T.null(), 0) == {[], :type}
    end

    test "a float takes an integer, because JSON does not have the distinction" do
      assert decode(T.float(), 1.5) == {:ok, 1.5}
      assert decode(T.float(), 2) == {:ok, 2.0}
      assert code(T.float(), "2") == {[], :type}
    end
  end

  describe "string constraints" do
    test "min: 1 is non-emptiness, and needs no counting" do
      assert decode(T.string(min: 1), "a") == {:ok, "a"}
      assert code(T.string(min: 1), "") == {[], :min}
      assert decode(T.string(min: 0), "") == {:ok, ""}
    end

    test "longer minimums count graphemes, but only when bytes leave it open" do
      assert decode(T.string(min: 2), "ab") == {:ok, "ab"}
      assert code(T.string(min: 2), "a") == {[], :min}
      # Two bytes, one grapheme: byte size says maybe, the count says no.
      assert code(T.string(min: 2), "\u00e9") == {[], :min}
    end

    test "a maximum is settled by byte size whenever it passes" do
      assert decode(T.string(max: 2), "ab") == {:ok, "ab"}
      # Four bytes, one grapheme: bytes say maybe, the count says yes.
      assert decode(T.string(max: 2), "\u00e9\u0301") == {:ok, "\u00e9\u0301"}
      assert code(T.string(max: 2), "abc") == {[], :max}
    end

    test "an exact length, from both sides" do
      assert decode(T.string(len: 2), "ab") == {:ok, "ab"}
      assert code(T.string(len: 2), "a") == {[], :len}
      assert code(T.string(len: 2), "abc") == {[], :len}
      # One grapheme cluster, four bytes: Rupa counts what a reader would count.
      assert decode(T.string(len: 1), "\u00e9\u0301") == {:ok, "\u00e9\u0301"}
    end

    test "pattern is compiled once, at compile time" do
      schema = T.string(pattern: "^[A-Z]{2}$")
      assert decode(schema, "ID") == {:ok, "ID"}
      assert code(schema, "id") == {[], :pattern}
    end

    test "checks stop at the first failure, so a leaf reports one thing" do
      assert codes(T.string(min: 5, pattern: "^a$"), "b", on_error: :collect) == [{[], :min}]
    end
  end

  describe "number constraints" do
    test "the four bounds" do
      assert code(T.integer(gte: 1), 0) == {[], :gte}
      assert code(T.integer(gt: 1), 1) == {[], :gt}
      assert code(T.integer(lte: 1), 2) == {[], :lte}
      assert code(T.integer(lt: 1), 1) == {[], :lt}
      assert decode(T.integer(gte: 1, lte: 3), 2) == {:ok, 2}
    end

    test "multiple_of, on integers and on floats" do
      assert decode(T.integer(multiple_of: 2), 4) == {:ok, 4}
      assert code(T.integer(multiple_of: 2), 7) == {[], :multiple_of}
      assert decode(T.float(multiple_of: 0.5), 1.5) == {:ok, 1.5}
      assert code(T.float(multiple_of: 0.5), 1.2) == {[], :multiple_of}
    end

    # A JSON integer past the double range is a valid number but not a representable float, so it
    # is a type error rather than an `ArithmeticError` out of the coercion.
    test "an integer too large to be a float is a type error, not a crash" do
      big = Integer.pow(10, 400)
      assert code(T.float(), big) == {[], :type}
      assert code(%{x: T.float()}, %{"x" => big}) == {[:x], :type}
      assert decode(T.float(), 1000) == {:ok, 1000.0}
    end

    # multiple_of is an exact decimal check (Rupa.Number), not a floating quotient: an ordinary
    # decimal multiple is accepted where `value / step` would miss it (0.3 / 0.1 is 2.999...), and
    # there is no overflow to reject, because nothing divides.
    test "multiple_of is exact for decimal multiples" do
      assert decode(T.float(multiple_of: 0.1), 0.3) == {:ok, 0.3}
      assert code(T.float(multiple_of: 0.1), 0.30000000000000004) == {[], :multiple_of}
      assert code(T.float(multiple_of: 0.1), 0.35) == {[], :multiple_of}
      assert decode(T.float(multiple_of: 0.0001), 1.0e308) == {:ok, 1.0e308}
      assert decode(T.float(multiple_of: 0.1), -0.3) == {:ok, -0.3}
    end

    # 2^53 + 1 rounds to 2^53.0 as a float, which does not satisfy gt: 2^53. Both backends coerce
    # the integer before checking the bound, so neither returns the rounded value and passes -- at
    # the root, and in an object field, whose generated fast path is a third route the coercion has
    # to reach too.
    test "a float bound is checked against the coerced value, not the raw integer" do
      assert code(T.float(gt: 9_007_199_254_740_992), 9_007_199_254_740_993) == {[], :gt}

      assert code(%{x: T.float(gt: 9_007_199_254_740_992)}, %{"x" => 9_007_199_254_740_993}) ==
               {[:x], :gt}

      assert decode(T.float(gte: 5), 5) == {:ok, 5.0}
      assert decode(%{x: T.float(gte: 5)}, %{"x" => 5}) == {:ok, %{x: 5.0}}
    end
  end

  describe "formats" do
    test "convert or validate, and fail at the field that holds them" do
      assert decode(T.datetime(), "2026-09-16T10:00:00Z") == {:ok, ~U[2026-09-16 10:00:00Z]}

      assert decode(T.uuid(), "6ba7b810-9dad-11d1-80b4-00c04fd430c8") ==
               {:ok, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"}

      assert code(%{at: T.datetime()}, %{"at" => "yesterday"}) == {[:at], :format}
    end

    test "constraints run before the format does" do
      assert code(T.uuid(min: 40), "6ba7b810-9dad-11d1-80b4-00c04fd430c8") == {[], :min}
    end
  end

  describe "enum and literal" do
    test "the wire string becomes the atom the schema named" do
      assert decode(T.enum([:admin, :member]), "admin") == {:ok, :admin}
      assert code(T.enum([:admin, :member]), "root") == {[], :const}
      assert decode(T.literal("v2"), "v2") == {:ok, "v2"}
      assert code(T.literal("v2"), "v1") == {[], :const}
    end
  end

  describe "objects" do
    test "required, optional and default" do
      schema = %{a: T.string(), b: T.optional(T.string()), c: T.string(default: "x")}

      assert decode(schema, %{"a" => "1"}) == {:ok, %{a: "1", c: "x"}}
      assert decode(schema, %{"a" => "1", "b" => "2"}) == {:ok, %{a: "1", b: "2", c: "x"}}
      assert code(schema, %{}) == {[:a], :required}
    end

    test "an absent optional is absent, not nil" do
      assert {:ok, decoded} = decode(%{b: T.optional(T.string())}, %{})
      refute Map.has_key?(decoded, :b)
    end

    test "null is only allowed where nullable says so" do
      assert decode(%{a: T.nullable(T.string())}, %{"a" => nil}) == {:ok, %{a: nil}}
      assert decode(%{a: T.nullable(T.string())}, %{"a" => "x"}) == {:ok, %{a: "x"}}
      assert code(%{a: T.string()}, %{"a" => nil}) == {[:a], :type}
      assert code(%{a: T.nullable(T.integer())}, %{"a" => "x"}) == {[:a], :type}
    end

    test "a default never replaces an explicit null" do
      assert code(%{a: T.string(default: "x")}, %{"a" => nil}) == {[:a], :type}
    end

    test "anything that is not a map is a type error" do
      assert code(%{a: T.string()}, "nope") == {[], :type}
    end

    test "nesting reports the whole path" do
      schema = %{outer: %{inner: T.integer(gte: 0)}}
      assert code(schema, %{"outer" => %{"inner" => -1}}) == {[:outer, :inner], :gte}
    end
  end

  describe "objects the fast clause cannot take" do
    test "an object with no fields at all, under every unknown-key policy" do
      assert decode(%{}, %{"anything" => 1}) == {:ok, %{}}
      assert code(%{}, "nope") == {[], :type}
      assert decode(T.object(%{}, unknown: :keep), %{"a" => 1}) == {:ok, %{"a" => 1}}
      assert code(T.object(%{}, unknown: :error), %{"a" => 1}) == {[], :unknown_key}
    end

    test "a field whose check cannot be a guard falls back to the chain" do
      assert decode(%{a: T.string(pattern: "^[A-Z]{2}$")}, %{"a" => "ID"}) == {:ok, %{a: "ID"}}
      assert code(%{a: T.string(pattern: "^[A-Z]{2}$")}, %{"a" => "id"}) == {[:a], :pattern}
      assert decode(%{a: T.string(max: 2)}, %{"a" => "ab"}) == {:ok, %{a: "ab"}}
      assert code(%{a: T.string(max: 2)}, %{"a" => "abc"}) == {[:a], :max}
    end

    test "multiple_of on a field: an integer step is a guard, a float step is not" do
      schema = %{i: T.integer(multiple_of: 2), f: T.float(multiple_of: 0.5)}

      assert decode(schema, %{"i" => 4, "f" => 1.5}) == {:ok, %{i: 4, f: 1.5}}
      assert code(schema, %{"i" => 3, "f" => 1.5}) == {[:i], :multiple_of}
      assert code(schema, %{"i" => 4, "f" => 1.2}) == {[:f], :multiple_of}
    end

    test "a field whose only bound is min: 0, which constrains nothing" do
      assert decode(%{a: T.string(min: 0), b: T.integer()}, %{"a" => "", "b" => 1}) ==
               {:ok, %{a: "", b: 1}}
    end
  end

  describe "wire names" do
    test "rename_all: reads the renamed key, and only that one" do
      schema = T.object(%{first_name: T.string(), id: T.integer()}, rename_all: :camelCase)

      assert decode(schema, %{"firstName" => "Ada", "id" => 1}) ==
               {:ok, %{first_name: "Ada", id: 1}}

      assert codes(schema, %{"first_name" => "Ada", "id" => 1}) == [{[:first_name], :required}]
    end

    test "from: overrides it for one field" do
      schema =
        T.object(%{first_name: T.string(from: "given_name"), last_name: T.string()},
          rename_all: :camelCase
        )

      assert decode(schema, %{"given_name" => "Ada", "lastName" => "L"}) ==
               {:ok, %{first_name: "Ada", last_name: "L"}}
    end

    test "to: on its own renames both directions, so decoding reads it too" do
      schema = %{a: T.string(to: "A")}

      assert decode(schema, %{"A" => "1"}) == {:ok, %{a: "1"}}
      assert codes(schema, %{"a" => "1"}) == [{[:a], :required}]
    end

    test "both of them, differing, is a field that reads one name and writes another" do
      schema = %{a: T.string(from: "old", to: "new")}

      assert decode(schema, %{"old" => "1"}) == {:ok, %{a: "1"}}
      assert codes(schema, %{"new" => "1"}) == [{[:a], :required}]
    end

    test "the error path names the field, not the wire key" do
      schema = T.object(%{first_name: T.string(min: 1)}, rename_all: :camelCase)

      assert code(schema, %{"firstName" => ""}) == {[:first_name], :min}
    end

    test "keys: :string decodes to the field name as a string" do
      schema = T.object(%{first_name: T.string()}, rename_all: :camelCase, keys: :string)

      assert decode(schema, %{"firstName" => "Ada"}) == {:ok, %{"first_name" => "Ada"}}
      assert code(schema, %{"firstName" => 1}) == {["first_name"], :type}
      assert code(schema, %{}) == {["first_name"], :required}
    end

    test "keys: :string goes with optional, default and the unknown-key policies" do
      fields = %{
        first_name: T.string(),
        age: T.optional(T.integer()),
        role: T.string(default: "x")
      }

      assert decode(T.object(fields, keys: :string), %{"first_name" => "Ada"}) ==
               {:ok, %{"first_name" => "Ada", "role" => "x"}}

      assert decode(T.object(fields, keys: :string, unknown: :keep), %{
               "first_name" => "A",
               "b" => 2
             }) ==
               {:ok, %{"first_name" => "A", "role" => "x", "b" => 2}}

      assert codes(T.object(fields, keys: :string, unknown: :error), %{
               "first_name" => "A",
               "b" => 2
             }) ==
               [{[], :unknown_key}]
    end

    test "renaming reaches the unknown-key policies, which see wire keys" do
      fields = %{first_name: T.string()}

      assert decode(T.object(fields, rename_all: :camelCase, unknown: :keep), %{
               "firstName" => "A",
               "x" => 1
             }) ==
               {:ok, %{:first_name => "A", "x" => 1}}

      assert decode(T.object(fields, rename_all: :camelCase, unknown: :error), %{
               "firstName" => "A"
             }) ==
               {:ok, %{first_name: "A"}}

      assert codes(T.object(fields, rename_all: :camelCase, unknown: :error), %{
               "firstName" => "A",
               "first_name" => 1
             }) ==
               [{[], :unknown_key}]
    end
  end

  describe "string field names" do
    test "an object named with strings decodes to string keys, and nests" do
      schema = {:object, %{"a" => T.string(), "in" => {:object, %{"n" => T.integer()}, []}}, []}

      assert decode(schema, %{"a" => "x", "in" => %{"n" => 1}}) ==
               {:ok, %{"a" => "x", "in" => %{"n" => 1}}}
    end

    test "keys: :atom is how you ask for atoms, and nothing else interns one" do
      schema = {:object, %{"a" => T.string()}, [keys: :atom]}

      assert decode(schema, %{"a" => "x"}) == {:ok, %{a: "x"}}
    end

    test "renaming, optional and default all read the same as they do with atom names" do
      schema =
        {:object,
         %{
           "first_name" => T.string(),
           "id" => T.string(from: "userId"),
           "nick" => T.optional(T.string()),
           "role" => T.string(default: "member")
         }, [rename_all: :camelCase]}

      assert decode(schema, %{"firstName" => "Ada", "userId" => "1"}) ==
               {:ok, %{"first_name" => "Ada", "id" => "1", "role" => "member"}}
    end

    test "the error path names the field, which is now a string" do
      assert code({:object, %{"a" => T.integer()}, []}, %{"a" => "x"}) == {["a"], :type}
    end

    test "unknown: :keep never carries a name a field already claims" do
      # "b" is what the field reads and "a" is where it lands, so a wire "a" has nowhere to go
      # that would not shadow the field. It is dropped rather than quietly winning.
      schema = {:object, %{"a" => T.string(from: "b")}, [unknown: :keep]}

      assert decode(schema, %{"b" => "x", "a" => 1}) == {:ok, %{"a" => "x"}}
      assert decode(schema, %{"b" => "x", "z" => 1}) == {:ok, %{"a" => "x", "z" => 1}}
    end

    test "unknown: :error and :strip see wire keys as they always did" do
      strict = {:object, %{"a" => T.integer()}, [unknown: :error]}

      assert decode(strict, %{"a" => 1}) == {:ok, %{"a" => 1}}
      assert code(strict, %{"a" => 1, "z" => 2}) == {[], :unknown_key}

      assert decode({:object, %{"a" => T.integer()}, []}, %{"a" => 1, "z" => 2}) ==
               {:ok, %{"a" => 1}}
    end
  end

  describe "the unknown-key policy" do
    test "strip is the default, and says nothing" do
      assert decode(%{a: T.string()}, %{"a" => "1", "b" => 2}) == {:ok, %{a: "1"}}
    end

    test "keep passes the extras through under their wire keys" do
      schema = T.object(%{a: T.string()}, unknown: :keep)
      assert decode(schema, %{"a" => "1", "b" => 2}) == {:ok, %{:a => "1", "b" => 2}}
    end

    test "error names them, one under :halt and all of them under :collect" do
      schema = T.object(%{a: T.string()}, unknown: :error)

      assert decode(schema, %{"a" => "1"}) == {:ok, %{a: "1"}}
      assert codes(schema, %{"a" => "1", "c" => 1, "b" => 2}) == [{[], :unknown_key}]

      assert codes(schema, %{"a" => "1", "c" => 1, "b" => 2}, on_error: :collect) ==
               [{[], :unknown_key}, {[], :unknown_key}]
    end

    test "error measures against the wire keys fields read, not their decoded or output names" do
      # The only key `x` reads is "wireX"; the decoded key "x" and the write key are not names the
      # wire may carry, so "x" on the wire is unknown -- not silently accepted and dropped.
      schema = T.object(%{"x" => T.integer(from: "wireX")}, unknown: :error)

      assert {:error, [error]} = decode(schema, %{"wireX" => 1, "x" => 999})
      assert {error.code, error.meta} == {:unknown_key, %{key: "x"}}
      assert decode(schema, %{"wireX" => 1}) == {:ok, %{"x" => 1}}
    end

    # A struct is a map, and a plain object handed one reads it as its fields: the `:__struct__`
    # tag is not data, so `:keep` does not carry it and `:error` does not report it -- and neither
    # policy raises for want of an `Enumerable`.
    test "a struct is read as its fields, and its tag is neither kept nor unknown" do
      keep = T.object(%{a: T.optional(T.integer())}, unknown: :keep)
      assert decode(keep, %URI{path: "/p"}) == {:ok, Map.from_struct(%URI{path: "/p"})}

      strict = T.object(%{a: T.optional(T.integer())}, unknown: :error)
      assert {:error, errors} = decode(strict, %URI{}, on_error: :collect)

      assert Enum.map(errors, & &1.meta.key) ==
               %URI{} |> Map.from_struct() |> Map.keys() |> Enum.sort()
    end
  end

  describe "lists" do
    test "elements decode, and errors carry the index" do
      assert decode(T.list(T.integer()), [1, 2]) == {:ok, [1, 2]}
      assert code(T.list(T.integer()), [1, "x"]) == {[1], :type}
      assert code(T.list(T.integer()), "nope") == {[], :type}
    end

    # `is_list/1` is true of `[1 | 2]`, and `length/1` on it raises -- so the list heads check the
    # length in the guard, where a failure is just "not this clause", and an improper list is a
    # type error like any other non-list. Tuples too, whose size check is a length as well.
    test "an improper list is a type error, not a raise" do
      assert code(T.list(T.integer()), [1 | 2]) == {[], :type}
      assert code(T.list(T.integer(), min: 1), [1 | 2]) == {[], :type}
      assert code(T.tuple([T.integer()]), [1 | 2]) == {[], :type}
      assert code(T.tuple([]), [1 | 2]) == {[], :type}
    end

    test "min, max and unique" do
      assert code(T.list(T.integer(), min: 2), [1]) == {[], :min}
      assert code(T.list(T.integer(), max: 1), [1, 2]) == {[], :max}
      assert code(T.list(T.integer(), unique: true), [1, 1]) == {[], :unique}
      assert decode(T.list(T.integer(), unique: false), [1, 1]) == {:ok, [1, 1]}
    end

    test "uniqueness is of the decoded values, not the wire" do
      # Two objects that differ only in a stripped extra key decode to the same value, so a
      # wire-level check would let them through and break the round trip.
      assert code(T.list(%{x: T.integer()}, unique: true), [
               %{"x" => 1, "a" => 1},
               %{"x" => 1, "b" => 2}
             ]) == {[], :unique}

      # An int and a float that decode to the same float collapse the same way.
      assert code(T.list(T.float(), unique: true), [1, 1.0]) == {[], :unique}

      # Genuinely distinct decoded values still pass.
      assert decode(T.list(%{x: T.integer()}, unique: true), [%{"x" => 1}, %{"x" => 2}]) ==
               {:ok, [%{x: 1}, %{x: 2}]}
    end

    test "halt stops at the first bad element, collect reports every one" do
      assert codes(T.list(T.integer()), ["a", "b"]) == [{[0], :type}]

      assert codes(T.list(T.integer()), ["a", "b"], on_error: :collect) ==
               [{[0], :type}, {[1], :type}]
    end
  end

  describe "tuples" do
    test "a fixed-length list decodes to an Elixir tuple" do
      assert decode(T.tuple([T.float(), T.string()]), [1, "a"]) == {:ok, {1.0, "a"}}
    end

    test "a tuple of nothing" do
      assert decode(T.tuple([]), []) == {:ok, {}}
      assert code(T.tuple([]), [1]) == {[], :tuple_size}
      assert code(T.tuple([]), "nope") == {[], :type}
    end

    test "the wrong length, and the wrong shape entirely" do
      assert code(T.tuple([T.float()]), [1, 2]) == {[], :tuple_size}
      assert code(T.tuple([T.float()]), "nope") == {[], :type}
    end

    test "members report their position" do
      schema = T.tuple([T.integer(), T.integer()])
      assert codes(schema, ["a", "b"]) == [{[0], :type}]
      assert codes(schema, ["a", "b"], on_error: :collect) == [{[0], :type}, {[1], :type}]
    end
  end

  describe "map_of" do
    test "values decode, keys stay as they came" do
      assert decode(T.map_of(T.integer()), %{"a" => 1}) == {:ok, %{"a" => 1}}
      assert code(T.map_of(T.integer()), "nope") == {[], :type}
    end

    test "errors carry the key, in both modes" do
      schema = T.map_of(T.integer())
      assert codes(schema, %{"a" => "x", "b" => "y"}) == [{["a"], :type}]

      assert codes(schema, %{"a" => "x", "b" => "y"}, on_error: :collect) ==
               [{["a"], :type}, {["b"], :type}]
    end
  end

  describe "tagged unions" do
    @shapes T.tagged(:type, %{
              "circle" => %{r: T.float()},
              "rect" => %{w: T.float(), h: T.float()}
            })

    test "the tag picks the branch, and the value comes back tagged" do
      assert decode(@shapes, %{"type" => "circle", "r" => 1.0}) == {:ok, {:circle, %{r: 1.0}}}

      assert decode(@shapes, %{"type" => "rect", "w" => 1.0, "h" => 2.0}) ==
               {:ok, {:rect, %{w: 1.0, h: 2.0}}}
    end

    test "a tag nobody declared, a tag that is not there, and a value that is not a map" do
      assert code(@shapes, %{"type" => "tri"}) == {[:type], :unknown_tag}
      assert code(@shapes, %{"r" => 1.0}) == {[:type], :required}
      assert code(@shapes, "nope") == {[], :type}
    end

    test "a branch's errors are at the branch's own path, with no segment for the tag" do
      assert code(@shapes, %{"type" => "circle", "r" => "x"}) == {[:r], :type}

      assert codes(@shapes, %{"type" => "rect"}, on_error: :collect) ==
               [{[:h], :required}, {[:w], :required}]
    end

    test "the tag is not an unknown key to the branch that has to look" do
      strict = T.tagged(:type, %{"circle" => T.object(%{r: T.float()}, unknown: :error)})

      assert decode(strict, %{"type" => "circle", "r" => 1.0}) == {:ok, {:circle, %{r: 1.0}}}
      assert code(strict, %{"type" => "circle", "r" => 1.0, "x" => 1}) == {[], :unknown_key}
    end

    test "a branch with no fields of its own is the tag and nothing else" do
      empty = T.tagged(:type, %{"nothing" => T.object(%{})})

      assert decode(empty, %{"type" => "nothing"}) == {:ok, {:nothing, %{}}}
      assert decode(empty, %{"type" => "nothing", "x" => 1}) == {:ok, {:nothing, %{}}}
      assert code(empty, %{"type" => "something"}) == {[:type], :unknown_tag}
    end

    test "and a branch that keeps unknown keys does not keep the tag" do
      keeps = T.tagged(:type, %{"circle" => T.object(%{r: T.float()}, unknown: :keep)})

      assert decode(keeps, %{"type" => "circle", "r" => 1.0, "x" => 1}) ==
               {:ok, {:circle, %{:r => 1.0, "x" => 1}}}
    end

    test "content: puts the branch under its own key, so a branch can be any schema" do
      adjacent = T.tagged(:kind, %{"n" => T.integer(), "s" => T.string()}, content: :value)

      assert decode(adjacent, %{"kind" => "n", "value" => 1}) == {:ok, {:n, 1}}
      assert decode(adjacent, %{"kind" => "s", "value" => "x"}) == {:ok, {:s, "x"}}
      assert code(adjacent, %{"kind" => "n"}) == {[:value], :required}
      assert code(adjacent, %{"kind" => "n", "value" => "x"}) == {[:value], :type}
      assert code(adjacent, %{"kind" => "z", "value" => 1}) == {[:kind], :unknown_tag}
    end

    test "a branch can recurse, to any depth" do
      tree =
        T.tagged(:type, %{
          "leaf" => %{v: T.integer()},
          "node" => %{kids: T.list(T.ref(:root))}
        })

      wire = %{"type" => "node", "kids" => [%{"type" => "leaf", "v" => 1}]}

      assert decode(tree, wire) == {:ok, {:node, %{kids: [{:leaf, %{v: 1}}]}}}

      assert code(tree, %{"type" => "node", "kids" => [%{"type" => "leaf"}]}) ==
               {[:kids, 0, :v], :required}
    end
  end

  describe "untagged unions" do
    @either T.union([T.integer(), T.string(min: 1)], tag: :none)

    test "the first variant that takes the value wins" do
      assert decode(@either, 1) == {:ok, 1}
      assert decode(@either, "x") == {:ok, "x"}
    end

    test "the order you wrote them in is part of the schema" do
      first = T.union([T.enum([:a]), T.string(min: 1)], tag: :none)
      second = T.union([T.string(min: 1), T.enum([:a])], tag: :none)

      assert decode(first, "a") == {:ok, :a}
      assert decode(second, "a") == {:ok, "a"}
    end

    test "when none of them takes it, one error says so, whatever the mode" do
      assert codes(@either, true) == [{[], :no_variant}]
      assert codes(@either, true, on_error: :collect) == [{[], :no_variant}]
      assert codes(@either, "", on_error: :collect) == [{[], :no_variant}]
    end

    test "a variant's own errors are never reported, because you did not choose it" do
      assert {:error, [error]} = decode(@either, true)
      assert error.meta == %{value: true, tried: 2}
    end

    test "nested in a container, with the path to it" do
      assert decode(%{v: T.list(@either)}, %{"v" => [1, "x"]}) == {:ok, %{v: [1, "x"]}}
      assert code(%{v: T.list(@either)}, %{"v" => [1, true]}) == {[:v, 1], :no_variant}
    end
  end

  describe "recursion" do
    test "a ref on a cycle decodes to any depth" do
      tree = %{value: T.integer(), children: T.list(T.ref(:root))}

      data = %{
        "value" => 1,
        "children" => [%{"value" => 2, "children" => []}]
      }

      assert decode(tree, data) == {:ok, %{value: 1, children: [%{value: 2, children: []}]}}

      assert code(tree, %{"value" => 1, "children" => [%{"children" => []}]}) ==
               {[:children, 0, :value], :required}
    end

    test "mutual recursion works the same way" do
      schema =
        Rupa.T.object(%{a: T.ref(:one)},
          defs: %{one: %{b: T.optional(T.ref(:two))}, two: %{c: T.optional(T.ref(:one))}}
        )

      assert decode(schema, %{"a" => %{"b" => %{"c" => %{}}}}) ==
               {:ok, %{a: %{b: %{c: %{}}}}}
    end
  end

  describe "on_error" do
    test "collect keeps going across sibling fields" do
      schema = %{a: T.integer(), b: T.integer(), c: T.integer()}

      assert codes(schema, %{"a" => "x", "b" => "y"}, on_error: :collect) ==
               [{[:a], :type}, {[:b], :type}, {[:c], :required}]
    end

    test "halt is the default, and gives exactly one" do
      schema = %{a: T.integer(), b: T.integer()}
      assert length(elem(decode(schema, %{}), 1)) == 1
    end

    test "anything else is a caller mistake" do
      codec = Rupa.compile!(%{})

      assert_raise ArgumentError, ~r/on_error: expects :halt or :collect/, fn ->
        Rupa.decode(codec, %{}, on_error: :whatever)
      end
    end
  end
end

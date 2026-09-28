defmodule Rupa.SchemaTest do
  use ExUnit.Case, async: true

  alias Rupa.Schema
  alias Rupa.T

  doctest Rupa.Schema

  defp codes(schema) do
    assert {:error, errors} = Schema.validate(schema)
    Enum.map(errors, &{&1.path, &1.code})
  end

  defp code(schema) do
    assert [pair] = codes(schema)
    pair
  end

  describe "normalize/1" do
    test "leaves a canonical term alone" do
      for schema <- [
            T.string(min: 1),
            T.literal("a"),
            T.ref(:root),
            T.enum([:a]),
            T.object(%{a: T.string()}),
            T.list(T.string()),
            T.map_of(T.string()),
            T.optional(T.string()),
            T.nullable(T.string()),
            T.tuple([T.string()]),
            T.union([T.string(), T.integer()], tag: :none),
            T.tagged(:type, %{"a" => %{}})
          ] do
        assert Schema.normalize(schema) == schema
      end
    end

    test "does not mistake a struct for a bare map" do
      assert Schema.normalize(~D[2026-09-16]) == ~D[2026-09-16]
    end

    test "hands back anything it does not recognise" do
      assert Schema.normalize(:nope) == :nope
      assert Schema.normalize({:string, :nope}) == {:string, :nope}
    end

    test "sorts options, including entries that are not pairs" do
      assert Schema.normalize({:string, [:bogus, {:min, 1}, {:max, 2}]}) ==
               {:string, [:bogus, max: 2, min: 1]}
    end
  end

  describe "walk/2" do
    test "rewrites children before their parent" do
      seen = fn node -> send(self(), node) && node end

      Schema.walk(T.list(T.string()), seen)
      assert_received {:string, []}
      assert_received {:list, {:string, []}, []}
    end

    test "reaches every kind that holds schemas" do
      schema =
        T.object(
          %{
            branch: T.tagged(:type, %{"a" => %{n: T.integer()}}),
            pair: T.tuple([T.integer()]),
            any: T.union([T.integer(), T.boolean()], tag: :none),
            values: T.map_of(T.integer()),
            maybe: T.optional(T.nullable(T.integer())),
            name: T.literal(1),
            link: T.ref(:tree)
          },
          defs: %{tree: T.integer()}
        )

      widened =
        Schema.walk(schema, fn
          {:integer, opts} -> {:float, opts}
          node -> node
        end)

      refute widened |> inspect() |> String.contains?("integer")
      assert widened |> inspect() |> String.contains?("float")
    end

    test "leaves nodes it cannot descend into" do
      assert Schema.walk({:object, %{a: :junk}, []}, & &1) == {:object, %{a: :junk}, []}
      assert Schema.walk({:object, %{}, :bogus}, & &1) == {:object, %{}, :bogus}
      assert Schema.walk({:string, :bogus}, & &1) == {:string, :bogus}
    end

    test "normalizes first, so a bare map is an object the function gets to see" do
      camel = fn
        {:object, fields, opts} -> {:object, fields, Keyword.put(opts, :rename_all, :camelCase)}
        node -> node
      end

      assert Schema.walk(%{first_name: T.string(), addr: %{post_code: T.string()}}, camel) ==
               T.object(
                 %{
                   first_name: T.string(),
                   addr: T.object(%{post_code: T.string()}, rename_all: :camelCase)
                 },
                 rename_all: :camelCase
               )
    end
  end

  describe "validate/1 on a well-formed schema" do
    test "returns the canonical term" do
      assert {:ok, {:object, %{name: {:string, [min: 1]}}, []}} =
               Schema.validate(%{name: T.string(min: 1)})
    end

    test "accepts the whole vocabulary" do
      schema =
        T.object(
          %{
            id: T.uuid(),
            age: T.optional(T.integer(gte: 0, lte: 150)),
            nickname: T.nullable(T.string()),
            role: T.enum([:admin, :member], default: :member),
            version: T.literal("v2"),
            scores: T.list(T.float(gt: 0), min: 1, max: 5, unique: true),
            counts: T.map_of(T.integer()),
            point: T.tuple([T.float(), T.float()]),
            shape: T.tagged(:type, %{"circle" => %{r: T.float()}}),
            either: T.union([T.integer(), T.boolean()], tag: :none),
            adjacent: T.tagged(:kind, %{"n" => T.integer()}, content: :value),
            children: T.list(T.ref(:root)),
            tree: T.ref(:tree),
            flag: T.boolean(),
            nothing: T.null(),
            when: T.datetime(),
            code: T.string(len: 2, pattern: "^[A-Z]{2}$")
          },
          rename_all: :camelCase,
          unknown: :error,
          keys: :atom,
          defs: %{tree: %{value: T.integer(), children: T.list(T.ref(:tree))}}
        )

      assert {:ok, ^schema} = Schema.validate(schema)
    end

    test "accepts the same defs entry declared twice with the same schema" do
      inner = T.object(%{a: T.ref(:shared)}, defs: %{shared: T.string()})
      assert {:ok, _schema} = Schema.validate(T.object(%{b: inner}, defs: %{shared: T.string()}))
    end
  end

  describe "validate/1 reports the kind" do
    test "unknown_type for anything that is not a schema" do
      assert code(:nope) == {[], :unknown_type}
      assert code({:string, :bogus}) == {[], :unknown_type}
      assert code(%{a: :nope}) == {[:a], :unknown_type}
      assert code(%{a: {:optional, T.string(), :bogus}}) == {[:a], :unknown_type}
    end

    test "a malformed payload is reported, not a crash in the defs traversal" do
      # These wear a known kind over the wrong payload shape, which the defs traversal used to
      # walk with Map.values/++ before any shape check and raise on. Now it collects no children
      # and check_node/3 reports the kind.
      assert code({:object, [], []}) == {[], :unknown_type}
      assert code({:tagged, [], [tag: :t]}) == {[], :unknown_type}
      assert code({:union, %{}, [tag: :none]}) == {[], :unknown_type}
    end
  end

  describe "validate/1 reports options" do
    test "unknown_option, for a key this kind does not take and for a stray entry" do
      assert code(T.string(gte: 1)) == {[], :unknown_option}
      assert code({:string, [:bogus]}) == {[], :unknown_option}
    end

    test "duplicate_option" do
      assert code({:string, [min: 1, min: 2]}) == {[], :duplicate_option}
    end

    test "invalid_option, per option" do
      assert code(T.string(min: -1)) == {[], :invalid_option}
      assert code(T.integer(gte: "x")) == {[], :invalid_option}
      assert code(T.integer(multiple_of: 0)) == {[], :invalid_option}
      assert code(T.list(T.string(), unique: 1)) == {[], :invalid_option}
      assert code(%{a: T.string(from: :a)}) == {[:a], :invalid_option}
      assert code(T.object(%{}, rename_all: :snake)) == {[], :invalid_option}
      assert code(T.object(%{}, unknown: :bogus)) == {[], :invalid_option}
      assert code(T.object(%{}, keys: :binary)) == {[], :invalid_option}
      assert code(T.object(%{}, defs: [])) == {[], :invalid_option}
      assert code(T.string(pattern: ~r/x/)) == {[], :invalid_option}

      assert {[], :invalid_option} in codes(T.tagged(:t, %{"a" => %{}}, content: "v"))
    end

    test "invalid_pattern when the regex does not compile" do
      assert code(T.string(pattern: "[")) == {[], :invalid_pattern}
    end

    test "unknown_format" do
      assert code(T.string(format: :ssn)) == {[], :unknown_format}
    end

    test "conflicting_options" do
      assert code(T.string(len: 2, min: 1)) == {[], :conflicting_options}
      assert code(T.string(len: 2, max: 1)) == {[], :conflicting_options}
      assert code(T.integer(gte: 0, gt: 1)) == {[], :conflicting_options}
      assert code(T.integer(lte: 5, lt: 4)) == {[], :conflicting_options}
    end

    test "contradictory_bounds" do
      assert code(T.string(min: 5, max: 2)) == {[], :contradictory_bounds}
      assert code(T.integer(gte: 5, lte: 2)) == {[], :contradictory_bounds}
      assert code(T.float(gt: 5, lt: 2)) == {[], :contradictory_bounds}
      assert code(T.list(T.string(), min: 5, max: 2)) == {[], :contradictory_bounds}
    end

    test "a valid option value passes the catch-all" do
      assert {:ok, _schema} = Schema.validate(%{a: T.string(default: "x")})
    end
  end

  describe "validate/1 rejects functions anywhere in the tree" do
    test "in an option, however deeply buried" do
      assert code(%{a: T.string(default: fn -> 1 end)}) == {[:a], :function_in_schema}
      assert code(%{a: T.string(default: [%{a: {fn -> 1 end}}])}) == {[:a], :function_in_schema}
    end

    test "inside defs, reported once, at the node that holds it" do
      schema = T.object(%{}, defs: %{a: %{b: T.string(default: fn -> 1 end)}})
      assert codes(schema) == [{[:defs, :a, :b], :function_in_schema}]
    end
  end

  describe "validate/1 reports objects and refs" do
    test "field names are atoms or strings, and nothing else" do
      assert {:ok, _schema} = Schema.validate({:object, %{"a" => T.string()}, []})
      assert code({:object, %{1 => T.string()}, []}) == {[], :invalid_field_name}
    end

    test "reserved_field_name: __struct__ cannot become a decoded atom key" do
      assert code(%{__struct__: T.string()}) == {[], :reserved_field_name}

      assert code({:object, %{"__struct__" => T.string()}, [keys: :atom]}) ==
               {[], :reserved_field_name}

      assert code(%{a: %{__struct__: T.string()}}) == {[:a], :reserved_field_name}

      # As a string key it is only a string.
      assert {:ok, _schema} = Schema.validate({:object, %{"__struct__" => T.string()}, []})
    end

    test "mixed_field_names" do
      assert code({:object, %{:a => T.string(), "b" => T.string()}, []}) ==
               {[], :mixed_field_names}
    end

    test "invalid_def_name" do
      assert code({:object, %{}, [defs: %{"a" => T.string()}]}) == {[], :invalid_def_name}
    end

    test "reserved_def_name: :root is the schema itself, so a defs: entry cannot take it" do
      assert code(T.object(%{a: T.ref(:root)}, defs: %{root: T.string()})) ==
               {[], :reserved_def_name}
    end

    # Every string a schema carries into the wire is rendered to JSON, or interned, while it is
    # staged; a binary that is not UTF-8 would raise out of that inside compile/2. So it is refused
    # here, with its path, under the code the JSON boundary uses for a value at run time.
    test "invalid_utf8 for any static string the wire will carry" do
      assert code(T.literal(<<255>>)) == {[], :invalid_utf8}
      assert code(T.enum(["ok", <<255>>])) == {[], :invalid_utf8}
      assert code({:object, %{<<255>> => T.integer()}, []}) == {[], :invalid_utf8}
      assert code(T.tagged(:k, %{<<255>> => %{a: T.integer()}})) == {[], :invalid_utf8}
      assert code(%{a: T.string(from: <<255>>)}) == {[:a], :invalid_utf8}
      assert code(%{a: T.string(to: <<255>>)}) == {[:a], :invalid_utf8}

      # A default is a value of the field's type, not a fragment of the wire, so it is not held
      # to this: a string field takes any binary.
      assert {:ok, _schema} = Schema.validate(%{a: T.string(default: <<255>>)})
    end

    test "unresolved_ref" do
      assert code(T.ref(:missing)) == {[], :unresolved_ref}
      assert code({:ref, "root", []}) == {[], :unresolved_ref}
    end

    test "duplicate_def" do
      inner = T.object(%{a: T.ref(:shared)}, defs: %{shared: T.string()})
      schema = T.object(%{b: inner}, defs: %{shared: T.integer()})
      assert {[:defs, :shared], :duplicate_def} in codes(schema)
    end
  end

  describe "validate/1 reports optional and nullable" do
    test "misplaced_optional anywhere but an object field" do
      assert code(T.list(T.optional(T.string()))) == {[:of], :misplaced_optional}
      assert code(T.optional(T.string())) == {[], :misplaced_optional}
      assert code(%{a: T.optional(T.optional(T.string()))}) == {[:a], :misplaced_optional}
    end

    test "nested_nullable, and a nullable null is the same mistake" do
      assert code(T.nullable(T.nullable(T.string()))) == {[], :nested_nullable}
      assert code(T.nullable(T.null())) == {[], :nested_nullable}
      assert code(%{a: T.list(T.nullable(T.null()))}) == {[:a, :of], :nested_nullable}
    end

    test "nested_default" do
      assert code(%{a: T.optional(T.string(default: "x"))}) == {[:a], :nested_default}
      assert code(%{a: T.optional(T.list(T.string(), default: []))}) == {[:a], :nested_default}
    end

    test "an optional field is fine, and so is a default on the optional itself" do
      assert {:ok, _schema} = Schema.validate(%{a: T.optional(T.string(), default: "x")})
    end
  end

  describe "validate/1 reports wire names" do
    test "misplaced_rename anywhere but the field's own term" do
      assert code(T.string(from: "a")) == {[], :misplaced_rename}
      assert code(T.list(T.string(to: "a"))) == {[:of], :misplaced_rename}
      assert code(%{a: T.optional(T.string(from: "b"))}) == {[:a], :misplaced_rename}
      assert code(%{a: T.nullable(T.string(to: "b"))}) == {[:a], :misplaced_rename}

      assert code(T.object(%{a: T.ref(:one)}, defs: %{one: T.string(from: "b")})) ==
               {[:defs, :one], :misplaced_rename}
    end

    test "both options are reported, not just the first" do
      assert codes(T.string(from: "a", to: "b")) ==
               [{[], :misplaced_rename}, {[], :misplaced_rename}]
    end

    test "on a field's own term they are fine, T.optional/2 included" do
      assert {:ok, _schema} = Schema.validate(%{a: T.string(from: "b", to: "c")})
      assert {:ok, _schema} = Schema.validate(%{a: T.optional(T.string(), from: "b")})
      assert {:ok, _schema} = Schema.validate(%{a: T.nullable(T.string(), to: "c")})
    end

    test "misplaced_default anywhere a field's absence cannot be what fires it" do
      assert code(T.string(default: "x")) == {[], :misplaced_default}
      assert code(T.list(T.string(default: "x"))) == {[:of], :misplaced_default}
      assert code(T.map_of(T.integer(default: 0))) == {[:of], :misplaced_default}
      assert code(T.tuple([T.string(default: "x")])) == {[0], :misplaced_default}

      assert code(T.union([T.string(default: "x"), T.integer()], tag: :none)) ==
               {[0], :misplaced_default}

      assert code(T.tagged(:k, %{"a" => T.object(%{}, default: %{})})) ==
               {["a"], :misplaced_default}

      assert code(T.object(%{a: T.ref(:one)}, defs: %{one: T.string(default: "x")})) ==
               {[:defs, :one], :misplaced_default}
    end

    test "a default on a field's own term is fine, wrapped or not" do
      assert {:ok, _schema} = Schema.validate(%{a: T.string(default: "x")})
      assert {:ok, _schema} = Schema.validate(%{a: T.optional(T.string(), default: "x")})
      assert {:ok, _schema} = Schema.validate(%{a: T.nullable(T.string(), default: "x")})
    end

    test "a wrapper around junk reports the junk, not the wrapper" do
      assert code(%{a: T.optional(:junk)}) == {[:a], :unknown_type}
    end
  end

  describe "validate/1 reports enums and literals" do
    test "empty_enum" do
      assert code(T.enum([])) == {[], :empty_enum}
    end

    test "invalid_scalar" do
      assert code(T.enum([nil])) == {[], :invalid_scalar}
      assert code(T.enum([%{}])) == {[], :invalid_scalar}
      assert code(T.literal([1])) == {[], :invalid_scalar}
    end

    test "duplicate_enum_value" do
      assert code(T.enum([:a, :a])) == {[], :duplicate_enum_value}
    end

    test "strings, atoms, numbers and booleans are all fine" do
      assert {:ok, _schema} = Schema.validate(T.enum(["a", :b, 1, 2.0, true]))
    end
  end

  describe "validate/1 reports unions" do
    test "untagged_union_needs_opt_in" do
      assert code(T.union([T.integer(), T.string()])) == {[], :untagged_union_needs_opt_in}

      assert code(T.union([T.integer(), T.string()], tag: :sort)) ==
               {[], :untagged_union_needs_opt_in}
    end

    test "union_too_small" do
      assert code(T.union([T.integer()], tag: :none)) == {[], :union_too_small}
    end

    test "members are checked at their index" do
      assert code(T.union([T.integer(), T.string(format: :ssn)], tag: :none)) ==
               {[1], :unknown_format}
    end
  end

  describe "validate/1 reports tagged unions" do
    test "invalid_tag" do
      assert code({:tagged, %{"a" => T.object(%{})}, []}) == {[], :invalid_tag}
      assert code(T.tagged(:none, %{"a" => T.object(%{})})) == {[], :invalid_tag}
      assert code(T.tagged("type", %{"a" => T.object(%{})})) == {[], :invalid_tag}
    end

    test "empty_branches" do
      assert code(T.tagged(:type, %{})) == {[], :empty_branches}
    end

    test "invalid_branch_name" do
      assert {[], :invalid_branch_name} in codes(T.tagged(:type, %{a: T.object(%{})}))
    end

    test "untagged_branch, unless the union is adjacently tagged" do
      assert code(T.tagged(:type, %{"a" => T.string()})) == {["a"], :untagged_branch}
      assert {:ok, _s} = Schema.validate(T.tagged(:type, %{"a" => T.string()}, content: :value))
    end

    test "tag_content_conflict when the tag and content keys are the same" do
      assert code(T.tagged(:k, %{"a" => T.integer()}, content: :k)) ==
               {[], :tag_content_conflict}

      assert {:ok, _s} =
               Schema.validate(T.tagged(:k, %{"a" => T.integer()}, content: :value))
    end
  end

  describe "validate/1 collects" do
    test "every problem in the tree, sorted by path" do
      schema = %{
        a: T.string(format: :ssn),
        b: T.integer(gte: 5, lte: 2),
        c: %{d: T.enum([])}
      }

      assert codes(schema) == [
               {[:a], :unknown_format},
               {[:b], :contradictory_bounds},
               {[:c, :d], :empty_enum}
             ]
    end

    test "errors from tuples and map_of at their own paths" do
      schema = %{
        pair: T.tuple([T.string(format: :ssn)]),
        values: T.map_of(T.string(format: :ssn))
      }

      assert codes(schema) == [
               {[:pair, 0], :unknown_format},
               {[:values, :of], :unknown_format}
             ]
    end
  end

  describe "validate!/1" do
    test "returns the canonical schema" do
      assert Schema.validate!(%{a: T.string()}) == {:object, %{a: {:string, []}}, []}
    end

    test "raises with every error, and says where each one is" do
      error =
        assert_raise Rupa.SchemaError, fn ->
          Schema.validate!(%{a: T.string(format: :ssn)})
        end

      message = Exception.message(error)
      assert message =~ "schema is not well formed"
      assert message =~ "at /a: :ssn is not one of Rupa's built-in formats"
    end

    test "says at the root when the path is empty" do
      error = assert_raise Rupa.SchemaError, fn -> Schema.validate!(:nope) end
      assert Exception.message(error) =~ "at the root: :nope is not a Rupa schema"
    end
  end
end

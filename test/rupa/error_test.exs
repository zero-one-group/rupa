defmodule Rupa.ErrorTest do
  use ExUnit.Case, async: true

  alias Rupa.Error

  doctest Rupa.Error

  defp said(code, meta \\ %{}) do
    [] |> Error.new(code, meta) |> Error.message()
  end

  describe "message/1" do
    test "renders every code Rupa.Schema can produce" do
      assert said(:unknown_type, %{value: :nope}) == ":nope is not a Rupa schema"
      assert said(:unknown_option, %{option: :gte, kind: :string}) =~ "string does not take"

      assert said(:invalid_option, %{option: :min, value: -1, expected: "a count"}) ==
               ":min expects a count, got -1"

      assert said(:duplicate_option, %{option: :min}) == ":min is given more than once"

      assert said(:conflicting_options, %{options: [:len, :min]}) ==
               ":len and :min cannot be combined"

      assert said(:contradictory_bounds, %{options: [:min, :max]}) ==
               "no value satisfies both :min and :max"

      assert said(:function_in_schema, %{option: :default}) =~ "data all the way down"
      assert said(:unknown_format, %{format: :ssn}) =~ "built-in formats"

      assert said(:invalid_pattern, %{reason: "boom at 1"}) ==
               "pattern does not compile: boom at 1"

      assert said(:invalid_field_name, %{field: 1}) =~ "object field names are atoms or strings"
      assert said(:invalid_def_name, %{name: "a"}) =~ "defs: names are atoms"
      assert said(:mixed_field_names) =~ "all atoms or all strings"
      assert said(:unresolved_ref, %{name: :tree}) == ":tree has no entry in defs:"
      assert said(:duplicate_def, %{name: :tree}) =~ "declares :tree twice"
      assert said(:misplaced_optional) =~ "only means anything on an object field"
      assert said(:nested_nullable) =~ "cannot wrap another"
      assert said(:nested_default) =~ "belongs on the outer term"
      assert said(:empty_enum) == "an enum needs at least one value"
      assert said(:invalid_scalar, %{value: nil}) =~ "got nil"
      assert said(:duplicate_enum_value, %{value: :a}) == ":a is listed twice"
      assert said(:untagged_union_needs_opt_in) =~ "tag: :none"
      assert said(:union_too_small) == "a union needs at least two variants"
      assert said(:invalid_tag, %{value: nil}) =~ "tag: expects an atom other than :none"
      assert said(:untagged_branch) =~ "every branch is an object"
      assert said(:empty_branches) == "a tagged union needs at least one branch"
      assert said(:invalid_branch_name, %{value: :a}) == "tag values are strings, got :a"
      assert said(:misplaced_rename, %{option: :from}) =~ "belongs on the field's own term"
      assert said(:misplaced_default) =~ "can never fire here"
      assert said(:reserved_def_name, %{name: :root}) =~ ":root is the name the schema itself"
      assert said(:reserved_field_name, %{field: :__struct__}) =~ "would pass for a struct"

      assert said(:duplicate_wire_key, %{key: "id"}) ==
               ~s(two fields map to the wire key "id")

      assert said(:struct_keys, %{names: :atom}) =~ "keys: :string cannot hold with it"
      assert said(:struct_keys, %{names: :string}) =~ "string-named object needs keys: :atom"
      assert said(:struct_keeps_unknown) =~ "nowhere to put the keys unknown: :keep would carry"
      assert said(:not_a_struct, %{module: URI}) =~ "URI is not one"

      assert said(:struct_field_missing, %{module: URI, keys: [:a, :b]}) ==
               "URI's fields do not include :a, :b; re-run mix rupa.gen.struct, or fix the schema"

      assert said(:circular_ref, %{name: :root}) =~ "a cycle of refs with no schema in it"
      assert said(:invalid_default, %{value: "x"}) =~ ~s("x" is not a valid value for this field)
      assert said(:recursive_default, %{value: %{}}) =~ "one more level of itself"

      assert said(:unsupported_format_constraint, %{format: :date_time, checks: [:len]}) =~
               "len check on the date_time format cannot hold"

      assert said(:tag_content_conflict, %{tag: :k}) =~ "tag: and content: are both :k"

      assert said(:tag_wire_conflict, %{key: "type"}) =~
               ~s("type", which is the tag's own wire key)
    end
  end

  describe "message/1, for the codes decoding produces" do
    test "renders every one" do
      assert said(:type, %{expected: :string, value: 1}) == "expected a string, got 1"
      assert said(:type, %{expected: :object, value: 1}) == "expected an object, got 1"
      assert said(:type, %{expected: :array, value: 1}) == "expected an array, got 1"
      assert said(:type, %{expected: :integer, value: "x"}) == ~s(expected an integer, got "x")
      assert said(:required) == "is required"

      assert said(:min, %{min: 1, unit: "characters"}) == "must have at least 1 characters"
      assert said(:max, %{max: 5, unit: "items"}) == "must have at most 5 items"
      assert said(:len, %{len: 2}) == "must be exactly 2 characters"
      assert said(:pattern, %{pattern: "^a$"}) == "must match ^a$"
      assert said(:format, %{format: :uuid}) == "is not a valid uuid"

      assert said(:gte, %{gte: 0}) == "must be at least 0"
      assert said(:gt, %{gt: 0}) == "must be greater than 0"
      assert said(:lte, %{lte: 9}) == "must be at most 9"
      assert said(:lt, %{lt: 9}) == "must be less than 9"
      assert said(:multiple_of, %{multiple_of: 2}) == "must be a multiple of 2"
      assert said(:unique) == "must not repeat a value"

      assert said(:invalid_utf8, %{value: <<255>>}) =~ "not valid UTF-8"
      assert said(:duplicate_key, %{key: "1"}) =~ ~s(two keys render to the name "1")
      assert said(:unsupported_key, %{key: {1, 2}}) =~ "{1, 2} has no string form"
      assert said(:unsupported_value, %{value: {1, 2}}) =~ "{1, 2} has no JSON form"

      assert said(:const, %{value: "x", allowed: [:a, :b]}) ==
               ~s(must be one of :a, :b, got "x")

      assert said(:unknown_key, %{key: "extra"}) =~ ~s("extra" is not a key)
      assert said(:tuple_size, %{expected: 2, actual: 3}) == "expected 2 elements, got 3"

      assert said(:unknown_tag, %{value: "tri", allowed: ["circle"]}) ==
               ~s("tri" is not a branch of this union, which has "circle")

      assert said(:no_variant, %{value: true, tried: 2}) ==
               "none of the 2 variants of this union accepted true"

      assert said(:ambiguous_const, %{values: ["a", :a]}) =~ "decode from the same wire value"
    end
  end

  describe "message/1, for the codes reading a JSON Schema produces" do
    test "renders every one" do
      assert said(:unsupported_keyword, %{keyword: "allOf"}) =~
               "allOf has no equivalent in Rupa's vocabulary"

      assert said(:unsupported_schema, %{value: true}) == "true is not a schema Rupa can read"

      assert said(:unsupported_type_union, %{types: ["string", "integer"]}) =~
               ~s(each of "string", "integer" would need its own constraints)

      assert said(:untyped_schema) =~ "constrains one kind of value and passes every other"
      assert said(:unsupported_mixed_object) =~ "an object and a map-of at once"
      assert said(:unsupported_open_tuple, %{size: 2}) =~ "a Rupa tuple is exactly 2 long"

      assert said(:unsupported_bare_required, %{name: "foo"}) =~
               ~s("foo" is required but not described)

      assert said(:unsupported_ref, %{ref: "http://x"}) =~ "which is #/$defs/<name> and nothing"

      assert said(:unsupported_recursive_ref, %{name: "s"}) =~
               ~s("s" is on a cycle, and a recursive ref needs a name)

      assert said(:unsupported_ref_siblings) =~ "a $ref beside other keywords would drop them"

      assert said(:invalid_keyword, %{keyword: "required"}) =~
               "the required keyword does not hold"
    end
  end

  describe "pointer/1" do
    test "escapes the two characters RFC 6901 reserves" do
      assert Error.pointer(Error.new(["a/b", "c~d"], :unknown_type)) == "/a~1b/c~0d"
    end

    test "walks atoms, strings and integers alike" do
      assert Error.pointer(Error.new([:addresses, 0, "circle"], :unknown_type)) ==
               "/addresses/0/circle"
    end

    # A map_of key from an Elixir term can be anything; the pointer says what it was rather than
    # raising inside the exception that is trying to report it.
    test "a segment with no string of its own is inspected, nil and booleans included" do
      assert Error.pointer(Error.new([:by, {1, 2}], :type)) == "/by/{1, 2}"
      assert Error.pointer(Error.new([nil, true, 1.5], :type)) == "/nil/true/1.5"
      assert Error.pointer(Error.new([%{"a/b" => 1}], :type)) == ~s(/%{"a~1b" => 1})

      codec = Rupa.compile!(Rupa.T.map_of(Rupa.T.integer()))

      assert_raise Rupa.EncodeError, ~r|/\{1, 2\} .*has no string form|, fn ->
        Rupa.encode_json!(codec, %{{1, 2} => 3})
      end
    end
  end
end

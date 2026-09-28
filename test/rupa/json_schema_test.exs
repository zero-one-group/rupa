defmodule Rupa.JsonSchemaTest do
  use ExUnit.Case, async: true

  alias Rupa.JsonSchema
  alias Rupa.T

  doctest Rupa.JsonSchema

  defp out(schema) do
    schema |> JsonSchema.encode!() |> Map.delete("$schema")
  end

  defp code(document) do
    assert {:error, [error | _rest]} = JsonSchema.decode(document)
    {error.path, error.code}
  end

  # What `encode/1` writes, `decode/1` reads back to a schema that writes the same document. It
  # is not the identity on the *schema* — an atom-named object comes back string-named, because
  # that is the whole point — so the document is what closes.
  defp closes(schema) do
    document = JsonSchema.encode!(schema)

    assert {:ok, back} = JsonSchema.decode(document)
    assert JsonSchema.encode!(back) == document

    back
  end

  describe "encode/1, scalars" do
    test "each kind and its own bounds" do
      assert out(T.string(min: 1, max: 5)) == %{
               "type" => "string",
               "minLength" => 1,
               "maxLength" => 5
             }

      assert out(T.string(len: 3)) == %{"type" => "string", "minLength" => 3, "maxLength" => 3}
      assert out(T.string(pattern: "^a$")) == %{"type" => "string", "pattern" => "^a$"}

      assert out(T.integer(gte: 0, lte: 9, multiple_of: 3)) == %{
               "type" => "integer",
               "minimum" => 0,
               "maximum" => 9,
               "multipleOf" => 3
             }

      assert out(T.float(gt: 0.0, lt: 1.0)) == %{
               "type" => "number",
               "exclusiveMinimum" => 0.0,
               "exclusiveMaximum" => 1.0
             }

      assert out(T.boolean()) == %{"type" => "boolean"}
      assert out(T.null()) == %{"type" => "null"}
    end

    test "a format writes its hyphenated name" do
      assert out(T.datetime()) == %{"type" => "string", "format" => "date-time"}
      assert out(T.uuid()) == %{"type" => "string", "format" => "uuid"}
    end

    test "one value is a const, several are an enum, and both are the wire values" do
      assert out(T.literal("v2")) == %{"const" => "v2"}
      assert out(T.enum([:admin, :member])) == %{"enum" => ["admin", "member"]}
    end
  end

  describe "encode/1, containers" do
    test "an object writes wire keys, and only the required ones are required" do
      schema =
        T.object(%{first_name: T.string(), nick: T.optional(T.string())}, rename_all: :camelCase)

      assert out(schema) == %{
               "type" => "object",
               "properties" => %{
                 "firstName" => %{"type" => "string"},
                 "nick" => %{"type" => "string"}
               },
               "required" => ["firstName"]
             }
    end

    test "an object with nothing in it says only that it is an object" do
      assert out(T.object(%{})) == %{"type" => "object"}
    end

    test "unknown: :error closes the object, and the others leave it open" do
      assert out(T.object(%{}, unknown: :error)) == %{
               "type" => "object",
               "additionalProperties" => false
             }

      assert out(T.object(%{}, unknown: :keep)) == %{"type" => "object"}
    end

    test "a field carrying from: and to: is described by the key it reads" do
      schema = T.object(%{id: T.string(from: "userId", to: "id")})

      assert out(schema)["properties"] == %{"userId" => %{"type" => "string"}}
    end

    test "a default is written in its wire form, through the field's own encoder" do
      assert out(T.object(%{at: T.datetime(default: ~U[2026-01-01 00:00:00Z])})) == %{
               "type" => "object",
               "properties" => %{
                 "at" => %{
                   "type" => "string",
                   "format" => "date-time",
                   "default" => "2026-01-01T00:00:00Z"
                 }
               }
             }
    end

    test "a default that cannot encode against its own field is a schema error" do
      assert {:error, [error]} = JsonSchema.encode(T.object(%{n: T.integer(default: "nope")}))
      assert {[:n], :invalid_default} = {error.path, error.code}
    end

    test "a default under a migration field spells its keys the way the document reads them" do
      # The document describes the wire the decoder reads, so `properties` names "old"; a default
      # written under "new" would contradict it, and the import would then refuse its own export.
      schema = %{u: T.object(%{x: T.string(from: "old", to: "new")}, default: %{x: "v"})}

      assert out(schema)["properties"]["u"] == %{
               "type" => "object",
               "properties" => %{"old" => %{"type" => "string"}},
               "required" => ["old"],
               "default" => %{"old" => "v"}
             }

      assert {:ok, back} = JsonSchema.decode(out(schema))
      assert {:ok, _codec} = Rupa.compile(back)
    end

    test "lists, tuples and map-ofs" do
      assert out(T.list(T.string(), min: 1, max: 3, unique: true)) == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "minItems" => 1,
               "maxItems" => 3,
               "uniqueItems" => true
             }

      assert out(T.list(T.string(), unique: false)) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert out(T.tuple([T.integer(), T.string()])) == %{
               "type" => "array",
               "prefixItems" => [%{"type" => "integer"}, %{"type" => "string"}],
               "items" => false,
               "minItems" => 2
             }

      # A zero-length tuple has no prefixItems to write (draft 2020-12 forbids an empty one), so it
      # is the array that admits no items: `items: false`, capped at zero.
      assert out(T.tuple([])) == %{"type" => "array", "items" => false, "maxItems" => 0}

      assert out(T.map_of(T.integer())) == %{
               "type" => "object",
               "additionalProperties" => %{"type" => "integer"}
             }
    end

    test "a nullable is an anyOf with null, and so is an untagged union without it" do
      assert out(T.nullable(T.string())) == %{
               "anyOf" => [%{"type" => "string"}, %{"type" => "null"}]
             }

      assert out(T.union([T.integer(), T.string()], tag: :none)) == %{
               "anyOf" => [%{"type" => "integer"}, %{"type" => "string"}]
             }
    end
  end

  describe "encode/1, unions and refs" do
    test "an internally tagged union is a oneOf with the discriminator in each branch" do
      schema = T.tagged(:kind, %{"circle" => T.object(%{r: T.float()}, unknown: :error)})

      assert out(schema) == %{
               "oneOf" => [
                 %{
                   "type" => "object",
                   "properties" => %{
                     "kind" => %{"const" => "circle"},
                     "r" => %{"type" => "number"}
                   },
                   "required" => ["kind", "r"],
                   "additionalProperties" => false
                 }
               ]
             }
    end

    test "an adjacently tagged union puts the branch under its own key" do
      schema = T.tagged(:k, %{"n" => T.integer()}, content: :v)

      assert out(schema) == %{
               "oneOf" => [
                 %{
                   "type" => "object",
                   "properties" => %{"k" => %{"const" => "n"}, "v" => %{"type" => "integer"}},
                   "required" => ["k", "v"]
                 }
               ]
             }
    end

    test "a ref to the root is #, and a ref off a cycle is inlined by staging" do
      recursive = out(T.object(%{kids: T.list(T.ref(:root))}))

      assert recursive["properties"]["kids"]["items"] == %{"$ref" => "#"}
      refute Map.has_key?(recursive, "$defs")

      inlined = out(T.object(%{a: T.ref(:shared)}, defs: %{shared: T.string(min: 1)}))

      assert inlined["properties"]["a"] == %{"type" => "string", "minLength" => 1}
      refute Map.has_key?(inlined, "$defs")
    end

    test "two definitions on a cycle come back as $defs" do
      schema =
        T.object(%{a: T.ref(:one)},
          defs: %{one: %{b: T.optional(T.ref(:two))}, two: %{c: T.optional(T.ref(:one))}}
        )

      document = out(schema)

      assert Map.keys(document["$defs"]) |> Enum.sort() == ["one", "two"]
      assert document["$defs"]["one"]["properties"]["b"] == %{"$ref" => "#/$defs/two"}
    end
  end

  describe "encode/1 and encode!/1" do
    test "hand back the schema's own errors, and raise on demand" do
      assert {:error, [%{code: :unknown_format}]} = JsonSchema.encode(T.string(format: :ssn))
      assert_raise Rupa.SchemaError, fn -> JsonSchema.encode!(T.string(format: :ssn)) end
    end
  end

  describe "decode/1, what it reads" do
    test "scalars and their bounds" do
      assert JsonSchema.decode!(%{"type" => "string", "maxLength" => 2}) == {:string, [max: 2]}

      assert JsonSchema.decode!(%{"type" => "string", "pattern" => "^a"}) ==
               {:string, [pattern: "^a"]}

      assert JsonSchema.decode!(%{"type" => "number", "multipleOf" => 2}) ==
               {:float, [multiple_of: 2]}

      assert JsonSchema.decode!(%{"type" => "boolean"}) == {:boolean, []}

      assert JsonSchema.decode!(%{"type" => "string", "format" => "date-time"}) ==
               {:string, [format: :date_time]}
    end

    test "a const, an enum, and a const of null" do
      assert JsonSchema.decode!(%{"const" => 7}) == {:literal, 7, []}
      assert JsonSchema.decode!(%{"enum" => ["a", "b"]}) == {:enum, ["a", "b"], []}
      assert JsonSchema.decode!(%{"const" => nil}) == {:null, []}
    end

    test "a type beside a closed set drops the values that type excludes" do
      assert JsonSchema.decode!(%{"type" => "string", "enum" => ["a", 1]}) == {:enum, ["a"], []}
      assert code(%{"type" => "string", "const" => 1}) == {[], :unsupported_schema}
      assert code(%{"type" => "string", "enum" => [1]}) == {[], :unsupported_schema}
    end

    test "a type array narrows a closed set the same way a single type does" do
      # The array is an assertion too, so it filters the const/enum rather than being ignored while
      # `type` is marked consumed -- a value only survives if it matches one of the listed types.
      assert code(%{"const" => 1, "type" => ["string"]}) == {[], :unsupported_schema}
      assert code(%{"const" => nil, "type" => ["string"]}) == {[], :unsupported_schema}

      assert JsonSchema.decode!(%{"enum" => [1, "ok"], "type" => ["string", "null"]}) ==
               {:enum, ["ok"], []}

      assert JsonSchema.decode!(%{"const" => 1, "type" => ["string", "integer"]}) ==
               {:literal, 1, []}
    end

    test "every type a closed set can be narrowed against" do
      values = ["a", 1, 1.5, true, nil, %{}, []]

      for {type, kept} <- [
            {"string", {:enum, ["a"], []}},
            {"integer", {:enum, [1], []}},
            {"number", {:enum, [1, 1.5], []}},
            {"boolean", {:enum, [true], []}},
            {"null", {:null, []}}
          ] do
        assert JsonSchema.decode!(%{"type" => type, "enum" => values}) == kept
      end

      # A closed set of objects or arrays is a shape Rupa's enum does not hold, and the import
      # says so rather than handing back a schema the compile refuses.
      for type <- ~w(object array) do
        assert {:error, [%{code: :invalid_scalar}]} =
                 JsonSchema.decode(%{"type" => type, "enum" => values})
      end
    end

    # Null is its own type in Rupa, never a member of a closed set, so a `null` among the values
    # comes out as the nullable it means -- and the values are made unique first, since the spec
    # only says they should be.
    test "a null in an enum is a nullable enum, and a lone null is T.null/0" do
      assert JsonSchema.decode!(%{"enum" => [nil, "a", "b"]}) ==
               {:nullable, {:enum, ["a", "b"], []}, []}

      assert JsonSchema.decode!(%{"enum" => ["a", nil], "type" => ["string", "null"]}) ==
               {:nullable, {:enum, ["a"], []}, []}

      assert JsonSchema.decode!(%{"enum" => [nil]}) == {:null, []}
      assert JsonSchema.decode!(%{"enum" => [nil, nil]}) == {:null, []}
      assert JsonSchema.decode!(%{"enum" => ["a", "a"]}) == {:enum, ["a"], []}

      # `type` narrows first: a string enum's null is a contradiction, and drops out.
      assert JsonSchema.decode!(%{"enum" => ["a", nil], "type" => "string"}) == {:enum, ["a"], []}
    end

    test "a two-type array is a nullable whichever way round the null is written" do
      for type <- ~w(string integer number boolean array object) do
        {:ok, a} = JsonSchema.decode(%{"type" => ["null", type]} |> with_items(type))
        {:ok, b} = JsonSchema.decode(%{"type" => [type, "null"]} |> with_items(type))
        assert a == b
        assert {:nullable, _inner, []} = a
      end

      assert JsonSchema.decode!(%{"type" => ["null", "null"]}) == {:null, []}

      assert JsonSchema.decode!(%{"anyOf" => [%{"type" => "null"}, %{"type" => "null"}]}) ==
               {:null, []}
    end

    defp with_items(document, "array"), do: Map.put(document, "items", %{"type" => "string"})
    defp with_items(document, _type), do: document

    test "objects, and what required and additionalProperties say" do
      document = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "integer"}},
        "required" => ["a"],
        "additionalProperties" => false
      }

      assert JsonSchema.decode!(document) ==
               {:object, %{"a" => {:string, []}, "b" => {:optional, {:integer, []}, []}},
                [unknown: :error]}

      assert JsonSchema.decode!(%{"type" => "object"}) == {:object, %{}, []}

      assert JsonSchema.decode!(%{
               "type" => "object",
               "additionalProperties" => %{"type" => "integer"}
             }) ==
               {:map_of, {:integer, []}, []}
    end

    test "a default makes a property optional and says what it falls back to" do
      document = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "string", "default" => "x"},
          "b" => %{"type" => "array", "items" => %{"type" => "integer"}, "default" => []}
        }
      }

      assert JsonSchema.decode!(document) ==
               {:object,
                %{
                  "a" => {:string, [default: "x"]},
                  "b" => {:list, {:integer, []}, [default: []]}
                }, []}
    end

    # Rupa's `default:` means the field is optional, so a name that is both `required` and carries
    # a `default` stays required and drops the annotation — the document, not Rupa, is the one
    # saying two contradictory things, and required is the stronger claim.
    test "a name in required stays required whatever its default says" do
      document = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string", "default" => "d"}},
        "required" => ["x"]
      }

      assert JsonSchema.decode!(document) == {:object, %{"x" => {:string, []}}, []}

      codec = document |> JsonSchema.decode!() |> Rupa.compile!()
      assert {:error, [%{path: ["x"], code: :required}]} = Rupa.decode(codec, %{})
    end

    # A non-scalar default is decoded through the property's own decoder, not a bare-scalar special
    # case, so a list-of-integers default becomes a list of integers and compiles.
    test "a container default is decoded through the field it sits on" do
      document = %{
        "type" => "object",
        "properties" => %{
          "xs" => %{"type" => "array", "items" => %{"type" => "integer"}, "default" => [1, 2]}
        }
      }

      assert JsonSchema.decode!(document) ==
               {:object, %{"xs" => {:list, {:integer, []}, [default: [1, 2]]}}, []}

      assert {:ok, _codec} = Rupa.compile(JsonSchema.decode!(document))
    end

    # A default the field cannot decode is `:invalid_default` from the import itself, with the
    # path and the offending value: decode/1 stages what it read, so a schema it hands back
    # compiles.
    test "a container default the field cannot decode is refused by the import" do
      document = %{
        "type" => "object",
        "properties" => %{
          "xs" => %{
            "type" => "array",
            "items" => %{"type" => "integer"},
            "default" => ["not-an-int"]
          }
        }
      }

      assert {:error, [error]} = JsonSchema.decode(document)

      assert {error.path, error.code, error.meta} ==
               {["xs"], :invalid_default, %{value: ["not-an-int"]}}
    end

    test "what Rupa refuses in a document is the import's error, not the compile's" do
      assert {:error, [%{code: :contradictory_bounds, path: []}]} =
               JsonSchema.decode(%{"type" => "string", "minLength" => 5, "maxLength" => 2})

      assert {:error, [%{code: :unsupported_format_constraint, path: ["at"]}]} =
               JsonSchema.decode(%{
                 "type" => "object",
                 "properties" => %{
                   "at" => %{"type" => "string", "format" => "date-time", "pattern" => "^2"}
                 }
               })
    end

    # A document default is a wire value; Rupa's default: holds the decoded one, so a format
    # default on a property is converted on the way in and the round trip through a codec closes.
    test "a format default is decoded to the value the field would produce" do
      document = %{
        "type" => "object",
        "properties" => %{
          "at" => %{
            "type" => "string",
            "format" => "date-time",
            "default" => "2026-01-01T00:00:00Z"
          }
        }
      }

      assert JsonSchema.decode!(document) ==
               {:object,
                %{"at" => {:string, [default: ~U[2026-01-01 00:00:00Z], format: :date_time]}}, []}

      # And it round-trips: encode a datetime default, read it back, and it still compiles.
      recovered = closes(T.object(%{at: T.datetime(default: ~U[2026-01-01 00:00:00Z])}))
      assert {:ok, _codec} = Rupa.compile(recovered)
    end

    test "a format default the format cannot read is refused by the import" do
      document = %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string", "format" => "uuid", "default" => "bad"}}
      }

      assert {:error, [error]} = JsonSchema.decode(document)
      assert {error.path, error.code} == {["id"], :invalid_default}
    end

    test "arrays, tuples and the bounds on them" do
      assert JsonSchema.decode!(%{
               "type" => "array",
               "items" => %{"type" => "string"},
               "minItems" => 1,
               "uniqueItems" => true
             }) == {:list, {:string, []}, [min: 1, unique: true]}

      tuple = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "integer"}],
        "items" => false,
        "minItems" => 1
      }

      assert JsonSchema.decode!(tuple) == {:tuple, [{:integer, []}], []}

      capped = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "integer"}],
        "maxItems" => 1,
        "minItems" => 1
      }

      assert JsonSchema.decode!(capped) == {:tuple, [{:integer, []}], []}
    end

    test "anyOf reads back as a nullable or an untagged union" do
      assert JsonSchema.decode!(%{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}) ==
               {:nullable, {:string, []}, []}

      assert JsonSchema.decode!(%{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}) ==
               {:union, [{:string, []}, {:integer, []}], [tag: :none]}
    end

    test "a type given as a list, of one and of two with null" do
      assert JsonSchema.decode!(%{"type" => ["string"]}) == {:string, []}

      assert JsonSchema.decode!(%{"type" => ["string", "null"], "minLength" => 1}) ==
               {:nullable, {:string, [min: 1]}, []}
    end

    test "text as well as a decoded document" do
      assert JsonSchema.decode!(~s({"type": "integer"})) == {:integer, []}
      assert code("{oops") == {[], :json}
    end
  end

  describe "decode/1, what it refuses" do
    test "a keyword Rupa does not have, named" do
      assert {:error, [error]} = JsonSchema.decode(%{"type" => "string", "allOf" => []})
      assert {error.code, error.meta.keyword} == {:unsupported_keyword, "allOf"}
      assert code(%{"oneOf" => []}) == {[], :unsupported_keyword}
      assert code(%{"not" => %{}}) == {[], :unsupported_keyword}
    end

    # Each construct consumes a fixed set of keywords; an assertion keyword left over is refused
    # by name rather than dropped, the same shape as a `$ref`'s siblings. The pure annotations
    # (`title`, `description` and the rest) are always allowed to sit alongside.
    test "an assertion keyword no construct consumes, named" do
      assert {:error, [error]} = JsonSchema.decode(%{"type" => "string", "minimum" => 1})
      assert {error.code, error.meta.keywords} == {:unsupported_keyword_combination, ["minimum"]}

      assert {:error, [both]} = JsonSchema.decode(%{"type" => "string", "foo" => 1, "bar" => 2})
      assert both.meta.keywords == ["bar", "foo"]

      assert code(%{
               "type" => "array",
               "prefixItems" => [%{"type" => "integer"}],
               "items" => false,
               "minItems" => 1,
               "uniqueItems" => true
             }) ==
               {[], :unsupported_keyword_combination}

      assert JsonSchema.decode!(%{
               "type" => "string",
               "title" => "Name",
               "description" => "a name",
               "$comment" => "note",
               "maxLength" => 3
             }) == {:string, [max: 3]}
    end

    # `const: null` is a null type, but only when nothing narrows it away: a `type` that a null
    # cannot satisfy leaves the set empty, which is not a schema Rupa can compile.
    test "a const of null against an incompatible type" do
      assert code(%{"const" => nil, "type" => "string"}) == {[], :unsupported_schema}
      assert JsonSchema.decode!(%{"const" => nil}) == {:null, []}
      assert JsonSchema.decode!(%{"const" => nil, "type" => "null"}) == {:null, []}
    end

    # The nullable `anyOf` shortcut matches its null branch as a partial map, so a second branch
    # that carries more than `type` is a real branch: it goes through the keyword check like any
    # other, rather than being dropped so `nil` slips through a schema that forbids it.
    test "the nullable anyOf shortcut only fires on a bare null branch" do
      assert code(%{"anyOf" => [%{"type" => "string"}, %{"type" => "null", "const" => 1}]}) ==
               {[1], :unsupported_schema}

      assert code(%{
               "anyOf" => [
                 %{"type" => "string"},
                 %{"type" => "null", "not" => %{"type" => "null"}}
               ]
             }) == {[1], :unsupported_keyword}

      assert JsonSchema.decode!(%{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}) ==
               {:nullable, {:string, []}, []}
    end

    # A document is untrusted input, so a malformed keyword is a named error rather than a raise
    # out of the `Enum`/`map_size` that reads it -- or a silent empty object.
    test "a malformed required or properties keyword, rather than a crash" do
      base = %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}

      for bad <- ["a", nil, 5, [1]] do
        assert {:error, [error]} = JsonSchema.decode(Map.put(base, "required", bad))
        assert {error.code, error.meta.keyword} == {:invalid_keyword, "required"}
      end

      assert {:error, [error]} = JsonSchema.decode(%{"type" => "object", "properties" => []})
      assert {error.code, error.meta.keyword} == {:invalid_keyword, "properties"}
    end

    test "a malformed $defs keyword, rather than a crash resolving a $ref against it" do
      # $defs is read by Map.fetch/2 while inlining a $ref, which raises on the wrong shape.
      for bad <- [[], "x", 5] do
        assert {:error, [error]} = JsonSchema.decode(%{"$defs" => bad, "$ref" => "#/$defs/x"})
        assert {error.code, error.meta.keyword} == {:invalid_keyword, "$defs"}
      end
    end

    # 2020-12 applies a $ref's siblings alongside the target; Rupa has nowhere to fold them in,
    # so it refuses rather than dropping them. A lone $ref still works.
    test "a $ref beside other keywords, rather than dropping them" do
      document = %{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#/$defs/s", "minLength" => 5}},
        "required" => ["a"],
        "$defs" => %{"s" => %{"type" => "string"}}
      }

      assert code(document) == {["a"], :unsupported_ref_siblings}
    end

    test "a schema with no type at all" do
      assert code(%{"minimum" => 1}) == {[], :untyped_schema}
      assert code(%{"type" => "array"}) == {[], :untyped_schema}
    end

    test "a boolean schema, and a type nobody has" do
      assert code(true) == {[], :unsupported_schema}
      assert code(%{"type" => "widget"}) == {[], :unknown_type}
      assert code(%{"type" => ["string", "integer"]}) == {[], :unsupported_type_union}
      assert code(%{"anyOf" => [%{"type" => "string"}]}) == {[], :unsupported_schema}
      assert code(%{"enum" => []}) == {[], :unsupported_schema}
    end

    test "a closed set beside a type nobody has keeps none of its values" do
      assert code(%{"type" => "widget", "enum" => ["a", 1]}) == {[], :unsupported_schema}
    end

    test "a format Rupa does not own" do
      assert code(%{"type" => "string", "format" => "idn-email"}) == {[], :unknown_format}
    end

    test "properties and additionalProperties together" do
      document = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "integer"}
      }

      assert code(document) == {[], :unsupported_mixed_object}
    end

    test "a required key nothing describes" do
      assert {:error, [error]} =
               JsonSchema.decode(%{"type" => "object", "required" => ["foo"]})

      assert {error.code, error.meta.name} == {:unsupported_bare_required, "foo"}
    end

    test "a tuple whose length the document leaves open at either end" do
      open = %{"type" => "array", "prefixItems" => [%{"type" => "integer"}]}

      assert code(open) == {[], :unsupported_open_tuple}
      assert code(Map.put(open, "items", false)) == {[], :unsupported_open_tuple}
      assert code(Map.put(open, "minItems", 1)) == {[], :unsupported_open_tuple}

      # A `maxItems` above the prefix length still leaves room for more, so it is open too.
      closed = %{"type" => "array", "prefixItems" => [%{"type" => "integer"}], "minItems" => 1}
      assert code(Map.put(closed, "maxItems", 2)) == {[], :unsupported_open_tuple}
      assert JsonSchema.decode!(Map.put(closed, "maxItems", 1)) == {:tuple, [{:integer, []}], []}
    end

    test "errors carry the path to the node that earned them" do
      document = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "array", "items" => %{"allOf" => []}}}
      }

      assert code(document) == {["a", :of], :unsupported_keyword}

      nested = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "string"}, %{"not" => %{}}],
        "items" => false,
        "minItems" => 2
      }

      assert code(nested) == {[1], :unsupported_keyword}
    end

    test "every property that fails is reported, not just the first" do
      document = %{
        "type" => "object",
        "properties" => %{"a" => %{"allOf" => []}, "b" => %{"not" => %{}}}
      }

      assert {:error, errors} = JsonSchema.decode(document)
      assert Enum.map(errors, & &1.path) == [["a"], ["b"]]
    end

    test "decode!/1 raises instead" do
      assert_raise Rupa.SchemaError, fn -> JsonSchema.decode!(%{"allOf" => []}) end
    end
  end

  describe "decode/1, refs" do
    test "a $ref off a cycle is inlined, wherever it sits" do
      document = %{
        "type" => "object",
        "properties" => %{
          "a" => %{"$ref" => "#/$defs/s"},
          "list" => %{"type" => "array", "items" => %{"$ref" => "#/$defs/s"}},
          "pair" => %{
            "type" => "array",
            "prefixItems" => [%{"$ref" => "#/$defs/s"}],
            "items" => false,
            "minItems" => 1
          },
          "either" => %{"anyOf" => [%{"$ref" => "#/$defs/s"}, %{"type" => "integer"}]},
          "rest" => %{"type" => "object", "additionalProperties" => %{"$ref" => "#/$defs/s"}}
        },
        "required" => ["a", "list", "pair", "either", "rest"],
        "$defs" => %{"s" => %{"type" => "string", "minLength" => 2}}
      }

      assert {:ok, {:object, fields, []}} = JsonSchema.decode(document)
      assert fields["a"] == {:string, [min: 2]}
      assert fields["list"] == {:list, {:string, [min: 2]}, []}
      assert fields["pair"] == {:tuple, [{:string, [min: 2]}], []}
      assert fields["either"] == {:union, [{:string, [min: 2]}, {:integer, []}], [tag: :none]}
      assert fields["rest"] == {:map_of, {:string, [min: 2]}, []}
    end

    test "a $ref on a cycle stops, because the name would have to become an atom" do
      through_defs = %{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#/$defs/s"}},
        "required" => ["a"],
        "$defs" => %{
          "s" => %{"type" => "object", "properties" => %{"b" => %{"$ref" => "#/$defs/s"}}}
        }
      }

      assert {:error, [error]} = JsonSchema.decode(through_defs)
      assert {error.code, error.meta.name} == {:unsupported_recursive_ref, "s"}

      root = %{
        "type" => "object",
        "properties" => %{"a" => %{"$ref" => "#"}},
        "required" => ["a"]
      }

      assert {:error, [%{code: :unsupported_recursive_ref, meta: %{name: "#"}}]} =
               JsonSchema.decode(root)
    end

    test "a ref Rupa does not resolve, and one with nothing behind it" do
      assert {:error, [error]} = JsonSchema.decode(%{"$ref" => "https://example.com/x"})
      assert {error.code, error.meta.ref} == {:unsupported_ref, "https://example.com/x"}

      assert code(%{"$ref" => "#/$defs/nope"}) == {[], :unresolved_ref}
    end

    # RFC 6901: a `/` in a $defs name is `~1` in the pointer and a `~` is `~0`. The name is the
    # member key unescaped; the pointer that reaches it is escaped. `~0` before `~1` on the way
    # back, so `~01` is a literal `~1` rather than a `/`.
    test "a $ref pointer escapes and unescapes the name it points at" do
      assert JsonSchema.decode!(%{
               "$ref" => "#/$defs/a~1b",
               "$defs" => %{"a/b" => %{"type" => "string"}}
             }) ==
               {:string, []}

      assert JsonSchema.decode!(%{
               "$ref" => "#/$defs/m~0n",
               "$defs" => %{"m~n" => %{"type" => "integer"}}
             }) ==
               {:integer, []}

      assert JsonSchema.decode!(%{
               "$ref" => "#/$defs/a~01b",
               "$defs" => %{"a~1b" => %{"type" => "boolean"}}
             }) ==
               {:boolean, []}
    end

    test "export writes an escaped pointer while the $defs key stays literal" do
      schema =
        T.object(%{root: T.ref(:"a/b")},
          defs: %{"a/b": %{next: T.nullable(T.ref(:"a/b"))}}
        )

      document = out(schema)

      assert document["properties"]["root"] == %{"$ref" => "#/$defs/a~1b"}
      assert Map.has_key?(document["$defs"], "a/b")
    end

    # A pointer of more than one token past `$defs` walks into a definition, which Rupa resolves
    # one level; it is refused rather than matched against a flat key that happens to look like it.
    test "a $ref that points deeper than a definition name is refused" do
      document = %{
        "$ref" => "#/$defs/a/properties/b",
        "$defs" => %{
          "a" => %{"type" => "object", "properties" => %{"b" => %{"type" => "string"}}},
          "a/properties/b" => %{"type" => "integer"}
        }
      }

      assert code(document) == {[], :unsupported_ref}
    end

    # The pointer sits in a URI fragment, so it is also percent-decoded (RFC 3986) on the way in and
    # percent-encoded on the way out -- a literal space or `%` in the name is not a pointer token.
    test "a $ref carries fragment percent-encoding, both directions" do
      assert JsonSchema.decode!(%{
               "$ref" => "#/$defs/a%20b",
               "$defs" => %{"a b" => %{"type" => "string"}}
             }) == {:string, []}

      schema =
        T.object(%{root: T.ref(:"a%20b")}, defs: %{"a%20b": %{next: T.nullable(T.ref(:"a%20b"))}})

      document = out(schema)
      assert document["properties"]["root"] == %{"$ref" => "#/$defs/a%2520b"}
      assert Map.has_key?(document["$defs"], "a%20b")
    end
  end

  describe "the two directions together" do
    test "the document closes on itself, for everything decode reads" do
      for schema <- [
            T.string(min: 1, max: 4),
            T.string(format: :uuid),
            T.integer(gte: 0, lt: 9, multiple_of: 3),
            T.float(gt: 0.0, lte: 1.0),
            T.boolean(),
            T.null(),
            T.literal("v2"),
            T.enum(["admin", "member"]),
            T.list(T.string(), min: 1, max: 3, unique: true),
            T.tuple([T.integer(), T.string()]),
            T.tuple([]),
            T.map_of(T.integer()),
            T.nullable(T.string()),
            T.union([T.integer(), T.string()], tag: :none),
            {:object, %{"a" => T.string(), "b" => T.optional(T.integer())}, [unknown: :error]},
            {:object, %{"c" => T.string(default: "x")}, []}
          ] do
        assert closes(schema)
      end
    end

    test "an atom-named object comes back string-named, and decodes the same wire" do
      atoms = T.object(%{first_name: T.string(min: 1)}, rename_all: :camelCase)
      strings = closes(atoms)

      assert strings == {:object, %{"firstName" => {:string, [min: 1]}}, []}

      wire = %{"firstName" => "Ada"}

      assert Rupa.decode!(Rupa.compile!(atoms), wire) == %{first_name: "Ada"}
      assert Rupa.decode!(Rupa.compile!(strings), wire) == %{"firstName" => "Ada"}
    end

    test "the two constructs that encode but do not decode" do
      tagged = T.tagged(:kind, %{"circle" => T.object(%{r: T.float()})})
      recursive = T.object(%{kids: T.list(T.ref(:root))})

      assert code(JsonSchema.encode!(tagged)) == {[], :unsupported_keyword}
      assert code(JsonSchema.encode!(recursive)) == {["kids", :of], :unsupported_recursive_ref}
    end
  end
end

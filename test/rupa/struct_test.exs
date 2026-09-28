defmodule Rupa.StructTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  # The modules `into:` names. They are hand-written here rather than generated, because what
  # this file is testing is that a struct someone already has works -- `mix rupa.gen.struct` is
  # tested where it lives, and its output is checked against `Rupa.compile/2` there.
  defmodule Address do
    @moduledoc false
    defstruct [:city, :postcode]
  end

  defmodule User do
    @moduledoc false
    defstruct [:id, :name, :address, :nickname, role: :member]
  end

  defmodule Spare do
    @moduledoc false
    defstruct [:city, :postcode, :country]
  end

  defmodule Node do
    @moduledoc false
    defstruct [:label, :children]
  end

  defmodule Click do
    @moduledoc false
    defstruct [:x]
  end

  defmodule NotAStruct do
    @moduledoc false
    def hello, do: :world
  end

  # Hand-written, and deliberately not what `mix rupa.gen.struct` would write: an optional
  # field whose defstruct default is a value rather than nil.
  defmodule Held do
    @moduledoc false
    defstruct [:id, note: "none"]
  end

  # A defstruct default that is a container. The generated backend once matched the absent value
  # as a *pattern*, so an empty-map default `%{}` matched any map and dropped the field whenever
  # it held one.
  defmodule Bag do
    @moduledoc false
    defstruct [:id, meta: %{}, tags: []]
  end

  # =============================================
  # Both backends, every direction
  # =============================================
  #
  # The same rule the rest of the suite runs on: every case goes through the closure tree and
  # the generated module, and they have to agree. A struct is the one feature where the two
  # build the value by different means -- a merge at run time against a map literal baked in
  # while the module was generated -- so agreeing is the thing worth asserting.

  defp backends(schema) do
    hash = :erlang.phash2(Rupa.Schema.normalize(schema))
    {:ok, module} = Rupa.compile(schema, as: Module.concat(Rupa.Conformance, "S#{hash}"))

    {Rupa.compile!(schema), module}
  end

  defp decode(schema, data, opts \\ []) do
    {codec, module} = backends(schema)
    closure = Rupa.decode(codec, data, opts)

    assert closure == Rupa.decode(module, data, opts)
    closure
  end

  defp encode(schema, value, opts \\ []) do
    {codec, module} = backends(schema)
    closure = Rupa.encode(codec, value, opts)

    assert closure == Rupa.encode(module, value, opts)
    closure
  end

  defp encode_json(schema, value) do
    {codec, module} = backends(schema)

    case Rupa.encode_json(codec, value) do
      {:ok, iodata} ->
        text = IO.iodata_to_binary(iodata)
        assert IO.iodata_to_binary(Rupa.encode_json!(module, value)) == text
        {:ok, text}

      {:error, errors} ->
        assert Rupa.encode_json(module, value) == {:error, errors}
        {:error, errors}
    end
  end

  defp address, do: T.object(%{city: T.string(), postcode: T.optional(T.string())}, into: Address)

  defp user do
    T.object(
      %{
        id: T.uuid(),
        name: T.string(min: 1),
        role: T.enum([:admin, :member], default: :member),
        nickname: T.optional(T.nullable(T.string())),
        address: address()
      },
      into: User
    )
  end

  @wire %{
    "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "name" => "Ada",
    "address" => %{"city" => "Jakarta"}
  }

  describe "decoding into a struct" do
    test "builds the struct the object names, nested objects included" do
      assert decode(user(), @wire) ==
               {:ok,
                %User{
                  id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
                  name: "Ada",
                  role: :member,
                  nickname: nil,
                  address: %Address{city: "Jakarta", postcode: nil}
                }}
    end

    test "an absent optional key becomes the module's own defstruct default" do
      assert {:ok, %User{nickname: nil, address: %Address{postcode: nil}}} = decode(user(), @wire)
    end

    test "an explicit null and an absent key reach the same struct" do
      # The one thing `into:` costs: present, absent and null are three states everywhere else,
      # and a struct has room for two of them.
      assert decode(user(), Map.put(@wire, "nickname", nil)) == decode(user(), @wire)
    end

    test "a key the struct has and the schema does not keeps that module's default" do
      schema = T.object(%{city: T.string()}, into: Spare)

      assert decode(schema, %{"city" => "Jakarta"}) ==
               {:ok, %Spare{city: "Jakarta", postcode: nil, country: nil}}
    end

    test "the fast clause builds the same struct as the chain" do
      # Every field required and unknown stripped is what the module backend's head match wants,
      # and it is the one path that builds the struct as a literal rather than by merging.
      schema = T.object(%{city: T.string(), postcode: T.string()}, into: Address)

      assert decode(schema, %{"city" => "Jakarta", "postcode" => "12240"}) ==
               {:ok, %Address{city: "Jakarta", postcode: "12240"}}

      assert [{[:postcode], :type}] = codes(schema, %{"city" => "Jakarta", "postcode" => 12_240})
    end

    test "an empty object is still a struct, and still minds unknown keys" do
      assert decode(T.object(%{}, into: Address), %{}) == {:ok, %Address{}}

      strict = T.object(%{}, into: Address, unknown: :error)
      assert decode(strict, %{}) == {:ok, %Address{}}
      assert codes(strict, %{"zip" => "12240"}) == [{[], :unknown_key}]
    end

    test "unknown: :error still reports, and reports before the struct is built" do
      schema = T.object(%{city: T.string()}, into: Address, unknown: :error)

      assert codes(schema, %{"city" => "Jakarta", "zip" => "12240"}) == [{[], :unknown_key}]
    end

    test "a failing field reports its path, not a half-built struct" do
      assert codes(user(), %{@wire | "name" => ""}) == [{[:name], :min}]
      assert codes(user(), put_in(@wire, ["address", "city"], 1)) == [{[:address, :city], :type}]
    end

    test "a tagged branch decodes into its own struct, and encodes back out of one" do
      schema = T.tagged(:kind, %{"click" => T.object(%{x: T.integer()}, into: Click)})

      assert decode(schema, %{"kind" => "click", "x" => 1}) == {:ok, {:click, %Click{x: 1}}}
      assert encode(schema, {:click, %Click{x: 1}}) == {:ok, %{"kind" => "click", "x" => 1}}

      # An internally tagged branch is the one JSON path that starts its field chain with the
      # tag already in the accumulator, so a struct there is worth its own case.
      assert encode_json(schema, {:click, %Click{x: 1}}) == {:ok, ~s({"kind":"click","x":1})}
      assert {:error, [%{code: :struct}]} = encode_json(schema, {:click, %Address{}})
    end

    test "a struct object still refuses a value that is not a map at all" do
      assert codes(address(), "Jakarta") == [{[], :type}]
    end

    test "a recursive ref builds a struct at every level" do
      schema =
        T.object(%{label: T.string(), children: T.list(T.ref(:root))}, into: Node)

      wire = %{"label" => "a", "children" => [%{"label" => "b", "children" => []}]}

      assert decode(schema, wire) ==
               {:ok, %Node{label: "a", children: [%Node{label: "b", children: []}]}}
    end

    defp codes(schema, data, opts \\ []) do
      assert {:error, errors} = decode(schema, data, opts)
      Enum.map(errors, &{&1.path, &1.code})
    end
  end

  describe "encoding out of a struct" do
    test "reads the struct back and is decode's inverse" do
      assert {:ok, decoded} = decode(user(), @wire)

      assert encode(user(), decoded) ==
               {:ok,
                %{
                  "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
                  "name" => "Ada",
                  "role" => "member",
                  "address" => %{"city" => "Jakarta"}
                }}

      assert decode(user(), elem(encode(user(), decoded), 1)) == {:ok, decoded}
    end

    test "an optional field holding nil is written as absent" do
      # Inside a struct there is no absent, so this is the only reading that closes the round
      # trip: an absent key and an explicit null decode to the same struct, so both may leave
      # as absent.
      assert {:ok, wire} = encode(address(), %Address{city: "Jakarta", postcode: nil})
      assert wire == %{"city" => "Jakarta"}
    end

    test "a required field holding nil is still an error" do
      assert {:error, [error]} = encode(address(), %Address{city: nil})
      assert {error.path, error.code} == {[:city], :type}
    end

    test "a defaulted field holding nil is an error rather than an absence" do
      # A default means decoding always put something there, so a nil is a value the schema
      # cannot express rather than a key that was never set.
      assert {:ok, decoded} = decode(user(), @wire)
      assert {:error, [error]} = encode(user(), %{decoded | role: nil})
      assert {error.path, error.code} == {[:role], :const}
    end

    test "another module's struct is refused by name" do
      assert {:error, [error]} = encode(user(), %Address{city: "Jakarta"})
      assert error.code == :struct
      assert error.meta == %{expected: User, value: %Address{city: "Jakarta"}}
      assert Rupa.Error.message(error) =~ "expected %Rupa.StructTest.User{}"
    end

    test "a plain map is refused too, however right its keys look" do
      assert {:error, [error]} = encode(address(), %{city: "Jakarta"})
      assert error.code == :struct
    end

    test "encode_json fuses out of a struct the same way" do
      assert {:ok, decoded} = decode(user(), @wire)

      assert encode_json(user(), decoded) ==
               {:ok,
                ~s({"address":{"city":"Jakarta"},) <>
                  ~s("id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8","name":"Ada","role":"member"})}
    end

    # The absent value is the module's own, not `nil`, and the rule has to be about the former.
    # Both cases fail if encode skips on `nil` instead: the first because the default is a value
    # the schema cannot express and encode does not re-run constraints, so it would go out and
    # fail on the way back in; the second because an absent key and an explicit null would stop
    # reaching the same struct.
    test "the absent value is the module's own, and an absent key round-trips through it" do
      assert decode(held(), %{"id" => 1}) == {:ok, %Held{id: 1, note: "none"}}
      assert encode(held(), %Held{id: 1, note: "none"}) == {:ok, %{"id" => 1}}
      assert decode(held(), %{"id" => 1}) == decode(held(), elem(encode(held(), %Held{id: 1}), 1))
      assert encode_json(held(), %Held{id: 1, note: "none"}) == {:ok, ~s({"id":1})}
    end

    test "with a default that is not nil, an explicit null goes out as one" do
      assert decode(held(), %{"id" => 1, "note" => nil}) == {:ok, %Held{id: 1, note: nil}}
      assert encode(held(), %Held{id: 1, note: nil}) == {:ok, %{"id" => 1, "note" => nil}}
      assert encode_json(held(), %Held{id: 1, note: nil}) == {:ok, ~s({"id":1,"note":null})}
      assert decode(held(), %{"id" => 1, "note" => nil}) == {:ok, %Held{id: 1, note: nil}}
    end

    defp held do
      T.object(%{id: T.integer(), note: T.optional(T.nullable(T.string(max: 2)))}, into: Held)
    end

    test "a map wearing the right tag without the keys raises, on both backends" do
      broken = Map.delete(%Address{city: "Jakarta"}, :postcode)
      {codec, module} = backends(address())

      assert_raise KeyError, fn -> Rupa.encode(codec, broken) end
      assert_raise KeyError, fn -> Rupa.encode(module, broken) end
      assert_raise KeyError, fn -> Rupa.encode_json(codec, broken) end
      assert_raise KeyError, fn -> Rupa.encode_json(module, broken) end
    end

    test "encode_json skips a nil optional and refuses a foreign struct" do
      assert encode_json(address(), %Address{city: "Jakarta"}) == {:ok, ~s({"city":"Jakarta"})}
      assert {:error, [%{code: :struct}]} = encode_json(address(), %User{})
    end
  end

  # =============================================
  # What cannot hold beside into:
  # =============================================

  describe "the schema errors" do
    defp error(schema) do
      assert {:error, [error]} = Rupa.compile(schema)
      {error.path, error.code, error.meta}
    end

    test "keys: :string cannot, because a struct's keys are atoms" do
      schema = T.object(%{city: T.string()}, into: Address, keys: :string)

      assert error(schema) == {[], :struct_keys, %{names: :atom}}
    end

    test "a string-named object has to ask for keys: :atom" do
      schema = T.object(%{"city" => T.string()}, into: Address)

      assert error(schema) == {[], :struct_keys, %{names: :string}}

      assert {:ok, %Address{city: "Jakarta"}} =
               decode(T.object(%{"city" => T.string()}, into: Address, keys: :atom), %{
                 "city" => "Jakarta"
               })
    end

    test "unknown: :keep cannot, because a struct has nowhere to put what it carries" do
      schema = T.object(%{city: T.string()}, into: Address, unknown: :keep)

      assert error(schema) == {[], :struct_keeps_unknown, %{}}
    end

    test "into: wants a module" do
      assert {[], :invalid_option, meta} = error(T.object(%{}, into: "MyApp.User"))
      assert meta.option == :into
    end

    test "a keys: that is not one is reported once, not twice" do
      # The cross-check reads the resolved `keys:`, so an unresolvable one has to stand aside
      # and let the option's own error be the whole of it.
      assert error(T.object(%{city: T.string()}, into: Address, keys: :nope)) ==
               {[], :invalid_option,
                %{option: :keys, value: :nope, expected: "one of :atom, :string"}}
    end
  end

  describe "the module check" do
    test "a module that is not loaded, or has no defstruct, is refused" do
      assert error(T.object(%{city: T.string()}, into: NotAStruct)) ==
               {[], :not_a_struct, %{module: NotAStruct}}

      assert error(T.object(%{city: T.string()}, into: Rupa.StructTest.Absent)) ==
               {[], :not_a_struct, %{module: Rupa.StructTest.Absent}}
    end

    test "a key the struct does not have is named, so a stale struct fails the compile" do
      schema = T.object(%{city: T.string(), country: T.string()}, into: Address)

      assert error(schema) == {[], :struct_field_missing, %{module: Address, keys: [:country]}}
    end

    test ":__struct__ is not a field, so a schema cannot claim it" do
      # Refused by validate/1 for every object, struct or not; and were it to reach here, it is
      # kept out of the module's key set too, so it could not overwrite the tag the merge puts.
      schema = T.object(%{__struct__: T.string()}, into: Address)

      assert error(schema) == {[], :reserved_field_name, %{field: :__struct__}}
    end

    test "it checks the decoded key, not the one you wrote" do
      # The whole reason the check happens after staging: `from:` moved the wire key and left the
      # decoded key alone, so this is fine -- while a rename that changes the decoded key is not.
      assert {:ok, _codec} =
               Rupa.compile(T.object(%{city: T.string(from: "town")}, into: Address))

      assert {[], :struct_field_missing, %{keys: [:town]}} =
               error(T.object(%{town: T.string()}, into: Address))
    end

    test "the path names the nested object, not the root" do
      schema = T.object(%{home: T.object(%{country: T.string()}, into: Address)})

      assert {[:home], :struct_field_missing, _meta} = error(schema)
    end

    test "structs: :skip stages without asking for the module" do
      schema = T.object(%{city: T.string()}, into: Rupa.StructTest.Absent)

      assert {:error, [%{code: :not_a_struct}]} = Rupa.Stage.run(schema)
      assert {:ok, program} = Rupa.Stage.run(schema, structs: :skip)
      assert program.root.into == Rupa.StructTest.Absent
    end
  end

  # =============================================
  # Staging and explain
  # =============================================

  test "explain prints into: beside the unknown-key policy" do
    assert Rupa.explain(address()) ==
             """
             object (2 fields, unknown: strip, into: Rupa.StructTest.Address)
               "city" -> :city         string
               "postcode" -> :postcode optional string\
             """
  end

  test "the schema still prints, hashes and normalises" do
    # A module name is an atom, so nothing about `into:` costs the schema its data-ness.
    assert Rupa.Schema.normalize({:object, %{city: {:string, []}}, [into: Address]}) ==
             {:object, %{city: {:string, []}}, [into: Address]}

    assert is_integer(:erlang.phash2(address()))
  end

  test "a JSON Schema describes the wire, so into: leaves no trace in it" do
    assert {:ok, document} = Rupa.JsonSchema.encode(address())

    assert document == %{
             "$schema" => "https://json-schema.org/draft/2020-12/schema",
             "type" => "object",
             "properties" => %{
               "city" => %{"type" => "string"},
               "postcode" => %{"type" => "string"}
             },
             "required" => ["city"]
           }
  end

  describe "a defstruct default that is a container" do
    setup do
      %{
        schema:
          T.object(
            %{
              id: T.integer(),
              meta: T.optional(T.map_of(T.integer())),
              tags: T.optional(T.list(T.string()))
            },
            into: Bag
          )
      }
    end

    test "a present non-default value is kept, not read as absent", %{schema: schema} do
      wire = %{"id" => 1, "meta" => %{"a" => 1}, "tags" => ["x"]}
      assert {:ok, decoded} = decode(schema, wire)

      assert encode(schema, decoded) ==
               {:ok, %{"id" => 1, "meta" => %{"a" => 1}, "tags" => ["x"]}}

      assert encode_json(schema, decoded) ==
               {:ok, ~s({"id":1,"meta":{"a":1},"tags":["x"]})}

      assert decode(schema, elem(encode(schema, decoded), 1)) == {:ok, decoded}
    end

    test "a value equal to the default still encodes as absent", %{schema: schema} do
      assert {:ok, decoded} = decode(schema, %{"id" => 1, "meta" => %{}, "tags" => []})
      assert encode(schema, decoded) == {:ok, %{"id" => 1}}
      assert encode_json(schema, decoded) == {:ok, ~s({"id":1})}
    end
  end
end

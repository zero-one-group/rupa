defmodule Rupa.StageTest do
  use ExUnit.Case, async: true

  alias Rupa.IR
  alias Rupa.Stage
  alias Rupa.T

  doctest Rupa.Stage

  defp stage!(schema) do
    assert {:ok, program} = Stage.run(schema)
    program
  end

  defp error(schema) do
    assert {:error, [error]} = Stage.run(schema)
    {error.path, error.code, error.meta}
  end

  describe "field names" do
    test "a string name is its own wire key and its own decoded key" do
      program = stage!({:object, %{"first_name" => T.string()}, [rename_all: :camelCase]})

      assert [%IR.Field{key: "first_name", from: "firstName", to: "firstName"}] =
               program.root.fields
    end

    test "keys: :atom is the one place a string name becomes an atom" do
      program = stage!({:object, %{"first_name" => T.string()}, [keys: :atom]})

      assert [%IR.Field{key: :first_name, from: "first_name"}] = program.root.fields
    end

    test "an atom name still defaults to an atom key" do
      program = stage!(%{first_name: T.string()})

      assert [%IR.Field{key: :first_name, from: "first_name"}] = program.root.fields
    end
  end

  describe "a malformed schema never reaches the IR" do
    test "validate/1 runs first, and its errors come straight back" do
      assert {:error, [%{code: :unknown_format}]} = Stage.run(T.string(format: :ssn))
    end
  end

  describe "scalars" do
    test "checks come out in a fixed order, whatever order they were written in" do
      assert %IR.Scalar{kind: :string, checks: [min: 1, max: 3, pattern: "^a$"]} =
               stage!(T.string(pattern: "^a$", max: 3, min: 1)).root

      assert %IR.Scalar{checks: [len: 2]} = stage!(T.string(len: 2)).root

      assert %IR.Scalar{checks: [gte: 0, lte: 9, multiple_of: 2]} =
               stage!(T.integer(multiple_of: 2, lte: 9, gte: 0)).root

      assert %IR.Scalar{checks: [gt: 1, lt: 8]} = stage!(T.float(lt: 8, gt: 1)).root
    end

    test "kinds with no constraints carry none" do
      assert %IR.Scalar{kind: :boolean, checks: [], format: nil} = stage!(T.boolean()).root
      assert %IR.Scalar{kind: :null} = stage!(T.null()).root
      assert %IR.Scalar{kind: :float} = stage!(T.float()).root
    end

    test "a format is lifted out of the checks" do
      assert %IR.Scalar{kind: :string, checks: [], format: :uuid} = stage!(T.uuid()).root
    end

    test "a pattern stays its source, because the module backend has to embed it" do
      assert %IR.Scalar{checks: [pattern: "^[A-Z]{2}$"]} =
               stage!(T.string(pattern: "^[A-Z]{2}$")).root
    end
  end

  describe "enum and literal collapse into one lookup" do
    test "atoms arrive from the wire as strings" do
      assert %IR.Const{lookup: %{"admin" => :admin, "member" => :member}, values: values} =
               stage!(T.enum([:admin, :member])).root

      assert values == [:admin, :member]
    end

    test "strings, numbers and booleans map to themselves" do
      assert %IR.Const{lookup: %{"a" => "a", 1 => 1, true => true}} =
               stage!(T.enum(["a", 1, true])).root
    end

    test "a literal is an enum of one" do
      assert %IR.Const{lookup: %{"v2" => "v2"}, values: ["v2"]} = stage!(T.literal("v2")).root
    end

    test "two values that decode from the same wire value are refused" do
      assert {[], :ambiguous_const, %{values: ["a", :a]}} = error(T.enum(["a", :a]))
    end
  end

  describe "objects" do
    test "fields are ordered, and carry the three names they answer to" do
      assert %IR.Object{fields: fields, unknown: :strip} =
               stage!(%{name: T.string(), age: T.integer()}).root

      assert Enum.map(fields, & &1.key) == [:age, :name]
      assert Enum.map(fields, & &1.from) == ["age", "name"]
      assert Enum.map(fields, & &1.to) == ["age", "name"]
    end

    test "presence and default are decided at staging" do
      program = stage!(%{a: T.string(), b: T.optional(T.string()), c: T.string(default: "x")})
      by_key = Map.new(program.root.fields, &{&1.key, &1})

      assert %IR.Field{presence: :required, default: :none} = by_key.a
      assert %IR.Field{presence: :optional, default: :none} = by_key.b
      assert %IR.Field{presence: :optional, default: {:value, "x"}} = by_key.c
    end

    test "a default on the optional itself is the one that is read" do
      assert [%IR.Field{presence: :optional, default: {:value, 1}}] =
               stage!(%{a: T.optional(T.integer(), default: 1)}).root.fields
    end

    test "the unknown-key policy comes through" do
      assert %IR.Object{unknown: :error} = stage!(T.object(%{}, unknown: :error)).root
      assert %IR.Object{unknown: :keep} = stage!(T.object(%{}, unknown: :keep)).root
    end
  end

  describe "containers" do
    test "list, map_of, tuple and nullable each get their own node" do
      assert %IR.Array{of: %IR.Scalar{kind: :string}, checks: [min: 1, max: 2, unique: true]} =
               stage!(T.list(T.string(), unique: true, max: 2, min: 1)).root

      assert %IR.Dict{of: %IR.Scalar{kind: :integer}} = stage!(T.map_of(T.integer())).root

      assert %IR.Fixed{members: [%IR.Scalar{kind: :float}, %IR.Scalar{kind: :string}]} =
               stage!(T.tuple([T.float(), T.string()])).root

      assert %IR.Nullable{of: %IR.Scalar{kind: :string}} = stage!(T.nullable(T.string())).root
    end
  end

  describe "refs" do
    test "a ref that is not on a cycle is replaced by the definition itself" do
      program = stage!(T.object(%{a: T.ref(:name)}, defs: %{name: T.string(min: 1)}))

      assert [%IR.Field{key: :a, ir: %IR.Scalar{kind: :string, checks: [min: 1]}}] =
               program.root.fields

      assert program.defs == %{}
    end

    test "a chain of non-cyclic refs collapses all the way down" do
      program = stage!(T.object(%{a: T.ref(:one)}, defs: %{one: T.ref(:two), two: T.integer()}))

      assert [%IR.Field{ir: %IR.Scalar{kind: :integer}}] = program.root.fields
    end

    test "a definition declared on a nested object is still in scope" do
      inner = T.object(%{b: T.ref(:shared)}, defs: %{shared: T.string()})
      program = stage!(%{a: inner})

      assert [%IR.Field{ir: %IR.Object{fields: [%IR.Field{ir: %IR.Scalar{kind: :string}}]}}] =
               program.root.fields
    end

    test "a ref on a cycle survives, and lands in the defs table" do
      program = stage!(%{value: T.integer(), children: T.list(T.ref(:root))})

      assert %IR.Object{fields: fields} = program.root
      assert [%IR.Field{key: :children, ir: %IR.Array{of: %IR.Ref{name: :root}}} | _rest] = fields
      assert %{root: %IR.Object{}} = program.defs
    end

    test "mutual recursion keeps both names" do
      schema =
        T.object(%{a: T.ref(:one)},
          defs: %{one: %{b: T.ref(:two)}, two: %{c: T.ref(:one)}}
        )

      program = stage!(schema)
      assert Map.keys(program.defs) |> Enum.sort() == [:one, :two]
      assert [%IR.Field{ir: %IR.Ref{name: :one}}] = program.root.fields
    end
  end

  describe "wire names" do
    defp names(schema) do
      Map.new(stage!(schema).root.fields, &{&1.key, {&1.from, &1.to}})
    end

    test "rename_all: spells every field in one style, both directions" do
      fields = %{first_name: T.string(), id: T.integer()}

      assert names(T.object(fields, rename_all: :camelCase)) ==
               %{first_name: {"firstName", "firstName"}, id: {"id", "id"}}

      assert names(T.object(fields, rename_all: :kebab)) ==
               %{first_name: {"first-name", "first-name"}, id: {"id", "id"}}

      assert names(T.object(fields, rename_all: :snake_case)) ==
               %{first_name: {"first_name", "first_name"}, id: {"id", "id"}}
    end

    test "it reads the field name as words, whatever style it was written in" do
      fields = %{firstName: T.string(), userID: T.string(), line_1: T.string()}

      assert names(T.object(fields, rename_all: :snake_case)) ==
               %{
                 firstName: {"first_name", "first_name"},
                 userID: {"user_id", "user_id"},
                 line_1: {"line_1", "line_1"}
               }

      assert names(T.object(fields, rename_all: :camelCase)) ==
               %{
                 firstName: {"firstName", "firstName"},
                 userID: {"userId", "userId"},
                 line_1: {"line1", "line1"}
               }
    end

    test "a name with no words in it is left alone rather than renamed to nothing" do
      assert names(T.object(%{_: T.string()}, rename_all: :snake_case)) == %{_: {"_", "_"}}
      assert names(T.object(%{_: T.string()}, rename_all: :camelCase)) == %{_: {"_", "_"}}
    end

    test "one of from: and to: renames both directions; both of them is a migration" do
      schema =
        T.object(
          %{
            first_name: T.string(from: "given_name", to: "givenName"),
            last_name: T.string(from: "surname"),
            age: T.optional(T.integer(), to: "yearsOld")
          },
          rename_all: :camelCase
        )

      assert names(schema) == %{
               first_name: {"given_name", "givenName"},
               last_name: {"surname", "surname"},
               age: {"yearsOld", "yearsOld"}
             }
    end

    test "rename_all: stops at the object that declares it" do
      schema =
        T.object(%{first_name: T.string(), home_address: %{post_code: T.string()}},
          rename_all: :camelCase
        )

      assert [_name, _address] = fields = stage!(schema).root.fields
      assert Enum.map(fields, & &1.from) == ["firstName", "homeAddress"]

      assert [%IR.Field{from: "post_code"}] =
               Enum.find(fields, &(&1.key == :home_address)).ir.fields
    end

    test "keys: changes the decoded key's type and leaves the wire alone" do
      schema = T.object(%{first_name: T.string()}, rename_all: :camelCase, keys: :string)

      assert [%IR.Field{key: "first_name", from: "firstName", to: "firstName"}] =
               stage!(schema).root.fields

      assert [%IR.Field{key: :first_name}] =
               stage!(T.object(%{first_name: T.string()}, keys: :atom)).root.fields
    end

    test "two fields that land on one wire key are refused" do
      assert {[], :duplicate_wire_key, %{key: "id"}} =
               error(%{id: T.string(), user_id: T.string(from: "id")})

      assert {[:a], :duplicate_wire_key, %{key: "id"}} =
               error(%{a: %{id: T.string(), user_id: T.string(to: "id")}})
    end
  end

  describe "unions" do
    test "an untagged union keeps its variants in the order they were written" do
      assert %IR.Union{members: [%IR.Scalar{kind: :integer}, %IR.Scalar{kind: :string}]} =
               stage!(T.union([T.integer(), T.string()], tag: :none)).root
    end

    test "a tagged union becomes a branch table, sorted, with the tag interned here" do
      schema = T.tagged(:type, %{"rect" => %{w: T.float()}, "circle" => %{r: T.float()}})

      assert %IR.Tagged{tag: :type, tag_wire: "type", content: nil, content_wire: nil} =
               tagged = stage!(schema).root

      assert Enum.map(tagged.branches, & &1.wire) == ["circle", "rect"]
      assert Enum.map(tagged.branches, & &1.tag) == [:circle, :rect]
    end

    test "content: is the adjacent form, and carries its own two names" do
      schema = T.tagged(:kind, %{"n" => T.integer()}, content: :value)

      assert %IR.Tagged{tag: :kind, tag_wire: "kind", content: :value, content_wire: "value"} =
               stage!(schema).root
    end

    # Internally tagged, the tag key sits in the branch's own map. A branch that strips unknown
    # keys ignores it for nothing; anything else has to be handed the map without it.
    test "a branch is told whether it has to be handed the map without the tag" do
      strips = T.tagged(:type, %{"a" => T.object(%{}, unknown: :strip)})
      errors = T.tagged(:type, %{"a" => T.object(%{}, unknown: :error)})
      adjacent = T.tagged(:type, %{"a" => T.object(%{}, unknown: :error)}, content: :value)

      assert [%IR.Branch{drop_tag: false}] = stage!(strips).root.branches
      assert [%IR.Branch{drop_tag: true}] = stage!(errors).root.branches
      assert [%IR.Branch{drop_tag: false}] = stage!(adjacent).root.branches
    end

    test "a branch can recurse, and the ref survives inside it" do
      program = stage!(T.tagged(:type, %{"node" => %{kids: T.list(T.ref(:root))}}))

      assert [%IR.Branch{tag: :node, ir: %IR.Object{fields: [field]}}] = program.root.branches
      assert %IR.Field{key: :kids, ir: %IR.Array{of: %IR.Ref{name: :root}}} = field
      assert %{root: %IR.Tagged{}} = program.defs
    end
  end

  describe "nested untagged unions warn" do
    defp warning(schema), do: ExUnit.CaptureIO.capture_io(:stderr, fn -> Stage.run(schema) end)

    test "a union inside a union says so, once" do
      inner = T.union([T.integer(), T.string()], tag: :none)
      schema = T.union([inner, T.boolean()], tag: :none)

      assert warning(schema) =~ "nests untagged unions"
    end

    test "through a container, and through a recursive ref" do
      inner = T.union([T.integer(), T.string()], tag: :none)

      assert warning(T.union([T.list(inner), T.boolean()], tag: :none)) =~ "nests untagged unions"

      recursive =
        T.object(%{a: T.ref(:one)},
          defs: %{one: %{b: T.union([T.ref(:one), inner], tag: :none)}}
        )

      assert warning(recursive) =~ "nests untagged unions"
    end

    test "one union on its own does not, and neither does a tagged one inside a union" do
      tagged = T.tagged(:type, %{"a" => %{}})
      schema = T.union([tagged, T.boolean()], tag: :none)

      assert warning(T.union([T.integer(), T.string()], tag: :none)) == ""
      assert warning(schema) == ""
      assert warning(%{a: T.list(T.tuple([T.integer()]))}) == ""
      assert warning(T.map_of(T.nullable(T.string()))) == ""
    end

    test "and two unions side by side are not nested" do
      union = T.union([T.integer(), T.string()], tag: :none)

      assert warning(%{a: union, b: union}) == ""
    end
  end

  describe "degenerate ref cycles" do
    test "a ref that resolves only to itself is refused, not left to hang" do
      assert error(T.ref(:root)) == {[], :circular_ref, %{name: :root}}
    end

    test "a chain of refs with no node between them is refused" do
      # Either member of the cycle is a correct thing to name; which one comes first is map
      # iteration order, which is not stable across OTP versions.
      schema = T.object(%{a: T.ref(:x)}, defs: %{x: T.ref(:y), y: T.ref(:x)})
      assert {[:defs, name], :circular_ref, %{name: name}} = error(schema)
      assert name in [:x, :y]
    end

    test "a cycle through nullable is refused: nullable hands its inner the value unchanged" do
      assert error(T.nullable(T.ref(:root))) == {[], :circular_ref, %{name: :root}}
    end

    test "a cycle through an untagged union is refused: every member sees the same value" do
      assert error(T.union([T.ref(:root), T.integer()], tag: :none)) ==
               {[], :circular_ref, %{name: :root}}
    end

    test "recursion through a real node still stages" do
      assert {:ok, _program} = Stage.run(%{value: T.integer(), children: T.list(T.ref(:root))})
    end

    test "recursion through nullable behind a consuming node still stages" do
      # The object consumes the map before the field loops, so nullable(ref(:root)) here is a
      # productive linked list, not the degenerate cycle above.
      assert {:ok, _program} = Stage.run(%{next: T.nullable(T.ref(:root))})
    end
  end

  describe "defaults" do
    test "a default that cannot encode against its field is refused" do
      assert {[:n], :invalid_default, %{value: "x"}} = error(%{n: T.integer(default: "x")})
      assert {[:r], :invalid_default, _meta} = error(%{r: T.enum([:a, :b], default: :zzz)})
    end

    test "a format default given as its wire string rather than its decoded value is refused" do
      assert {[:at], :invalid_default, _meta} =
               error(%{at: T.datetime(default: "2026-01-01T00:00:00Z")})
    end

    test "a nested default is reported at its own path" do
      schema = %{outer: %{inner: T.integer(default: "x")}}
      assert {[:outer, :inner], :invalid_default, _meta} = error(schema)
    end

    test "a valid default, decoded value and all, stages" do
      assert {:ok, _program} = Stage.run(%{at: T.datetime(default: ~U[2026-01-01 00:00:00Z])})
      assert {:ok, _program} = Stage.run(%{r: T.enum([:a, :b], default: :a)})
    end

    test "a default outside its own constraints is refused" do
      # A default is materialised onto an absent field with no per-decode check, so it must be a
      # value the field would accept -- constraints and all, or the materialised value would not
      # itself decode. Staging round-trips it (encode then decode) to catch that here.
      assert {[:n], :invalid_default, %{value: 5}} = error(%{n: T.integer(lte: 3, default: 5)})
      assert {[:n], :invalid_default, %{value: 0}} = error(%{n: T.integer(gt: 0, default: 0)})
    end

    test "a default inside its constraints stages" do
      assert {:ok, _program} = Stage.run(%{n: T.integer(gte: 0, lte: 10, default: 5)})
      assert {:ok, _program} = Stage.run(%{s: T.string(min: 1, default: "x")})
    end

    test "a default is stored in its own decoded form, so materialising it is a fixpoint" do
      # `%{}` would decode to `%{x: 1}` (x carries its own default), so the stored child default is
      # normalised to that -- otherwise the first decode and a round trip through it disagree.
      program = stage!(%{child: T.object(%{x: T.integer(default: 1)}, default: %{})})
      assert [%IR.Field{key: :child, default: {:value, %{x: 1}}}] = program.root.fields

      # a key a strip object drops is dropped from the stored default too.
      program = stage!(%{child: T.object(%{}, default: %{"lost" => 1})})
      assert [%IR.Field{key: :child, default: {:value, %{}}}] = program.root.fields
    end

    test "a migration field's default is normalised without crossing its names" do
      # from ≠ to makes encode deliberately not decode's inverse, so normalisation runs against a
      # name-symmetric copy: the default is neither falsely refused nor read back under the wrong
      # key, and its value survives.
      program = stage!(%{u: T.object(%{x: T.string(from: "old", to: "new")}, default: %{x: "v"})})
      assert [%IR.Field{key: :u, default: {:value, %{x: "v"}}}] = program.root.fields
    end

    test "a default is normalised against children whose own defaults are already normalised" do
      # Two levels of default: `a`'s `%{}` decodes through `b`, whose `%{}` in turn decodes to
      # `%{c: 1}` -- so `a`'s stored form has to reach all the way down, or the first decode
      # materialises `%{b: %{}}` and the round trip through it comes back with `c` filled in.
      schema = %{
        a: T.object(%{b: T.object(%{c: T.integer(default: 1)}, default: %{})}, default: %{})
      }

      program = stage!(schema)
      assert [%IR.Field{key: :a, default: {:value, %{b: %{c: 1}}}}] = program.root.fields

      # ...and a key the child strips is stripped out of the parent's default too.
      schema = %{
        a: T.object(%{b: T.object(%{c: T.integer()}, default: %{c: 1, junk: 2})}, default: %{})
      }

      program = stage!(schema)
      assert [%IR.Field{key: :a, default: {:value, %{b: %{c: 1}}}}] = program.root.fields
    end

    test "a default under a recursive definition is normalised through the settled table" do
      # `a` defaults through def `node`, whose own field default settles to `%{c: 1}` first.
      schema =
        T.object(%{a: T.ref(:node, default: %{kids: []})},
          defs: %{
            node: %{
              kids: T.list(T.ref(:node)),
              b: T.object(%{c: T.integer(default: 1)}, default: %{})
            }
          }
        )

      program = stage!(schema)

      assert [%IR.Field{key: :a, default: {:value, %{kids: [], b: %{c: 1}}}}] =
               program.root.fields
    end

    test "a default that reaches its own field again is :recursive_default, not a hang" do
      # Every time it fires it materialises one more `next`; no finite value of it is stable.
      assert {[:next], :recursive_default, %{value: %{}}} =
               error(%{next: T.ref(:root, default: %{})})

      schema = T.object(%{a: T.ref(:node)}, defs: %{node: %{next: T.ref(:node, default: %{})}})
      assert {[:defs, :node, :next], :recursive_default, _meta} = error(schema)

      # Break the recursion with something that can be empty and a default is stable again.
      assert {:ok, _program} = Stage.run(%{kids: T.list(T.ref(:root), default: [])})
      assert {:ok, _program} = Stage.run(%{next: T.nullable(T.ref(:root), default: nil)})
    end
  end

  describe "a value-converting format cannot carry a length or pattern" do
    # date_time/date/time/duration decode to a value and re-encode to a canonical spelling, so a
    # length or pattern check on the incoming spelling need not hold on the encoded one -- the codec
    # would accept an input it then cannot re-encode. Refused at staging, the policy B12 already
    # gave the generator.
    test "the four converting formats refuse a string check" do
      assert {[], :unsupported_format_constraint, %{format: :date_time, checks: [:len]}} =
               error(T.datetime(len: 25))

      assert {[], :unsupported_format_constraint, %{format: :duration}} =
               error(T.duration(len: 5))

      assert {[:on], :unsupported_format_constraint, %{format: :date}} =
               error(%{on: T.date(min: 3)})

      assert {[:a], :unsupported_format_constraint, %{format: :time}} =
               error(%{a: T.time(pattern: "^x")})
    end

    test "the six that hand the string back unchanged still take checks" do
      assert {:ok, _program} = Stage.run(T.uuid(len: 36))
      assert {:ok, _program} = Stage.run(T.email(max: 30))
      assert {:ok, _program} = Stage.run(%{h: T.hostname(max: 253)})
      assert {:ok, _program} = Stage.run(T.string(len: 5, pattern: "^x"))
    end
  end

  describe "tag key collisions" do
    test "an internally tagged branch cannot claim the tag's wire key" do
      schema = T.tagged(:type, %{"circle" => %{type: T.string(), r: T.float()}})
      assert {["circle"], :tag_wire_conflict, %{key: "type"}} = error(schema)
    end

    test "a field renamed onto the tag key is caught too" do
      schema = T.tagged(:type, %{"circle" => %{kind: T.string(to: "type"), r: T.float()}})
      assert {["circle"], :tag_wire_conflict, %{key: "type"}} = error(schema)
    end

    test "a branch that does not touch the tag key stages" do
      assert {:ok, _program} = Stage.run(T.tagged(:type, %{"circle" => %{r: T.float()}}))
    end
  end
end

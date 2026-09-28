defmodule Rupa.ExplainTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  doctest Rupa.Explain

  describe "summary lines" do
    test "a scalar carries its checks and its format" do
      assert Rupa.explain(T.string()) == "string"
      assert Rupa.explain(T.string(min: 1, max: 5)) == "string min=1 max=5"
      assert Rupa.explain(T.uuid()) == "string format=uuid"
      assert Rupa.explain(T.integer(gte: 0)) == "integer gte=0"
    end

    test "a const lists what it accepts" do
      assert Rupa.explain(T.enum([:admin, :member])) == "const :admin | :member"
      assert Rupa.explain(T.literal("v2")) == ~s[const "v2"]
    end

    test "containers say what they hold, on the next line" do
      assert Rupa.explain(T.list(T.integer(), max: 3)) == "list max=3 of\n  integer"
      assert Rupa.explain(T.map_of(T.integer())) == "map of\n  integer"
      assert Rupa.explain(T.nullable(T.string())) == "nullable\n  string"

      assert Rupa.explain(T.tuple([T.float(), T.string()])) ==
               "tuple (2 members) of\n  float\n  string"

      assert Rupa.explain(T.tuple([T.float()])) == "tuple (1 member) of\n  float"
    end
  end

  describe "objects" do
    test "an empty one" do
      assert Rupa.explain(%{}) == "object (0 fields, unknown: strip)"
    end

    test "wire key, field name, presence, and the columns line up" do
      schema = %{
        id: T.uuid(),
        age: T.optional(T.integer(gte: 0)),
        role: T.enum([:admin], default: :admin)
      }

      assert Rupa.explain(schema) ==
               """
               object (3 fields, unknown: strip)
                 "age" -> :age   optional integer gte=0
                 "id" -> :id     string format=uuid
                 "role" -> :role optional default=:admin const :admin\
               """
    end

    test "a renamed field shows the wire key, and both of them when they differ" do
      schema =
        T.object(
          %{first_name: T.string(), user_id: T.string(from: "id", to: "userId")},
          rename_all: :camelCase,
          keys: :string
        )

      assert Rupa.explain(schema) ==
               """
               object (2 fields, unknown: strip)
                 "firstName" -> "first_name"   string
                 "id" -> "user_id" -> "userId" string\
               """
    end

    test "a field holding a container keeps the tree under it" do
      schema = T.object(%{tags: T.list(T.string(min: 1), max: 5)}, unknown: :error)

      assert Rupa.explain(schema) ==
               """
               object (1 field, unknown: error)
                 "tags" -> :tags list max=5 of
                   string min=1\
               """
    end
  end

  describe "unions" do
    test "a tagged one lines its branches up the way an object lines up its fields" do
      schema = T.tagged(:type, %{"circle" => %{r: T.float()}, "rect" => %{w: T.float()}})

      assert Rupa.explain(schema) ==
               """
               tagged tag=:type (2 branches) of
                 "circle" -> :circle object (1 field, unknown: strip)
                   "r" -> :r float
                 "rect" -> :rect     object (1 field, unknown: strip)
                   "w" -> :w float\
               """
    end

    test "content: shows, and one branch is one branch" do
      schema = T.tagged(:kind, %{"n" => T.integer()}, content: :value)

      assert Rupa.explain(schema) ==
               """
               tagged tag=:kind content=:value (1 branch) of
                 "n" -> :n integer\
               """
    end

    test "an untagged one says it is untagged, and lists what it will try in order" do
      schema = %{v: T.union([T.integer(), T.string(min: 1)], tag: :none)}

      assert Rupa.explain(schema) ==
               """
               object (1 field, unknown: strip)
                 "v" -> :v union (2 variants, untagged) of
                   integer
                   string min=1\
               """
    end
  end

  describe "refs" do
    test "an inlined ref leaves no trace, which is the point" do
      schema = T.object(%{a: T.ref(:name)}, defs: %{name: T.string(min: 1)})

      assert Rupa.explain(schema) ==
               """
               object (1 field, unknown: strip)
                 "a" -> :a string min=1\
               """
    end

    test "a recursive one is named, and printed once below" do
      schema = %{value: T.integer(), children: T.list(T.ref(:root))}

      assert Rupa.explain(schema) ==
               """
               object (2 fields, unknown: strip)
                 "children" -> :children list of
                   ref :root (recursive)
                 "value" -> :value       integer

               defs :root
                 object (2 fields, unknown: strip)
                   "children" -> :children list of
                     ref :root (recursive)
                   "value" -> :value       integer\
               """
    end
  end

  describe "explain/1" do
    test "takes a codec as well as a schema" do
      codec = Rupa.compile!(T.string())
      assert Rupa.explain(codec) == Rupa.explain(T.string())
    end

    test "an atom that is not a generated codec is read as a schema" do
      assert_raise Rupa.SchemaError, fn -> Rupa.explain(:nope) end
    end

    test "a schema it cannot stage raises rather than printing nonsense" do
      assert_raise Rupa.SchemaError, fn -> Rupa.explain(T.string(format: :ssn)) end
    end
  end

  test "a codec inspects as its root node" do
    assert inspect(Rupa.compile!(%{a: T.string()})) ==
             "#Rupa.Codec<object (1 field, unknown: strip)>"
  end
end

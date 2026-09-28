# dev/example.exs — what Rupa looks like in action.
#
#     mix run dev/example.exs
#
# One section per milestone, and the acceptance test for each: a milestone is done when its
# section runs top to bottom without an exception and the output matches the comments beside
# it. Nothing aspirational lives here — this file only ever holds code that actually runs.

alias Rupa.Schema
alias Rupa.T

# =============================================
# M1.1 — a schema is data
# =============================================
#
# `Rupa.T` functions are constructors, nothing more.

IO.inspect(T.string(min: 1), label: "T.string/1 returns")
# => {:string, [min: 1]}

address = %{
  street: T.string(min: 1),
  city: T.string(),
  country: T.string(len: 2),
  unit: T.optional(T.string())
}

# A bare map is an object, so the map above and this term are the same schema:
true =
  Schema.normalize(address) ==
    {:object,
     %{
       street: {:string, [min: 1]},
       city: {:string, []},
       country: {:string, [len: 2]},
       unit: {:optional, {:string, []}, []}
     }, []}

# Options come back sorted, so how you spelled them does not change the term — and two
# spellings of one schema hash the same, which is what `as:` idempotence will key on in M3.
true = T.string(max: 5, min: 1) == T.string(min: 1, max: 5)

# =============================================
# M1.2 — fields are required by default
# =============================================
#
# Serde and Pydantic, not Ecto. Object-level options hang off `T.object/2`; a
# bare map means "all defaults".

user =
  T.object(
    %{
      id: T.uuid(),
      first_name: T.string(min: 1),
      last_name: T.string(min: 1),
      email: T.email(),
      age: T.optional(T.integer(gte: 0, lte: 150)),
      nickname: T.nullable(T.string()),
      role: T.enum([:admin, :member, :guest], default: :member),
      addresses: T.list(address, max: 5),
      created_at: T.datetime()
    },
    unknown: :error
  )

# Three states, kept apart on purpose:
#
#   required           present, and not null
#   T.optional/2       the KEY may be absent — decodes to no key at all, not to nil
#   T.nullable/2       the VALUE may be null — decodes to nil
#   default:           fires on absent only; an explicit null is never replaced
#
# `:age` may be missing. `:nickname` must be there and may be null. `:role` may be missing and
# becomes :member. `:first_name` is required, because nothing says otherwise.

# =============================================
# M1.3 — validate/1 is the judge
# =============================================
#
# The constructors never are.

{:ok, ^user} = Schema.validate(user)

{:error, errors} =
  Schema.validate(%{
    a: T.string(format: :ssn),
    b: T.integer(gte: 5, lte: 2),
    c: %{d: T.list(T.optional(T.string()))}
  })

IO.inspect(Enum.map(errors, &{&1.path, &1.code}), label: "validate/1 found")

# => [
# =>   {[:a], :unknown_format},
# =>   {[:b], :contradictory_bounds},
# =>   {[:c, :d, :of], :misplaced_optional}
# => ]

IO.puts(Rupa.Error.message(hd(errors)))
# => :ssn is not one of Rupa's built-in formats

IO.puts(Rupa.Error.pointer(List.last(errors)))
# => /c/d/of

# Every problem in the tree at once, and never a function anywhere in it:
{:error, [%{code: :function_in_schema}]} = Schema.validate(%{a: T.string(default: fn -> 1 end)})

# An option that can only mean something on an object field -- default:, from:, to: -- is
# refused anywhere else rather than carried along and ignored:
{:error, [%{code: :misplaced_default}]} = Schema.validate(T.list(T.string(default: "x")))

# =============================================
# M1.4 — recursion is a named ref
# =============================================
#
# The same shape as JSON Schema's $ref/$defs, so it round-trips, prints, and
# hashes like everything else.

tree = %{value: T.integer(), children: T.list(T.ref(:root))}
{:ok, _} = Schema.validate(tree)

forest =
  T.object(
    %{name: T.string(), trees: T.list(T.ref(:tree))},
    defs: %{tree: %{value: T.integer(), children: T.list(T.ref(:tree))}}
  )

{:ok, _} = Schema.validate(forest)

# A ref with nothing to resolve against is a schema error, not a decode-time surprise:
{:error, [%{code: :unresolved_ref}]} = Schema.validate(T.ref(:nowhere))

# =============================================
# M1.5 — composition
# =============================================
#
# Schemas are maps, so most of this is honest map work.

create_params = T.pick(user, [:first_name, :last_name, :email])
public_user = T.omit(user, [:email])
patch_params = T.partial(user)
admin = T.merge(user, %{permissions: T.list(T.string())})

for schema <- [create_params, public_user, patch_params, admin] do
  {:ok, _} = Schema.validate(schema)
end

{:object, fields, _opts} = patch_params
IO.inspect(fields.first_name, label: "T.partial/1 made :first_name")
# => {:optional, {:string, [min: 1]}, []}

# `:role` had a default, so it was never required, so partial/1 left it alone:
IO.inspect(fields.role, label: "T.partial/1 left :role")
# => {:enum, [:admin, :member, :guest], [default: :member]}

# =============================================
# M1.6 — a schema is a tree you can rewrite
# =============================================
#
# Because it is only ever data.

widened =
  Schema.walk(user, fn
    {:integer, opts} -> {:float, opts}
    node -> node
  end)

{:object, widened_fields, _opts} = widened
IO.inspect(widened_fields.age, label: "walk/2 widened :age")
# => {:optional, {:float, [gte: 0, lte: 150]}, []}

# =============================================
# M2.1 — compile once, decode many times
# =============================================
#
# The schema is walked here and never again: wire keys, enum tables, defaults,
# regexes and refs are all resolved at this point.

codec = Rupa.compile!(user)

params = %{
  "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "first_name" => "Ada",
  "last_name" => "Lovelace",
  "email" => "ada@example.com",
  "nickname" => nil,
  "addresses" => [%{"street" => "1 Jl. Gandaria", "city" => "Jakarta", "country" => "ID"}],
  "created_at" => "2026-09-16T10:00:00Z"
}

{:ok, decoded} = Rupa.decode(codec, params)

IO.inspect(Map.take(decoded, [:first_name, :role, :nickname, :created_at]),
  label: "decode/2 returned"
)

# => %{
# =>   created_at: ~U[2026-09-16 10:00:00Z],
# =>   first_name: "Ada",
# =>   nickname: nil,
# =>   role: :member
# => }

# Keys are atoms, but only ever atoms interned from the schema at compile time. A wire key the
# schema does not name is stripped or rejected, never converted, so there is no way to exhaust
# the atom table with wire data.
false = Map.has_key?(decoded, :age)
true = Rupa.valid?(codec, params)

# Every kind in the vocabulary compiles. What a schema cannot say, it says at compile time:
{:error, [%{code: :unknown_format}]} = Rupa.compile(%{a: T.string(format: :ssn)})

# =============================================
# M2.2 — errors carry a path and a stable code
# =============================================
#
# Messages render on demand. A successful decode never builds a string.

bad = %{params | "addresses" => [%{"street" => "", "city" => "X", "country" => "IDN"}]}

{:error, [one]} = Rupa.decode(codec, bad)
IO.inspect({one.path, one.code}, label: "on_error: :halt gave")
# => {[:addresses, 0, :country], :len}

{:error, all} = Rupa.decode(codec, bad, on_error: :collect)
IO.inspect(Enum.map(all, &{&1.path, &1.code}), label: "on_error: :collect gave")
# => [{[:addresses, 0, :country], :len}, {[:addresses, 0, :street], :min}]

IO.puts(Rupa.Error.message(one))
# => must be exactly 2 characters

IO.puts(Rupa.Error.pointer(one))
# => /addresses/0/country

# `unknown: :error` on the object means a key nobody asked for is a failure, not a shrug:
{:error, [%{code: :unknown_key}]} = Rupa.decode(codec, Map.put(params, "nickname2", 1))

# =============================================
# M2.3 — look at what it compiled to
# =============================================
#
# The thing a macro can never give you. This prints the IR, so it is the same
# text whichever backend you compiled to.

IO.puts(Rupa.explain(Rupa.compile!(T.pick(user, [:id, :age, :role, :addresses]))))

# => object (4 fields, unknown: error)
# =>   "addresses" -> :addresses list max=5 of
# =>     object (4 fields, unknown: strip)
# =>       "city" -> :city       string
# =>       "country" -> :country string len=2
# =>       "street" -> :street   string min=1
# =>       "unit" -> :unit       optional string
# =>   "age" -> :age             optional integer gte=0 lte=150
# =>   "id" -> :id               string format=uuid
# =>   "role" -> :role           optional default=:member const :admin | :member | :guest

# =============================================
# M2.4 — recursion decodes to any depth
# =============================================
#
# A ref that is not on a cycle is inlined at staging and leaves no trace. One
# that is stays a node, and that is the only lookup a decode ever does.

tree_codec = Rupa.compile!(tree)

{:ok, nested} =
  Rupa.decode(tree_codec, %{
    "value" => 1,
    "children" => [%{"value" => 2, "children" => []}]
  })

IO.inspect(nested, label: "a recursive decode")
# => %{children: [%{children: [], value: 2}], value: 1}

{:error, [deep]} = Rupa.decode(tree_codec, %{"value" => 1, "children" => [%{"children" => []}]})

IO.inspect({deep.path, deep.code}, label: "and a path through it")
# => {[:children, 0, :value], :required}

# =============================================
# M3.1 — name a codec and it becomes a module
# =============================================
#
# You name the schemas that are static and long-lived, which is exactly when
# codegen pays for itself, so the fast path is the one you reach by default.

{:ok, MyApp.Codecs.User} = Rupa.compile(user, as: MyApp.Codecs.User)

# A handle, not an API: it is always reached through Rupa.decode/3.
{:ok, ^decoded} = Rupa.decode(MyApp.Codecs.User, params)

# Both backends are staged by the same pass and decode to the same value — including the
# errors, down to the path and the code. The test suite asserts that on every case it has.
{:error, [^one]} = Rupa.decode(MyApp.Codecs.User, bad)

# Naming it again with the same schema is a lookup, not a recompile:
{:ok, MyApp.Codecs.User} = Rupa.compile(user, as: MyApp.Codecs.User)
false = :erlang.check_old_code(MyApp.Codecs.User)

# Naming it with a different one is refused, rather than swapping the codec underneath code
# that is already using it. `force: true` replaces it, and is for dev and test.
{:error, [clash]} = Rupa.compile(%{a: T.string()}, as: MyApp.Codecs.User)
IO.puts(Rupa.Error.message(clash))

# => MyApp.Codecs.User is already a codec for a different schema;
# =>   pass force: true to replace it

# =============================================
# M3.2 — the IR is what both backends read
# =============================================
#
# So explain/1 prints the same thing either way, and a recursive ref that the
# closure tree resolves through a table is a direct call here.

true = Rupa.explain(MyApp.Codecs.User) == Rupa.explain(user)

{:ok, MyApp.Codecs.Tree} = Rupa.compile(tree, as: MyApp.Codecs.Tree)

{:ok, nested_again} =
  Rupa.decode(MyApp.Codecs.Tree, %{
    "value" => 1,
    "children" => [%{"value" => 2, "children" => []}]
  })

IO.inspect(nested_again == nested, label: "both backends, same tree")
# => true

# =============================================
# M4.1 — encode is the inverse
# =============================================
#
# Both backends have one, and they agree, the same way decode does.

{:ok, wire} = Rupa.encode(codec, decoded)

IO.inspect(Map.take(wire, ["first_name", "role", "created_at"]), label: "encode/2 returned")

# => %{
# =>   "created_at" => "2026-09-16T10:00:00Z",
# =>   "first_name" => "Ada",
# =>   "role" => "member"
# => }

# Inverse means this, precisely: encode a decoded value, decode it again, get the value back.
{:ok, ^decoded} = Rupa.decode(codec, wire)
{:ok, ^wire} = Rupa.encode(MyApp.Codecs.User, decoded)

# It is not the identity on the wire, and should not be: `role` was absent from the request and
# came back carrying its default, which is the whole point of a default.
false = Map.has_key?(params, "role")
true = Map.has_key?(wire, "role")

# =============================================
# M4.2 — what encode checks, and what it leaves
# =============================================
#
# Types and formats, because it has to look at those anyway to turn a DateTime
# back into a string. Constraints are not re-run: decode already bought them.

{:error, [wrong]} = Rupa.encode(codec, %{decoded | created_at: "already a string"})
IO.inspect({wrong.path, wrong.code}, label: "encode/2 refused")
# => {[:created_at], :format}

# `:first_name` is `min: 1`, and encoding does not look:
{:ok, _} = Rupa.encode(codec, %{decoded | first_name: ""})

# =============================================
# M4.3 — generators, for the property that says it
# =============================================
#
# `Rupa.Gen` lives behind an optional `stream_data` dependency: add that to your own deps and
# a schema becomes a generator of *decoded* values. This is the property test/rupa/gen_test.exs
# runs a thousand times per type, on both backends, written out once.

sample = Enum.take(Rupa.Gen.stream(codec), 250)

# Every one of them survives the trip out to the wire and back.
true =
  Enum.all?(sample, fn value ->
    {:ok, out} = Rupa.encode(codec, value)
    Rupa.decode(codec, out) == {:ok, value}
  end)

IO.inspect(length(sample), label: "round-tripped")
# => 250

# Decoded means decoded: a `DateTime`, not the string it came from, and an atom, not its wire
# value. A field carrying a default is always generated, because leaving it out would let
# decoding fill it in and hand back a value the generator never produced.
[first | _] = sample

IO.inspect({is_struct(first.created_at, DateTime), first.role in [:admin, :member, :guest]},
  label: "generated a decoded value"
)

# => {true, true}

# What it cannot generate honestly it refuses, rather than skipping the constraint and passing
# a property that never tested it.
refused =
  try do
    Rupa.Gen.stream(T.string(pattern: "^[a-z]+$"))
  rescue
    error in ArgumentError -> Exception.message(error)
  end

IO.inspect(String.starts_with?(refused, "cannot generate values for pattern:"),
  label: "a pattern is refused"
)

# => true

# =============================================
# M5.1 — the wire has its own names
# =============================================
#
# A field's name is an atom and its wire key is a string, and by default the
# second is the first spelled out. Four options move that apart, all of them
# spent at compile time.

api_user =
  T.object(
    %{
      first_name: T.string(min: 1),
      last_name: T.string(min: 1),
      signed_up_at: T.datetime(),
      home_address: T.optional(%{post_code: T.string(len: 5)})
    },
    rename_all: :camelCase
  )

api_codec = Rupa.compile!(api_user)

{:ok, ada} =
  Rupa.decode(api_codec, %{
    "firstName" => "Ada",
    "lastName" => "Lovelace",
    "signedUpAt" => "2026-09-16T10:00:00Z"
  })

IO.inspect(Map.take(ada, [:first_name, :signed_up_at]), label: "camelCase in")

# => %{first_name: "Ada", signed_up_at: ~U[2026-09-16 10:00:00Z]}

# It reads the field name as words and writes them back, so it works whichever style the atom
# was written in — and it applies to the object that declares it, not to the objects inside.
# `:home_address` was renamed; `:post_code`, one level down, was not.
{:error, [%{path: [:home_address, :post_code], code: :required}]} =
  Rupa.decode(api_codec, %{
    "firstName" => "Ada",
    "lastName" => "L",
    "signedUpAt" => "2026-09-16T10:00:00Z",
    "homeAddress" => %{}
  })

# A whole tree in one style is a rewrite, because a schema is only ever data:
deep =
  Schema.walk(api_user, fn
    {:object, fields, opts} -> {:object, fields, Keyword.put(opts, :rename_all, :camelCase)}
    node -> node
  end)

{:ok, _} =
  Rupa.decode(Rupa.compile!(deep), %{
    "firstName" => "Ada",
    "lastName" => "L",
    "signedUpAt" => "2026-09-16T10:00:00Z",
    "homeAddress" => %{"postCode" => "12345"}
  })

# =============================================
# M5.2 — one field at a time, and the other side of the map
# =============================================
#
# `from:` and `to:` override `rename_all:` for a single field. Give one and the
# other follows it, so a field you renamed by hand still round-trips.

renamed = Rupa.compile!(%{id: T.uuid(), last_name: T.string(from: "surname")})

{:ok, one} =
  Rupa.decode(renamed, %{"id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8", "surname" => "L"})

{:ok, back} = Rupa.encode(renamed, one)

IO.inspect(Map.keys(back), label: "from: renames both directions")
# => ["id", "surname"]

# Giving *both*, naming different keys, is how you read an old name and write a new one. It is
# the one thing in Rupa that makes encode stop being decode's inverse, and it takes saying so.
migrating = Rupa.compile!(%{email: T.email(from: "e_mail", to: "email")})

{:ok, decoded_mail} = Rupa.decode(migrating, %{"e_mail" => "ada@example.com"})
IO.inspect(Rupa.encode!(migrating, decoded_mail), label: "an old name in, a new name out")
# => %{"email" => "ada@example.com"}

# `keys:` is the decoded side rather than the wire: it changes the key's type, never its name.
string_keyed =
  Rupa.compile!(T.object(%{first_name: T.string()}, rename_all: :camelCase, keys: :string))

IO.inspect(Rupa.decode!(string_keyed, %{"firstName" => "Ada"}), label: "keys: :string decoded")
# => %{"first_name" => "Ada"}

# And encode reads back whichever key it wrote:
%{"firstName" => "Ada"} = Rupa.encode!(string_keyed, %{"first_name" => "Ada"})

# explain/1 shows all of it, because staging is where it was spent:
IO.puts(
  Rupa.explain(
    T.object(%{first_name: T.string(), user_id: T.string(from: "id", to: "userId")},
      rename_all: :camelCase
    )
  )
)

# => object (2 fields, unknown: strip)
# =>   "firstName" -> :first_name   string
# =>   "id" -> :user_id -> "userId" string

# Two fields landing on one wire key is a schema the wire cannot express, so it is refused
# at compile time rather than one of them quietly winning:
{:error, [%{code: :duplicate_wire_key, meta: %{key: "id"}}]} =
  Rupa.compile(%{id: T.string(), user_id: T.string(from: "id")})

# And `from:`/`to:` belong to the object field, not to the type, so anywhere else says so:
{:error, [%{code: :misplaced_rename}]} = Rupa.compile(T.list(T.string(from: "a")))

# =============================================
# M6.1 — a union you can pattern match on
# =============================================
#
# `T.tagged/3` is the default, because it reads one key and calls one branch
# however deep it goes. It decodes to `{tag, value}`, with the tag interned from
# the branch name at compile time.

shape =
  T.tagged(:type, %{
    "circle" => %{r: T.float(gt: 0)},
    "rect" => %{w: T.float(gt: 0), h: T.float(gt: 0)}
  })

shapes = Rupa.compile!(shape)

{:ok, circle} = Rupa.decode(shapes, %{"type" => "circle", "r" => 2.0})
IO.inspect(circle, label: "a tagged decode")
# => {:circle, %{r: 2.0}}

# Which is one case away from being handled:
area =
  case circle do
    {:circle, %{r: r}} -> :math.pi() * r * r
    {:rect, %{w: w, h: h}} -> w * h
  end

IO.inspect(Float.round(area, 3), label: "and one case away from an area")
# => 12.566

# Encoding puts the tag back where it found it, so this is still a round trip:
IO.inspect(Rupa.encode!(shapes, circle), label: "encode/2 returned")
# => %{"r" => 2.0, "type" => "circle"}

# A tag nobody declared, and a tag that is not there, are both errors with the tag's own path:
{:error, [%{path: [:type], code: :unknown_tag}]} = Rupa.decode(shapes, %{"type" => "triangle"})
{:error, [%{path: [:type], code: :required}]} = Rupa.decode(shapes, %{"r" => 2.0})

# Inside the branch, the path is the branch's own — the tag is not a segment:
{:error, [%{path: [:r], code: :gt}]} = Rupa.decode(shapes, %{"type" => "circle", "r" => 0.0})

# =============================================
# M6.2 — the tag beside the value, and recursion through it
# =============================================
#
# `content:` is serde's adjacent tagging: the tag in one key, the branch in
# another. The branch is then free to be any schema at all, not just an object.

event =
  Rupa.compile!(
    T.tagged(:kind, %{"at" => T.datetime(), "count" => T.integer(gte: 0)}, content: :value)
  )

IO.inspect(Rupa.decode!(event, %{"kind" => "at", "value" => "2026-09-16T10:00:00Z"}),
  label: "adjacently tagged"
)

# => {:at, ~U[2026-09-16 10:00:00Z]}

{:error, [%{path: [:value], code: :type}]} =
  Rupa.decode(event, %{"kind" => "count", "value" => "x"})

# A branch can recurse, and tagged dispatch stays one lookup however deep it goes:
tree_codec =
  Rupa.compile!(
    T.tagged(:type, %{
      "leaf" => %{v: T.integer()},
      "node" => %{kids: T.list(T.ref(:root))}
    })
  )

{:ok, nested_tree} =
  Rupa.decode(tree_codec, %{
    "type" => "node",
    "kids" => [%{"type" => "leaf", "v" => 1}, %{"type" => "leaf", "v" => 2}]
  })

IO.inspect(nested_tree, label: "a recursive tagged decode")
# => {:node, %{kids: [leaf: %{v: 1}, leaf: %{v: 2}]}}

IO.puts(Rupa.explain(event))

# => tagged tag=:kind content=:value (2 branches) of
# =>   "at" -> :at       string format=date_time
# =>   "count" -> :count integer gte=0

# =============================================
# M6.3 — untagged, and what it costs
# =============================================
#
# No tag to read, so every variant is tried in the order you wrote them and the
# first that takes the value wins. That is opt-in, because it is the one shape
# in the vocabulary whose cost doubles with depth.

{:error, [%{code: :untagged_union_needs_opt_in}]} =
  Schema.validate(T.union([T.integer(), T.string()]))

either = Rupa.compile!(T.union([T.integer(), T.string(min: 1)], tag: :none))

IO.inspect({Rupa.decode!(either, 1), Rupa.decode!(either, "x")}, label: "first variant that fits")
# => {1, "x"}

# When none of them fits, you get one error rather than every variant's — you did not choose a
# variant, so a list of what each one disliked is not the answer to anything:
{:error, [none]} = Rupa.decode(either, true)
IO.puts(Rupa.Error.message(none))
# => none of the 2 variants of this union accepted true

# And nesting one inside another is the case that doubles, so staging says so once, on stderr:
_nested =
  Rupa.compile(T.union([T.union([T.integer(), T.string()], tag: :none), T.boolean()], tag: :none))

# => warning: this schema nests untagged unions, so decoding costs one attempt per variant
# =>   per level and doubles with depth. Rupa.T.tagged/3 stays flat at any depth; if you
# =>   meant the untagged one, nothing here is wrong.
#
# `mix run bench/union.exs` is that sentence with numbers under it.

# =============================================
# M7.1 — JSON in
# =============================================
#
# `decode_json/3` is bytes in, decoded value out. It parses with OTP's `:json`
# and then decodes, which is what the name promises and no more: a value's key
# does not reach `:json`'s callbacks until after that value is built, so an
# object's fields cannot be schema-directed while parsing. `Rupa.Json` carries
# the full reading of the API, and `mix run bench/json.exs` carries the numbers.

event =
  Rupa.compile!(
    T.object(
      %{
        id: T.uuid(),
        at: T.datetime(),
        payload: T.tagged(:kind, %{"click" => T.object(%{x: T.integer(), y: T.integer()})}),
        labels: T.list(T.string(min: 1)),
        note: T.nullable(T.string())
      },
      rename_all: :camelCase
    )
  )

text = """
{"id": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
 "at": "2026-09-16T10:00:00Z",
 "payload": {"kind": "click", "x": 3, "y": 4},
 "labels": ["beta"],
 "note": null}
"""

IO.inspect(Rupa.decode_json!(event, text), label: "decoded from text")
# => %{id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8", at: ~U[2026-09-16 10:00:00Z],
# =>   payload: {:click, %{x: 3, y: 4}}, labels: ["beta"], note: nil}

# A JSON null is `nil`, not the atom `:null` — three states are present, absent
# and null, and this is the one that means null.
{:ok, nil} = Rupa.decode_json(Rupa.compile!(T.nullable(T.integer())), "null")

# Text that is not JSON is an error like any other, with a path and a code, so
# a request handler has one shape to match on rather than a rescue:
{:error, [broken]} = Rupa.decode_json(event, "{oops")
IO.puts(Rupa.Error.message(broken))
# => invalid JSON: unexpected byte 0x6F

# =============================================
# M7.2 — JSON out, in one pass
# =============================================
#
# `encode_json/3` is the half that fuses. `encode/3` builds a wire map and a
# JSON encoder then walks it; this walks your value once and emits the bytes.
# Wire keys, enum values and a tagged branch's whole `"kind":"click"` were
# rendered to binaries while the schema was staged, so what is left at run time
# is escaping the strings you actually carry.

decoded = Rupa.decode_json!(event, text)

IO.puts(Rupa.encode_json!(event, decoded))
# => {"at":"2026-09-16T10:00:00Z","id":"6ba7b810-9dad-11d1-80b4-00c04fd430c8",
# =>  "labels":["beta"],"note":null,"payload":{"kind":"click","x":3,"y":4}}

# The result is iodata, which is what a socket or a `Plug.Conn` wants. Fields
# come out in the schema's order rather than a map's, which is the one visible
# difference from going the long way round:
true = is_list(Rupa.encode_json!(event, decoded))

# It is still the inverse, so the round trip closes on the text as it does on
# the term:
written = IO.iodata_to_binary(Rupa.encode_json!(event, decoded))
^decoded = Rupa.decode_json!(event, written)

# And it checks what `encode/3` checks — the type, and the format that turns a
# `DateTime` back into a string — with the same errors at the same paths:
{:error, [%{path: [:at], code: :format}]} =
  Rupa.encode_json(event, %{decoded | at: "already a string"})

IO.puts("encode_json/3 refused at :at")

# =============================================
# M8.1 — field names you did not choose
# =============================================
#
# A field's name is an atom when you know the fields as you write the code,
# which is most of the time. It can also be a string, and that is for an object
# whose names came from somewhere else — a JSON Schema you fetched, a form
# someone defined at runtime. Nothing about such a document then has to become
# an atom, which is what keeps the atom table out of reach of the wire.

form_schema =
  {:object,
   %{
     "full_name" => T.string(min: 1),
     "signed_up_at" => T.datetime(),
     "score" => T.optional(T.integer(gte: 0))
   }, [rename_all: :camelCase]}

form = Rupa.compile!(form_schema)

IO.inspect(Rupa.decode!(form, %{"fullName" => "Ada", "signedUpAt" => "2026-09-16T10:00:00Z"}),
  label: "string names decode to string keys"
)

# => %{"full_name" => "Ada", "signed_up_at" => ~U[2026-09-16 10:00:00Z]}

# Everything else is unchanged: renaming, optional, defaults, the error paths —
# which now name the field the way the schema spells it.
{:error, [wrong]} = Rupa.decode(form, %{"fullName" => "", "signedUpAt" => "2026-09-16T10:00:00Z"})
IO.inspect({wrong.path, wrong.code}, label: "the path names the field")
# => {["full_name"], :min}

# `keys:` is the one place a name becomes an atom, and you have to ask for it.
# That is a name in a schema, not a key off a document — the same rule every
# other atom in a schema already follows.
atoms = Rupa.compile!({:object, %{"full_name" => T.string()}, [keys: :atom]})
IO.inspect(Rupa.decode!(atoms, %{"full_name" => "Ada"}), label: "keys: :atom, asked for")
# => %{full_name: "Ada"}

# What you cannot do is mix them in one object: `keys:` would have nothing
# coherent to default to, and the decoded map's shape would depend on which
# field you were looking at.
{:error, [%{code: :mixed_field_names}]} =
  Schema.validate({:object, %{:a => T.string(), "b" => T.string()}, []})

IO.puts("mixing atoms and strings in one object is refused")

# =============================================
# M8.2 — the same schema as a JSON Schema
# =============================================
#
# `encode/1` is total, because Rupa's vocabulary is a subset of JSON Schema's
# declarative one. It stages the schema first, so what the document describes is
# the document: the property names are the wire keys, not the field names.

alias Rupa.JsonSchema

published = JsonSchema.encode!(form_schema)

IO.inspect(Map.take(published, ["type", "required"]), label: "the wire, described")
# => %{"type" => "object", "required" => ["fullName", "signedUpAt"]}

IO.inspect(published["properties"]["signedUpAt"], label: "a format keeps its name")
# => %{"type" => "string", "format" => "date-time"}

# `decode/1` goes the other way and interns nothing: the object it hands back is
# named with strings, so no property name in a document you did not write ever
# becomes an atom. That is what M8.1 was for.
{:ok, recovered} = JsonSchema.decode(published)
IO.inspect(JsonSchema.encode!(recovered) == published, label: "the document closes on itself")
# => true

# What it will not do is fail quietly. A keyword Rupa has no answer for is an
# error with the path to it, never a constraint dropped on the floor:
{:error, [unsupported]} = JsonSchema.decode(%{"allOf" => [%{"type" => "string"}]})
IO.puts(Rupa.Error.message(unsupported))
# => allOf has no equivalent in Rupa's vocabulary, which is JSON Schema's declarative subset

# Two of Rupa's own constructs encode but do not come back, and for one reason:
# both would have to intern an atom from the document to exist at all. A tagged
# union's tag is an atom, and a recursive ref needs a $defs name.
{:error, [%{code: :unsupported_keyword}]} =
  JsonSchema.decode(JsonSchema.encode!(T.tagged(:kind, %{"circle" => %{r: T.float()}})))

# A $ref that is *not* on a cycle needs no name, so it is inlined and works:
{:ok, inlined} =
  JsonSchema.decode(%{
    "type" => "object",
    "properties" => %{"a" => %{"$ref" => "#/$defs/s"}},
    "required" => ["a"],
    "$defs" => %{"s" => %{"type" => "string", "minLength" => 2}}
  })

IO.inspect(inlined, label: "a $ref off a cycle is inlined")
# => {:object, %{"a" => {:string, [min: 2]}}, []}

# The official JSON-Schema-Test-Suite is vendored and runs on every build.
# `Rupa.JsonSchema` lists every place Rupa and the spec disagree, and there are
# four of them.

# =============================================
# M8.3 — a format means what JSON Schema says it means
# =============================================
#
# The suite's format corpus is vendored as well, and every string case in it
# agrees with Rupa. A time carries an offset and decodes to UTC, the way a
# date-time does:

stamp = Rupa.compile!(%{at: T.time(), took: T.duration()})

{:ok, stamped} = Rupa.decode(stamp, %{"at" => "08:30:00+07:00", "took" => "PT1H30M"})
IO.inspect(stamped.at, label: "a time, in UTC")
# => ~T[01:30:00]

IO.inspect(Rupa.encode!(stamp, stamped), label: "and back")
# => %{"at" => "01:30:00Z", "took" => "PT1H30M"}

# `email` is RFC 5321's Mailbox, quoted local parts and address literals
# included, and `hostname` follows an xn-- label down to the Unicode it encodes:
# café is xn--caf-dma, and the decomposed spelling of the same word is refused.
{:ok, _} = Rupa.decode(Rupa.compile!(T.email()), ~s("ada lovelace"@[192.168.0.1]))
{:ok, _} = Rupa.decode(Rupa.compile!(T.hostname()), "xn--caf-dma.example")
{:error, [%{code: :format}]} = Rupa.decode(Rupa.compile!(T.hostname()), "xn--cafe-yvc.example")

# =============================================
# M9.1 — decoding straight into structs
# =============================================
#
# `into:` is an option on the object, not on the compile, so it nests: an
# address three levels down becomes its own struct the same way the root does.
# A module name is an atom, so the schema still prints, hashes and embeds as a
# literal — what it adds is a soft dependency on that module existing.

defmodule Example.Address do
  @moduledoc false
  defstruct [:city, :postcode]
end

defmodule Example.Account do
  @moduledoc false
  defstruct [:id, :handle, :address, :nickname, tier: :free]
end

account =
  T.object(
    %{
      id: T.uuid(),
      handle: T.string(min: 1),
      tier: T.enum([:free, :paid], default: :free),
      nickname: T.optional(T.nullable(T.string())),
      address:
        T.object(%{city: T.string(), postcode: T.optional(T.string())}, into: Example.Address)
    },
    into: Example.Account
  )

{:ok, accounts} = Rupa.compile(account)

decoded =
  Rupa.decode!(accounts, %{
    "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "handle" => "owl",
    "address" => %{"city" => "Kyoto"}
  })

IO.inspect(decoded, label: "decoded")
# => %Example.Account{
#      id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
#      handle: "owl",
#      address: %Example.Address{city: "Kyoto", postcode: nil},
#      nickname: nil,
#      tier: :free
#    }

# A struct has every key always, so `into:` is the one place present, absent and
# null stop being three states. An absent optional key leaves the module's own
# defstruct default behind — `nil`, for a struct `mix rupa.gen.struct` wrote — so
# an explicit null reaches the same value:
true =
  Rupa.decode!(accounts, %{
    "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
    "handle" => "owl",
    "nickname" => nil,
    "address" => %{"city" => "Kyoto"}
  }) == decoded

# Encoding reads it back the same way round, so the round trip still closes: what
# encode writes as absent is whatever decode would have left there, which is the
# module's own default rather than `nil` in particular. Give a struct you wrote
# yourself a default of its own and that is what stands for absent instead.
IO.inspect(Rupa.encode!(accounts, decoded), label: "encoded")
# => %{
#      "address" => %{"city" => "Kyoto"},
#      "handle" => "owl",
#      "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
#      "tier" => "free"
#    }

true = Rupa.decode!(accounts, Rupa.encode!(accounts, decoded)) == decoded

# Both backends build the same struct — the closure tree by merging onto a base
# built when the codec was, the generated module from a map literal baked in
# while it was being generated.
{:ok, named} = Rupa.compile(account, as: Example.Codecs.Account, force: true)
true = Rupa.decode!(named, Rupa.encode!(named, decoded)) == decoded

# Encoding is by name, not by shape: a map with the right keys is not the struct
# the schema says this is.
{:error, [wrong]} = Rupa.encode(accounts, %{handle: "owl"})
IO.puts(Rupa.Error.message(wrong))
# => expected %Example.Account{}, got %{handle: "owl"}

# =============================================
# M9.2 — the module has to be there, and has to fit
# =============================================
#
# `Rupa.compile/2` checks the module while it stages, against the keys the
# object actually decodes to — the names after rename_all:, from: and keys:
# have been spent. So renaming a field and forgetting to re-run
# `mix rupa.gen.struct` is a schema error naming the key, rather than a struct
# that quietly comes back with a default in it.

{:error, [stale]} =
  Rupa.compile(T.object(%{city: T.string(), country: T.string()}, into: Example.Address))

IO.puts(Rupa.Error.message(stale))

# => Example.Address's fields do not include :country; re-run mix rupa.gen.struct, or fix the schema

# Three of the object's own options cannot hold beside `into:`, because a struct
# has atom keys and every one of them always.
{:error, [%{code: :struct_keys}]} =
  Rupa.compile(T.object(%{city: T.string()}, into: Example.Address, keys: :string))

{:error, [%{code: :struct_keeps_unknown}]} =
  Rupa.compile(T.object(%{city: T.string()}, into: Example.Address, unknown: :keep))

# A string-named object is the one Rupa.JsonSchema.decode/1 produces, and it has
# to say `keys: :atom` before it can be a struct — the same opt-in M8.1 already
# makes you ask for, because it is the one place a name becomes an atom.
{:error, [%{code: :struct_keys}]} =
  Rupa.compile(T.object(%{"city" => T.string()}, into: Example.Address))

{:ok, _from_a_document} =
  Rupa.compile(T.object(%{"city" => T.string()}, into: Example.Address, keys: :atom))

# `explain/1` prints it beside the unknown-key policy, so what runs is visible
# on both backends.
IO.puts(Rupa.explain(T.object(%{city: T.string()}, into: Example.Address)))
# => object (1 field, unknown: strip, into: Example.Address)
# =>   "city" -> :city string

# A JSON Schema describes the wire, and `into:` is not on the wire — so the
# document it writes has no trace of it, and reading one back never names a
# module Rupa would have to invent.
{:ok, document} = Rupa.JsonSchema.encode(T.object(%{city: T.string()}, into: Example.Address))
IO.inspect(Map.take(document, ["type", "properties"]), label: "into: is not a wire concern")
# => %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}

# `mix rupa.gen.struct MyApp.Schemas.account` writes the modules above from the
# schema: one file per into:, a defstruct and a @type, and nothing that mentions
# Rupa. The loop is to change the schema, run it, and commit both.

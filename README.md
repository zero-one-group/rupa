<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/zero-one-group/rupa/main/assets/rupa-lockup-dark.svg">
    <img alt="Rupa" src="https://raw.githubusercontent.com/zero-one-group/rupa/main/assets/rupa-lockup.svg" width="360">
  </picture>
</p>

<p align="center">
  <a href="https://hex.pm/packages/rupa"><img alt="Hex version" src="https://img.shields.io/hexpm/v/rupa.svg"></a>
  <a href="https://rupa.hexdocs.pm"><img alt="Hexdocs" src="https://img.shields.io/badge/hex-docs-blue.svg"></a>
  <a href="https://github.com/zero-one-group/rupa/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/hexpm/l/rupa.svg"></a>
</p>

A macro-less, serde-like schema library for Elixir. Schemas are plain data.

```elixir
alias Rupa.T

schema = %{
  id: T.uuid(),
  name: T.string(min: 1),
  role: T.enum([:admin, :member], default: :member),
  signed_up_at: T.datetime(),
  address: T.optional(%{city: T.string(), post_code: T.string(len: 5)})
}

{:ok, codec} = Rupa.compile(schema)

Rupa.decode(codec, %{
  "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
  "name" => "Ada",
  "signed_up_at" => "2026-09-17T10:00:00Z"
})
#=> {:ok, %{
#     id: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
#     name: "Ada",
#     role: :member,
#     signed_up_at: ~U[2026-09-17 10:00:00Z]
#   }}
```

That schema is a term. It prints, it hashes with `:erlang.phash2/1`, you can build it at
runtime, pattern-match on it, rewrite it with `Rupa.Schema.walk/2`, and turn it into a JSON
Schema and back. There is no macro anywhere, and no function inside a schema either.

## The one idea

Serde gets its speed from doing the work at compile time. Macros are one way to reach compile
time; they are not the only one, and they cost you a schema you can print, compose, or step
through. Rupa separates the two: the schema stays an inspectable term, and a **staging pass**
turns it into something fast.

`Rupa.explain/1` prints what that pass produced — the thing a macro can never give you:

```elixir
Rupa.explain(%{tags: T.list(T.string(min: 1), max: 5)})
```

```
object (1 field, unknown: strip)
  "tags" -> :tags list max=5 of
    string min=1
```

Wire keys, the order fields are tried in, which refs were inlined and which survived as
recursion — all of it decided once, before any data arrives.

## Installation

```elixir
def deps do
  [{:rupa, "~> 0.1"}]
end
```

No required dependencies. `stream_data` is optional and only `Rupa.Gen` uses it. Elixir 1.18 or
newer on OTP 27 or newer — OTP 27 is the floor because `:json` is stdlib from there, and the
JSON edge is written against it with no fallback.

## What it does

**Two backends, one IR.** `compile(schema)` returns a closure tree, which is what you want for
a schema you did not know at boot — a per-tenant shape, a form someone defined at runtime, a
JSON Schema you fetched. `compile(schema, as: MyApp.Codecs.User)` generates a module, which is
what you want for one you did. Both are staged by the same pass and decode to the same value;
the choice is about cost, not behaviour.

**Decode and encode are inverses.** `decode(encode(decode(w))) == decode(w)`. Not the identity
on the wire, because an absent default comes back materialised — which is the point of a
default.

**JSON is a first-class edge.** `decode_json/3` takes text and `encode_json/3` writes iodata.
Encoding fuses: one walk of your value straight to bytes, with wire keys and enum values
rendered while the schema was staged. It comes in *under* serialising alone, because
`:json.encode/1` cannot know that this object's keys are the same seven strings every time.
Decoding does not fuse, and `Rupa.Json` says exactly why rather than pretending otherwise.

**JSON Schema, both directions.** `Rupa.JsonSchema.encode/1` writes draft 2020-12 and
`decode/1` reads it. The official test suite is vendored and runs on every build, so the four
places Rupa and the spec disagree are measured rather than asserted.

**Structs.** `T.object(%{...}, into: MyApp.User)` decodes into a struct, nested objects
included, and `mix rupa.gen.struct` writes the modules from the schema.

**Errors are structured and lazy.** `%Rupa.Error{path, code, meta}`; a message renders only
when you ask for one, so a successful decode never builds a string.

## What it does not do

The vocabulary is **JSON Schema's declarative subset and nothing more**. No refinements, no
transforms, no custom codecs, no user functions of any kind. If JSON Schema cannot say it, Rupa
cannot either — turning an integer into a `Money` is a plain function you call on the decoded
value.

That is the constraint everything else rests on. It is what makes "schemas are plain data"
literally true rather than nearly true, and it is what lets a schema hash, print, embed in
generated code as a literal, and round-trip through a document.

## How fast

Two tables, both reproducible from this repository, each with the machine it was taken on.

**In BEAM**, `mix run bench/compare.exs`, which also runs in CI and fails the build when the
budget stops holding. One wire map in, one validated typed value out, the same checks in every
row. 2026-09-22, macOS on Apple Silicon, OTP 29:

| | µs/op | reds/op | words/op | rel |
|---|---|---|---|---|
| hand-written | 0.380 | 11 | 42 | 1.00x |
| **Rupa, module backend** | **0.188** | **24** | **48** | **0.49x** |
| Rupa, closure backend | 0.478 | 120 | 188 | 1.26x |
| Ecto 3.14.2 embedded cast | 7.49 | 1264 | 1418 | 19.7x |
| Peri 0.11.2 | 7.47 | 1604 | 1656 | 19.7x |

Reductions are the column to read: 24 against 1264 and 1604, and 48 words against 1418 and
1656. Both of those hold across machines; a two-core cloud runner reports the same three
figures to the unit while its µs/op column disagrees by a factor of two — and on this run that
column puts the module backend under hand-written, which is the JIT on a hot loop rather than a
claim, since the same work costs it 24 reductions to hand-written's 11. `bench/BUDGET.md` is
where the budget lives and what a milestone has to change, with a reason, before it can move a
number.

**Across languages**, `bench/xlang/`, run by hand in a Docker image that pins every toolchain.
Bytes in, validated typed value out. 2026-09-17, M4 under Docker, arm64 Linux, 100k iterations
after a 200k warmup, best of 5 interleaved passes:

| | ns/op | spread | rel |
|---|---|---|---|
| serde_json 1.0 | 371 | 15.0% | 1.00x |
| Zod 4.6.5 | 920 | 1.5% | 2.48x |
| Malli 0.16.4 | 964 | 12.6% | 2.60x |
| **Rupa** | **1017** | **9.5%** | **2.74x** |
| pydantic-core 2.13.3 | 1291 | 3.3% | 3.48x |

`spread` is how far each column's worst pass landed above its best, and it is printed so the
table can say what it cannot tell you. Zod, Malli and Rupa sit within about ten percent of each
other, which is not more than the error bars around them, so read that band as a tie rather
than an order. The gap down to pydantic-core and the gap up to serde_json are both wider than
any spread here, and those are the two the table can actually support: 2.7x off Rust, ahead of
a compiled Rust validator behind a Python call.

`bench/xlang/README.md` says precisely what each column is allowed to do differently, which is
the part of a cross-language comparison that usually goes unsaid. It also documents the one
scheduler flag Rupa's column runs with, and the measurement that justifies it.

## Status

0.1.0 is the first release. The vocabulary is complete, both backends carry decode, encode and
encode-to-JSON, JSON text goes in and out, so does JSON Schema, objects decode into structs, and
every string format agrees with JSON Schema's official format corpus. Before 1.0 a minor version
may rename or remove; `CHANGELOG.md` gives each such change a one-line migration.

## Development

The pinned Elixir and OTP are in `.tool-versions`.

```bash
mix deps.get
mix check.all            # format, compile, credo --strict, coverage
mix docs                 # must emit no warnings
mix run dev/example.exs  # the acceptance test; one section per milestone
```

`dev/example.exs` is the spec. It grows with the library, every line of it runs, and its output
has to match the comments beside it.

The other benches are run by hand: `bench/decode.exs` for the budget, `bench/json.exs` for the
two JSON directions against their floors, `bench/union.exs` for the backtracking claim with
numbers under it.

## Name

`rupa` is Javanese (and Indonesian) for form or shape, from Sanskrit *rūpa*.
[`latu`](https://github.com/zero-one-group/latu), its sibling, is Javanese for *spark*.

## License

Apache-2.0. See [LICENSE](https://github.com/zero-one-group/rupa/blob/main/LICENSE).

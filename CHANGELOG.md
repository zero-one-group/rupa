# Changelog

Rupa follows [Semantic Versioning](https://semver.org). Before 1.0, a minor version may rename
or remove; each such change is listed here with the migration in one line.

## 0.1.0 — 2026-09-28

**M8c — every format means what JSON Schema's does.** The suite's `optional/format` corpus is
vendored for the ten formats Rupa has, and `test/rupa/format_suite_test.exs` runs every string
case in it through `Rupa.Format` and both backends: 474 of 474 agree, where 74 did not. Every
change is a tightening, and these are the ones a caller will notice:

  * `T.time()` needs an offset (`"10:00:00"` is an error) and decodes to UTC, as `T.datetime()`
    does. It encodes with a `Z`.
  * A leap second (`23:59:60`, in UTC) decodes to the second before it; `Calendar` has no 60.
  * `T.datetime()` and `T.date()` refuse a sign or a fifth digit on the year and a space for the
    `T`, and take `t` and `z` in lower case. A `DateTime` in another zone encodes in UTC, and a
    year outside 0000–9999 is refused in both directions.
  * `T.duration()` is RFC 3339 appendix A: no fractions, weeks only alone, units nested
    (`P1Y0M2D`, never `P1Y2D`). The encoder writes the zeros the grammar needs.
  * `T.email()` is RFC 5321's `Mailbox`. Quoted local parts, address literals and single-label
    domains are in; a leading, trailing or doubled dot, non-ASCII, and unquoted `;:(),` are out.
  * `T.hostname()` checks an `xn--` label as an IDNA2008 A-label (Punycode, NFC, RFC 5892's
    properties and contextual rules; not the Bidi rule), from a table `dev/idna/generate.exs`
    derives from Unicode 17.0.
  * `T.uri()` refuses malformed percent-encoding, `T.ipv4()` a leading `+`, `T.ipv6()` a zone id.

`T.email()` and `T.hostname()` are scanned rather than matched by a regex now, which makes them
three to five times faster.

**M10 — comparisons, docs, and everything but the publish.** Both remaining open items in the
design doc are settled, the README is no longer the one from M0, and there are now two
benchmark suites whose numbers anyone can reproduce.

**The identity.** `assets/` holds the lockup, mark, avatar and favicons: ꦫꦸꦥ in Hanacaraka
beside the Latin name, Latu's system in teal, every glyph outlined so no reader needs a Javanese
font. `dev/logo/build.py` draws all of it from two fonts; `assets/README.md` has the rules and
the palette. The README opens with the lockup and hexdocs gets the tile as logo and favicon.

**A generated codec's diagnostics are said again in terms of the schema.** `Rupa.compile/2`
wraps the codegen in `Code.with_diagnostics/1`, so `warning: this clause of defp j2/2 is never
used` no longer arrives in someone's boot log as itself. What comes out instead names the
codec, says which of the three walks wrote the code, points at `Rupa.explain/1`, and says what
the usual cause is — all in one warning per compile rather than one per finding, because a
schema that earns any of these usually earns four. Nothing is dropped: Rupa's own dead clauses
have been real bugs three milestones running.

The index that makes that possible is per direction, not per node. `Rupa.Codegen.module/3` now
returns `{ast, index}` where the index names every function the module defines. A map from a
function to a *node* would have meant threading a path through every clause of three
generators, and it would have bought less than it sounds: a definition only survives staging
when it is recursive, and the type checker does not report inside a recursive group at all.

**The JSON encoder stays unconditional.** It is about 30% of codegen on top of the other two
trees, and `bench/BUDGET.md` has the number, but an option is a thing to remember and a boot
bill of a second or two for fifty codecs belongs in the docs instead.

**`bench/compare.exs`, and it runs in CI.** Peri, Ecto's embedded cast, `:json.decode/1` as the
floor, both Rupa backends and hand-written, all on `bench/decode.exs`'s fixture with the same
checks in every row. On a two-core runner: 24 reductions per op against Peri's 1600 and Ecto's
1254, and 48 words against 1866 and 1515. It asserts rather than prints — the budget from
`bench/BUDGET.md` and a deliberately loose margin against the other two — and exits non-zero
when one stops holding, because a benchmark that only prints is one nobody reads until someone
happens to look.

**`bench/xlang/`** builds one Docker image with five runtimes and runs the same job in each:
bytes in, validated typed value out. serde_json, pydantic-core, Zod, Malli and Rupa, every
version pinned, every column documented as to what it is allowed to do differently — serde has
no declarative `min_length`, so that column validates by hand rather than dropping the
constraint. On the sandbox: serde_json 624 ns, Zod 1836, Rupa 2412, pydantic-core 2837. Zod
being above Rupa is a real result for V8 on a hot loop and is printed rather than left out.
Malli's column is written to the same protocol and has not been run, because Maven is not
reachable from where the rest of this was built; a column that will not run is named in the
output rather than quietly dropped.

**The README is now about the library rather than about the repository.** It had said "this
repository is the skeleton ... there is no public API behind them until M1" since M0. It now
opens with code that runs, says what the vocabulary deliberately refuses, and carries both
tables with the machine and date beside them.

**Docs pass.** Every public module is documented and grouped — "The API", "Exceptions" and
"Inside", so the staging pass stops sitting in the sidebar beside the constructors. Every
public function has a doctest or an example, except `Rupa.Closure.build_encoder/1` and
`build_json/1`, which are one-line cross-references to `build/1` on purpose. Doctests went from
65 to 76, mostly the ten format constructors, which are the most-used part of the API and had a
one-line description each.

`mix hex.build` ships 24 files: `lib/` including the Mix task, `.formatter.exs`, `mix.exs`,
README, LICENSE and CHANGELOG, with `stream_data` as the one optional requirement. Peri and
Ecto are `only: :dev` and appear nowhere in the package.

**M9 — structs, both ways.** `Rupa.T.object(%{...}, into: MyApp.User)` decodes that object into
a struct, and `mix rupa.gen.struct` writes the modules it names.

**`into:` is an option on the object, not on the compile**, which is what makes it compose: an
address three levels down becomes a `MyApp.Address` the same way the root becomes a
`MyApp.User`. A module name is an atom, so the schema still prints, hashes with
`:erlang.phash2/1` and embeds in generated code as a literal — and `as:` idempotence keys on
that hash, which a compile option would have quietly broken by letting two different codecs
collide on one name.

**The module has to be there, and has to fit.** Staging requires it to be loaded with a
`defstruct`, and to already have every key the object decodes to — the names after
`rename_all:`, `from:` and `keys:` have been spent, which is why the check happens after
staging rather than against what you wrote. So renaming a field and forgetting to re-run
`mix rupa.gen.struct` is `:struct_field_missing` naming the key, rather than a struct that
quietly comes back with a default in it. The new codes are `:not_a_struct`,
`:struct_field_missing`, `:struct_keys`, `:struct_keeps_unknown` and `:struct`.

**Three of the object's own options cannot hold beside it**, because a struct has atom keys and
every one of them always: `keys: :string`, `unknown: :keep`, and a string-named object without
the `keys: :atom` that M8a already makes you ask for.

**`T.optional/2` survives and loses its edge.** Inside a struct the key is always there, so
what decoding leaves behind for an absent field is that field's `defstruct` default, and
encoding writes that same value back as absent. That is what keeps
`decode(encode(decode(w))) == decode(w)` closing, and it is the one thing `into:` costs against
the three states the rest of the library keeps apart. For a struct `mix rupa.gen.struct` wrote
the value is `nil`, so an absent key and an explicit null reach the same struct and both leave
as absent; a struct you wrote yourself may default the field to something else, and then that
is what stands for absent and `nil` goes out as a null like any other value. A field with a
`default:` of its own is not in this set at all — decoding always put something there, so a
`nil` is a value the schema cannot express, and it errors.

**`mix rupa.gen.struct MyApp.Schemas.user`** calls that zero-arity function, stages the schema
and writes one file per `into:` module at the path its name conventionally has under `lib/`: a
`defstruct` and a `@type t`, with a schema `default:` carried through as the `defstruct`
default, and nothing that mentions Rupa. `--force` overwrites, `--dry-run` prints. It stages
with `Rupa.Stage.run(schema, structs: :skip)`, which is the new option and exists for this.
Keys and defaults go through Elixir's own printers rather than through interpolation, so a
property name a document chose — `first-name`, say — comes out quoted in both the `defstruct`
and the typespec instead of as a syntax error.

**Elixir's type checker found the one clause that fell out of the design.** When the absent
value is `nil`, an optional `nullable` field's `nil` branch is unreachable inside a struct —
the field chain has already written that `nil` as absence — so both backends encode through
the `nullable`'s inner node instead. Decoding still goes through the wrapper, because a wire
`null` has to be allowed in.

Decode's budget did not move: 119/190 and 24/48 words and reductions per op, the same figures as
M3, M5, M6 and M7. The closure backend's struct path is a separate function from the ordinary
one rather than a `base` that may be `nil`, so an object with no `into:` pays nothing for the
feature.

**M8b — JSON Schema, both directions.** `Rupa.JsonSchema.encode/1` writes a draft 2020-12
document and `decode/1` reads one. The official JSON-Schema-Test-Suite is vendored under
`test/fixtures/json-schema-suite/`, pinned to an upstream commit, and every case runs on every
build.

**`encode/1` is total, and describes the wire rather than the schema.** It stages first, so
`rename_all:`, `from:` and `keys:` are already spent and the property names are the wire keys. A
`$ref` off a cycle has been inlined by then; genuine recursion comes back out as `$defs` and
`$ref`, with a ref to the root written `#`. A `default:` is written in its wire form, through the
field's own encoder — which is the only thing that knows how, since the value is decoded and the
document wants what the wire would carry.

**`decode/1` interns nothing**, which is what M8a was for: the objects it produces are named with
strings, so no property name in a document ever becomes an atom. Two of Rupa's own constructs
therefore encode but do not decode, both for the same reason — a tagged union's tag is an atom,
and a recursive `$ref` needs a `$defs` name. A `$ref` that is *not* on a cycle needs no name, so
it is inlined and ordinary reuse through `$defs` works.

**It refuses out loud.** Every keyword Rupa has no answer for is a named error with the path to
it: `:unsupported_keyword`, `:untyped_schema`, `:unsupported_mixed_object`,
`:unsupported_bare_required`, `:unsupported_open_tuple`, `:unsupported_ref`,
`:unsupported_recursive_ref`, `:unsupported_type_union`. Writing that list is what turned up two
places where an earlier cut dropped a constraint on the floor — `required` naming a key
`properties` did not describe, and `prefixItems` read as a fixed-length tuple when the document
had pinned neither end.

**Where Rupa and the spec disagree is now measured rather than asserted.** Four places, all in
`Rupa.JsonSchema`'s moduledoc: `format` asserts where JSON Schema annotates, `pattern` is PCRE,
lengths count graphemes, and — the only one where Rupa is the stricter — a number is compared by
term rather than by mathematical value, so `1.0` is not an `integer` and `{"const": 0}` does not
match `0.0`. The suite runner prints the pass rate, the skip reasons and those deviations, and
fails on anything not in one of the two lists. It also fails on a deviation the suite has stopped
reporting, so the list cannot go stale.

**A whole-string anchoring bug in `Rupa.Format`, found by the format corpus.** `^...$` in PCRE
also matches before a final newline, so `T.uuid()`, `T.email()`, `T.hostname()` and
`T.duration()` all accepted a value with a trailing newline. They now anchor with `\A` and
`\z`. M8c vendors the corpus that found it.

**M8a — an object's field names can be strings.** `{:object, %{"a" => T.string()}, []}` is a
schema, and it decodes to `%{"a" => ...}`. Names are all atoms or all strings per object;
mixing them is `:mixed_field_names`, because `keys:` would then have nothing coherent to
default to.

This exists for `Rupa.JsonSchema.decode/1` in M8b, and it is what makes that path total. A
JSON Schema names its properties, and turning those names into atoms is the one thing in the
library that could grow the atom table from a document. Now nothing has to: a decoded schema
is string-named, and the design doc's claim that Rupa has no atom-exhaustion path stays true
with no exception written under it.

**`keys:` defaults to the type of the name you wrote.** An atom-named object decodes to atom
keys, a string-named one to string keys, so neither default interns anything. `keys: :atom` on
a string-named object is the single explicit place a name becomes an atom — and that is a name
in a schema, not a key off a document, which is the rule every other atom in a schema already
follows. It is the second and last `String.to_atom/1` in the repo.

**`unknown: :keep` no longer lets an unknown key shadow a field.** A field claims three names —
the wire key it reads, the wire key it writes, and the key it takes in the decoded map — and
once a decoded key can be a string, any of the three can collide with a key the schema does not
know. It was reachable before M8a with `keys: :string` and a `from:`, where the kept key won
and the field's value was silently lost; now all three names are off limits to the extras in
both directions, from one definition in `Rupa.IR` that both backends read.

**Migration:** a non-atom name in `defs:` now reports `:invalid_def_name` rather than
`:invalid_field_name`, since the two no longer mean the same thing.

**M7 — JSON, both directions.** `Rupa.decode_json/3` takes JSON text and `Rupa.encode_json/3`
writes it, on both backends. The two halves are not the same problem, and only one of them
fuses; the milestone was told to measure before believing either way, and `mix run
bench/json.exs` is the measurement.

**`encode_json/3` emits iodata in one walk of the decoded value.** The two-step it replaces —
`encode/3` builds a wire map, a JSON encoder then walks it — costs 349 reductions and 505 words
per op on the nested fixture; fused costs 162 and 314. On the module backend, 326/459 becomes
129/235. Wire keys, enum values and a tagged branch's whole `,"kind":"click"` are rendered to
binaries while the schema is staged, so what is left at run time is escaping the strings the
value actually carries. The result is iodata, which is what a socket wants;
`IO.iodata_to_binary/1` flattens it. Fields come out in the schema's order rather than a map's,
which is the one visible difference from going the long way round.

**`decode_json/3` does not fuse, and the callback API is why.** `:json.decode/3` hands a value's
key to `object_push` only after that value is fully built, so when a nested object starts,
nothing in scope says which field it belongs to — and a field is exactly where a schema differs
from a parser. The accumulator threads down through `object_start` and `array_start`, which is
enough to direct the root and an array's elements and not enough for an object's fields. There
is no `object_keys` callback. So `decode_json/3` is the two-step composition under the name it
promised, the bench shows it lands on the sum of its parts, and a Rupa-owned parser is the way
past it rather than in.

**A JSON null decodes to `nil`.** `:json` calls it the atom `null` by default; Rupa parses with
`null: nil` so that present, absent and null stay the three states the rest of the library
already means by them. That costs 14 reductions and 18 words per parse — passing any decoders
map at all makes `:json.decode/3` build its callback record per call — and it buys the only
reading of null that composes with `T.nullable/1`.

**Going the long way round needs an encoder that knows about `nil`.** `encode/3` returns `nil`
for a null, and `:json.encode/1` writes a bare atom as a string, so `encode/3` piped into it
quietly emits `"nil"` where the document should say `null`. Elixir's own `JSON` module gets this
right, and so does `:json.encode/2` with an encoder you supply. `encode_json/3` has no such
edge, which is a second reason to prefer it.

**Malformed text is an error, not a raise.** `%Rupa.Error{code: :json}` with the reason in
`meta`, so a request handler has one shape to match on. Trailing whitespace is fine; trailing
anything else is not.

**A tagged branch with no fields of its own no longer warns.** Its decoder is `{:ok, %{}}` and
cannot fail, so the clause that would have handled its failure was dead code — which Elixir's
type checker reports by the generated module's internal name, into whatever console the compile
happens in. Found by an M7 test, fixed in the M6 code it came from.

**Codegen got a third tree, and the boot bill shows it.** A named codec now generates decode,
encode and encode-to-JSON. `bench/BUDGET.md` has the number. The decode budget itself did not
move: 119/190 and 24/48, the same as M5 and M6.

**M6 — unions.** `Rupa.T.tagged/3` and `Rupa.T.union/2` compile, on both backends, which
completes the vocabulary: every kind the design doc lists now has a codec behind it, and
`:not_yet_supported` is gone along with the last thing that raised it.

**A tagged union decodes to `{tag, value}`** — `{:circle, %{r: 1.0}}` — with the tag interned
from the branch name while the schema is staged, never from wire data. That is one shape for
both tagging styles and one `case` clause per branch at the other end. Internally tagged
(the default) leaves the branch's own fields where they are; `content:` puts them in an
envelope beside the tag, serde style, and a branch is then free to be any schema rather than
an object. Encoding puts the tag back where it found it, so the round trip holds either way.

**Tagged dispatch is one key read and one call, at any depth.** The module backend matches the
tag in the function head, so a branch is a direct call. `mix run bench/union.exs` is that claim
with numbers under it: at depths 1 to 7, tagged grows by a falling factor per level while
untagged holds at ×2.

**An untagged union tries its variants in the order you wrote them**, and the first that takes
the value wins — so the order is part of the schema. Attempts run in `:halt` whatever
`on_error:` said, because a variant you did not choose is one whose complaints you will never
read; when none of them fits, the error is a single `:no_variant` rather than every variant's.

**Nesting one untagged union inside another warns**, once per schema, with `IO.warn/1` while
staging. It is the only construct in the vocabulary whose cost doubles with depth and the only
one you can reach without meaning to. Rupa still starts nothing and never logs: this is the
compiler's own way of saying "this is valid, and you may not have meant it".

**`Rupa.Gen` generates both**, and the round-trip property covers a recursive tagged union. An
untagged one generates from a random variant, which round-trips only if the variants are
disjoint — that is the cost `tag: :none` makes you opt into, and the docs say so.

**`bench/measure.exs`** now holds how every benchmark in that directory counts, so
`bench/decode.exs` and `bench/union.exs` share one definition of words and reductions per op
rather than two copies of it.

**M5 — wire mapping.** An object's fields no longer have to be spelled the way the wire spells
them. `rename_all: :camelCase | :snake_case | :kebab` renames every field of the object that
declares it, `from:` and `to:` override that for one field, and `keys: :atom | :string` chooses
what the decoded map is keyed by. All four are spent at staging, so both backends read three
finished names off the staged field and neither one ever looks at a case convention.

**`rename_all:` reads a field name as words**, so it works on a name written in any of the three
rather than only on snake_case, and a run of capitals is one word — `user_id` and `userID` both
read as `["user", "id"]`. It applies to the object that declares it and not to the objects
inside it; a whole tree in one style is a `Rupa.Schema.walk/2` away, which is the kind of thing
schemas-as-data is for.

**One of `from:` and `to:` renames both directions.** Give both, naming different keys, and you
have said this field reads an old name and writes a new one — the one way to make `encode` stop
being `decode`'s inverse, and it takes saying so. Like `default:`, they belong on the field's
own term; anywhere else is `:misplaced_rename`. Two fields landing on one wire key is
`:duplicate_wire_key` at compile time rather than one of them quietly winning.

**`keys:` is the decoded side, not the wire.** It changes the key's type and never its name, so
`%{first_name: ...}` under `rename_all: :camelCase, keys: :string` reads `"firstName"` and
decodes to `%{"first_name" => ...}` — and encode reads back whichever key it wrote. No atom is
ever interned from wire data on any path, before or after renaming, and
`test/rupa/codegen_test.exs` reads the generated AST to say so.

**`Rupa.T.partial/1` carries `from:` and `to:` out** to the `optional` it adds, the same way it
already leaves a defaulted field alone, so wrapping a field does not bury its wire key.

**M4b — generators.** `Rupa.Gen.stream/1` turns a schema, a codec or a generated module into a
StreamData generator of *decoded* values, and `test/rupa/gen_test.exs` runs the property it
exists for — encode it, decode that, get the value back — a thousand times per type against
both backends. `stream_data` is an optional dependency: `Rupa.Gen` compiles when it is there
and does not exist when it is not, so nobody who only wants to decode pays for it.

**It refuses rather than skips.** A `pattern:`, a `multiple_of:` it cannot hit exactly, a bound
nothing satisfies, or a recursion with no case that stops each raise with the path at the
moment the generator is built. A property test that quietly ignores half your schema is worse
than one that will not start.

**M4a — encode.** `Rupa.encode/3` and `Rupa.encode!/3`, on both backends, from the same IR.
Inverse means this precisely: encode a decoded value, decode it again, and you get the value
back. It is deliberately not the identity on the *wire* — a default that was absent comes back
materialised, which is the point of a default.

**What encode checks is types and formats**, because it has to look at those anyway to turn a
`DateTime` back into a string and an atom back into its wire value. Constraints are not re-run;
decoding already bought them. Failures are `%Rupa.Error{}` with a path, the same as decoding,
and `Rupa.EncodeError` is its own exception — a decode error is the outside world being wrong,
an encode error is your own code being wrong about a value it built.

**Every format has an encode side**, including a duration encoder written here rather than
handed to `Duration.to_iso8601/1`: the stdlib will emit a negative duration, which RFC 3339 has
no syntax for and Rupa's parser therefore rejects, so a round trip through the stdlib would not
be one. Sub-second precision survives — `PT1.500S` comes back `PT1.500S`.

**M3 — the module backend.** `Rupa.compile(schema, as: MyApp.Codecs.User)` generates and
loads a module from the same IR the closure tree is built from, and `Rupa.decode/3` takes the
name. Object fields are matched in a head, guard-safe checks in a guard, and the result built
as a map literal, so a field that is present and valid allocates nothing: 48 words/op against
hand-written's 42. A recursive ref is a direct call, so the one table lookup the closure
backend does goes away, and a compiled `pattern` is embedded as a literal rather than kept in
`:persistent_term` — the module is built at runtime by the OTP about to run it, so the version
skew that would make that unsafe cannot happen.

**Naming a codec twice is a lookup**, on a hash of the schema the module carries. Naming it
with a *different* schema is refused rather than swapping the codec under code already using
it; `force: true` replaces it with `:code.soft_purge/1`, and a process still running the old
codec refuses the replacement instead of being killed. Compiles are serialised per name with
`:global.trans/2`, so Rupa still has nothing to start and nothing in your supervision tree.

**Every decode test runs on both backends** and asserts they agree, so a feature cannot land on
one and not the other.

**M2 — the staging pass, and the closure backend over it.** `Rupa.compile/1` validates a
schema, stages it into `Rupa.IR`, and builds a decoder. `Rupa.decode/3` runs it, `Rupa.decode!/3`
raises, `Rupa.valid?/2` is the yes/no. Scalars with their constraints and all ten formats,
objects with required, optional and default fields, lists, tuples, `map_of`, `nullable`, `enum`,
`literal`, and the unknown-key policy. Unions are M6, wire renaming is M5, and both say so at
compile time rather than being quietly ignored.

**Refs are resolved at staging.** A ref that is not on a cycle is replaced by the definition
itself, so the decoder never looks anything up; only genuine recursion stays a node.

**Errors are a list whatever happens.** `on_error:` is `:halt` by default and stops at the
first problem; `:collect` reports every field. Paths are built on the way back up, so a
successful decode allocates nothing for them.

**`Rupa.explain/1`** prints the staged program. It reads the IR, not a backend, so it will say
the same thing when the module backend lands.

**A decode budget**, `bench/BUDGET.md`, and `mix run bench/decode.exs` to measure against it —
no benchmarking dependency, because the numbers that matter are words and reductions per op.

**M1 — the schema vocabulary.** `Rupa.T` builds schema terms and nothing else: `{kind, opts}`
for scalars, `{kind, payload, opts}` for everything that holds a schema. A bare map is an
object, and options come back sorted, so two spellings of one schema are one term and hash the
same. `Rupa.Schema.validate/1` is the only judge — structure, options, refs, and no function
anywhere in the tree — and reports every problem at once as `%Rupa.Error{}` with a path.
`Rupa.Schema.walk/2` rewrites a schema, children first. `T.pick/2`, `T.omit/2`, `T.partial/1`
and `T.merge/2` are honest map work on the field map.

**Present, absent and null are three states.** A field is required unless it is wrapped in
`T.optional/2` or carries `default:`. `optional` is about the key and decodes to no key at
all, never to `nil`; `nullable` is about the value and decodes to `nil`; `default:` fires on
absent only, and never replaces an explicit null.

**M0 — skeleton and gates.** No library code. `mix.exs` on an Elixir 1.18 / OTP 27 floor,
`mix check.all`, Credo strict, ExCoveralls at 100%, and a CI workflow that runs the gate on
the pinned pair and compiles and tests the floor beside it.

# The decode budget

What `mix run bench/decode.exs` and `mix run bench/json.exs` are checked against. A milestone
that moves a number past its budget either fixes it or changes this file with a reason.

## The numbers, and how much each one is worth

**`words/op` is the budget.** It is the process heap a single decode allocates, and it predicts
GC behaviour under sustained load, which is where a schema library actually lives. It does not
move between machines.

**`reds/op` is the tiebreaker.** The scheduler's own count of work done. Independent of the
machine, but not quite of the runtime: OTP 29 counts the parser rows below about ten reductions
cheaper than OTP 27 does and Rupa's own rows within a handful either way, while `words/op` agrees
to the unit. So a reductions figure travels with an OTP release, and a comparison is between two
rows of one run rather than against a number in this file.

**`us/op` is the one to distrust.** It is here because people ask for it. On a shared two-core
runner it swings by a factor of two between runs, and it is the only column where the
benchmark's own loop overhead is a meaningful share of the measurement.

## The budget

| | words/op | reds/op |
|---|---|---|
| closure backend | ≤ 200 | ≤ 130 |
| module backend | ≤ 100 | ≤ 40 |

Hand-written means `HandWritten` in `bench/decode.exs`: the same fixture, the same checks,
pattern matching written out by hand. It is the 1.0x line, and it costs 42 words/op and 11
reds/op.

**JSON has one budget and it is a comparison, not a constant:** `encode_json/3` stays under the
two-step it replaces on both counts, on both backends. There is nothing to promise for
`decode_json/3` beyond what its parts cost, because it is its parts — see below.

## Measurements — M7, retaken after the 0.1.0 reviews

2000 iterations per case, 2026-09-22, the maintainer's machine: macOS on Apple Silicon, OTP 29,
Elixir 1.20.3. `reds/op` and `words/op` are the columns to hold a run against — the maintainer's
own `mix run bench/json.exs` is the gate, and a `words/op` that disagrees is a finding. Against
M7's tables, the closure decoder lost two words (190 → 188, so `decode_json` 374 → 372) and its
sparse row gained a reduction (111 → 112) somewhere in the three release reviews; nothing else in
Rupa moved, and the parser and encoder rows differ only by the OTP-release offset above.

### Decode — `bench/decode.exs`

| case | us/op | reds/op | words/op | rel |
|---|---|---|---|---|
| hand-written | 0.333 | 11 | 42 | 1.00x |
| closure, all present | 0.479 | 120 | 188 | 1.44x |
| closure, 3 absent | 0.396 | 112 | 149 | 1.19x |
| module, all present | 0.223 | 24 | 48 | 0.67x |
| module, 3 absent | 0.627 | 33 | 62 | 1.88x |

M3 set these figures and M5, M6, M7, M9 and M10 all landed on them to the unit, which is what
"spent at staging" is supposed to mean; the two words the reviews took off the closure row are the
only movement since. The cloud sandbox reports the same `reds/op` and `words/op` while its `us/op`
column disagrees by a factor of three — and here the module backend's `us/op` comes in *under*
hand-written, which is the JIT and the column being what it is — that is the argument for which
columns to read, and why the budget is written in words and reductions.

### JSON in — `bench/json.exs`, the same nested fixture

| case | reds/op | words/op |
|---|---|---|
| `:json.decode/1` — the floor | 186 | 158 |
| `:json.decode/3` with `null: nil` | 201 | 176 |
| `decode/3` on the parsed term, closure | 120 | 188 |
| `decode/3` on the parsed term, module | 24 | 48 |
| `decode_json/3`, closure | 327 | 372 |
| `decode_json/3`, module | 231 | 232 |

Read it as arithmetic: 201 + 120 = 321 against 327 measured, and 201 + 24 = 225 against 231.
The composition costs six reductions beyond its parts, which is the call. That is the point of
the table — there is no hidden cost and no hidden saving, because there is no fusion. `Rupa.Json`
says why the callback API does not allow one.

The `null: nil` row is worth 15 reductions and 18 words. It is not the substitution — the parser
puts that term in inline — it is that passing any decoders map at all makes `:json.decode/3`
build its callback record once per call.

### JSON out — where the milestone actually pays

| case | reds/op | words/op |
|---|---|---|
| `:json.encode/2` on the wire map — the floor | 249 | 320 |
| `encode/3` alone, closure | 90 | 185 |
| two-step (`encode/3` then `:json.encode/2`), closure | 338 | 505 |
| **`encode_json/3`, closure** | **159** | **314** |
| two-step, module | 315 | 459 |
| **`encode_json/3`, module** | **132** | **235** |

Fused is 53% fewer reductions and 38% fewer words than the two-step on the closure backend, and
58%/49% on the module backend. Both fused rows come in under the serialising floor, which is not
a trick: the floor walks a generic map and escapes every key it finds, and the fused path had its
keys rendered to binaries while the schema was staged.

## Measurements — M10, and what Rupa is measured against

`bench/compare.exs` runs in CI and asserts rather than prints: the two budgets above, plus a
margin against Peri and Ecto. It is the only bench here that fails a build.

Maintainer's machine, 2000 iterations per case, 2026-09-22. One wire map in, one validated
typed value out, the same checks in every row.

| case | us/op | reds/op | words/op | rel |
|---|---|---|---|---|
| hand-written | 0.380 | 11 | 42 | 1.00x |
| Rupa, module | 0.188 | 24 | 48 | 0.49x |
| Rupa, closure | 0.478 | 120 | 188 | 1.26x |
| Ecto 3.14.2 embedded cast | 7.489 | 1264 | 1418 | 19.71x |
| Peri 0.11.2 | 7.472 | 1604 | 1656 | 19.66x |

The decode rows are the table above again — and the cloud sandbox reports the same `reds/op` and
`words/op` to the unit while its `us/op` column comes in at roughly twice these, which is the
argument for which columns to read restated one more time.

**The margins the file asserts are deliberately loose.** Ten times on reductions against each of
Peri and Ecto, where measured is about sixty-five and fifty. That is the number which goes red
when Rupa regresses by an order of magnitude and stays green when somebody else's library gets
faster, which would be good news and not a build failure.

What the other two columns are doing differently is in `bench/compare.exs`'s own header, and it
is worth reading before quoting the table: Peri validates in place and keeps the shape, Rupa
converts, Ecto builds structs, and the one check Ecto cannot state declaratively costs it a
`validate_change/3` that is in the file rather than dropped from the row.

### Across languages — `bench/xlang/`

Not comparable to anything above, and on purpose: `ns/op` wall clock is the only currency five
runtimes share, so this table is run by hand and published with a machine and a date beside it.
M4 under Docker, arm64 Linux, 2026-09-17, 100000 iterations after a 200000 warmup, best of 5
interleaved passes.

| library | ns/op | spread | rel |
|---|---|---|---|
| serde_json 1.0 | 371.1 | 15.0% | 1.00x |
| Zod 4.6.5 | 920.1 | 1.5% | 2.48x |
| Malli 0.16.4 | 963.6 | 12.6% | 2.60x |
| Rupa | 1017.4 | 9.5% | 2.74x |
| pydantic-core 2.13.3 | 1290.9 | 3.3% | 3.48x |

The design notes expected to lose to serde by 5-10x; 2.7x is better than that and is still the
number to distrust first, because it is one machine.

**Read `spread` before `ns/op`.** It is how far a column's worst pass landed above its best, and
here it decides what can be said at all: Zod, Malli and Rupa sit within about ten percent of
each other, which is not more than the error bars around them, so that band is a tie and not an
order. The gap to pydantic-core and the gap to serde_json are wider than any spread in the
table, and those two orderings it can support.

**The earlier x86-64 row is withdrawn rather than kept beside this one.** It was one sample per
column at a 10000 warmup, and both of those turned out to matter. Ten thousand measures
HotSpot's first tier rather than its last, which is why Malli was absent from a table it now
sits third in; and one sample cannot tell a library from the core it happened to land on. An
x86-64 row taken under the current harness is worth having and does not exist yet.

Two things learned building it outlive this table. Best-of-N works: serde_json's best came in
at 373.5, 372.9 and 371.1 across three runs on this machine, inside 0.6%, while individual
passes within one of those runs varied by 15%. And Rupa's column runs with
`+S 1:1 +sbwt none +sbwtdcpu none`, which took its spread from 36.1% to 9.5% without moving its
best — on a host with performance and efficiency cores, the BEAM's per-core busy-waiting
schedulers decide which kind the measured thread gets, and `bench/xlang/README.md` carries the
profile showing both modes running identical work.

## Codegen is the boot bill

**A named codec generates three trees since M7** — decode, encode, and encode-to-JSON — and the
third one costs about 30% on top of the first two: on the sandbox, measured with and without it,
the nested fixture went from ~130 ms to ~170 ms. M5 measured 49.5 ms on the maintainer's machine;
the same fixture measured 67 ms there on 2026-09-22 (57.8 ms for the sparse one).

It is paid once, in your application's start callback, and a repeat compile of an unchanged
schema is a hash lookup. It is still the number to watch if a project ever names hundreds of
codecs, and it is now the number to revisit if `encode_json/3` should become something you ask
for rather than something you get.

This is wall clock, the column this file otherwise tells you to distrust, and it is the one
number with nowhere else to live. M3 measured 31 ms here for the same generated code that M5
measured 49.5 ms for; the sandbox shows no such jump between 1.14 and 1.18, so the change is in
the toolchain after 1.18 — most likely the type checker now inferring across a module that
`Code.compile_quoted` builds at runtime, which is also when generated codecs started reporting
dead clauses at all.

## What the milestones learned

**M2 — `String.length/1` walks grapheme clusters and allocates while it does.** On the nested
fixture its four `min: 1` checks were 134 of 339 words/op. Byte size bounds grapheme count from
above, which settles `min: 1` outright and most of the rest without counting, so both backends
check bytes first. That one change was most of the distance from 339 to 190.

**M3 — the win is not the code being generated, it is the object head match.** A first cut that
simply unrolled the closure logic into functions came in at 117 words/op and 42 reds/op: better
than closures, nowhere near hand-written. What closed the gap was one extra clause per object,
emitted when every field is required and unknown keys are stripped — the wire keys in the
pattern, the guard-safe checks in the guard, the result as a map literal. Nothing is consed and
no `{:ok, _}` is built. 117 → 48 words/op, 42 → 24 reds/op. Anything that fails that clause
falls back to the general chain, which is slower and says which field it was.

**M5 — renaming costs nothing at run time, which is the whole point of staging it.** Both
backends read finished wire keys off `%IR.Field{}`, so a `rename_all:` schema and a plain one
generate the same code and allocate the same words.

**M7 — the fused encoder beats the serialising floor because the floor is doing work it does not
have to.** `:json.encode/1` cannot know that this map's keys are the same seven strings every
time, so it escapes them on every call; a staged program knows, and renders them once. The same
argument covers an enum's wire value and a tagged branch's whole `,"kind":"click"`. It does not
cover decoding, where the equivalent knowledge — which field this value belongs to — is exactly
what the parser will not tell you until it is too late.

# bench/xlang — Rupa against the libraries it is actually competing with

```bash
docker build -t rupa-xlang -f bench/xlang/Dockerfile .
docker run --rm rupa-xlang
```

Five implementations of one job, on one fixture, measured the same way. What this directory is
for is the sentence in the README, and the sentence has to survive someone checking it.

## The one comparable shape

**Bytes in, a validated typed value out.** That is the only thing all five of these do, so it
is the only thing worth timing:

1. the JSON bytes are parsed,
2. every field is checked against the same constraints,
3. what comes back is typed — a struct, a model, a parsed object — not a generic map.

Everything outside the loop is setup and is not timed: building the schema, compiling the
validator, reading the fixture. That matches how each of these is meant to be used, and it is
the arrangement that flatters the compiled ones least — a library that pays at compile time
should have already paid.

The happy path only. Error construction is a different measurement and the libraries differ
wildly in how much they build on failure, so mixing the two would say nothing about either.

## The fixture

`fixture.json`: three nested objects, a two-element list, nine leaf fields, all present and
valid. It is `bench/decode.exs`'s shape, so the in-BEAM numbers and these are about the same
work. Constraints, identical in all five:

| field | check |
|---|---|
| `id`, `name` | string, at least one character |
| `active` | boolean |
| `score` | number, at least 0 |
| `profile.age` | integer, 0 to 150 |
| `profile.city`, `profile.settings.theme` | string |
| `profile.settings.size` | integer |
| `tags` | list of strings, each at least one character |

## What each column is doing, and where it differs

* **Rupa** — `Rupa.decode_json/3` against a codec compiled with `as:`. Parse, then the staged
  program. The design doc is explicit that this does not fuse and why.
* **serde_json** — `from_slice` into a typed struct, then the constraints by hand. serde has no
  declarative `min_length`, so that is what a fair column costs: the derive does the types and
  the shape, and `validate/1` does the rest. This is the ceiling, and it is meant to be.
* **pydantic-core** — `model_validate_json`, which parses and validates in one pass in Rust.
  The closest of the five to what Rupa is trying to be, and the one to watch.
* **Zod** — `JSON.parse` then `schema.parse`. Two passes over the value, which is the same
  arrangement as Rupa's.
* **Malli** — `jsonista` then a compiled validator and decoder. The fair Clojure target;
  clojure.spec is the slow one Malli exists to replace, so comparing against spec would be
  choosing a weak opponent.

## On Apple Silicon

Build and run it **natively**, which is what the commands above do. Do not pass
`--platform linux/amd64`.

Native arm64 is a real measurement: Docker Desktop runs a Linux VM, and for a CPU-bound loop
with no I/O the VM costs approximately nothing. What it is *not* is an x86-64 measurement. The
BEAM's JIT, V8 and the JVM all have mature arm64 backends and all three land in slightly
different places than they do on x86-64, so treat a run here as its own row — which is what
publishing the machine beside the number is for.

`linux/amd64` under Rosetta is not representative of anything and its numbers should not be
published. Three of the five runtimes here emit machine code at run time, and under emulation
that code is generated as x86-64 and then translated again before it executes. It punishes
exactly the JIT-heavy columns and flatters the one that is compiled ahead of time, so the
comparison it produces is of the emulator rather than of the libraries.

If you want the x86-64 row, run this on an x86-64 Linux box.

One thing to know if a build fails early: Node is the only toolchain here that ships a tarball
per architecture, so it is the only place the Dockerfile has to know which one it is on. When
that went wrong the failure surfaced as `rosetta error: failed to open elf at
/lib64/ld-linux-x86-64.so.2` at the first `npm` — an x86-64 binary in an arm64 image, reported
nowhere near where it was installed. The Node layer now ends with `node --version` so that
lands where it belongs, and every other toolchain layer does the same.

## Warmup, repeats, and what the table can actually tell you

Three knobs, defaulting to 50,000, 100,000 and 5. The programs read the first two, the runner
reads the third, and each of them re-runs all five columns:

```bash
docker run --rm -e XLANG_WARMUP=200000 -e XLANG_REPEATS=9 rupa-xlang
```

**Warmup decides exactly one column**, and it is worth knowing which. Two of the five compile
ahead of time and do not care: serde_json is a binary, and pydantic-core's validator is Rust
behind a Python call. The BEAM compiles on load, so Rupa is warm almost immediately. V8 needs a
few thousand iterations and then settles. HotSpot is the one — its tiered compiler does not
reach the top tier until something like fifteen thousand invocations of a method, so a warmup
near ten thousand measures C1 with profiling rather than C2, which reads as a slow library and
is not one. The default is 50,000 for that reason alone, and Malli has been seen still
improving at 200,000, so read its row as an upper bound until it stops moving.

**Repeats decide whether any of it means anything.** The runner measures every column once per
pass, interleaved, so that drift and whatever else the machine is doing land on all five
equally; it then reports each column's best pass and, as `spread`, how far its worst pass
landed above that. Best rather than mean, because every source of noise here adds time —
another process got the core, the JIT had not finished, the fan had not spun up — so the
fastest pass is the closest to the library and the spread is the honest error bar around it.

Read the spread first. A few percent is the machine's noise floor and the ns/op beside it is
the library. Double digits is a column that has not settled, and no story about why it is fast
or slow is worth telling yet. **Never publish a row whose spread is wider than the gap it is
being used to claim** — one sample per column cannot tell a library from a busy machine, and
the cost of finding that out the other way is an afternoon spent explaining a number that was
never there.

## The one flag on the table

Rupa's column runs with `+S 1:1 +sbwt none +sbwtdcpu none`. No other column is given anything,
the table prints the flag above itself so a number pasted elsewhere arrives with its asterisk,
and `XLANG_BEAM_FLAGS=` takes it off so you can watch what it was doing.

What it removes is this. The BEAM starts one scheduler thread per logical core and idle
schedulers busy-wait before sleeping, so a single-threaded benchmark still presents to the host
as ten runnable threads. On a machine with performance and efficiency cores the host spreads
them, and the thread carrying the measurement lands on whichever kind it lands on. On a 10-core
M4 under Docker that produced two clean clusters a factor of 1.36 apart, 1065 ns/op and 1443,
with nothing in between and three of five passes landing slow.

`elixir/profile.exs` is what settles it, and it is kept for the next time a column wobbles. It
reports the same loop in chunks with the process's own accounting beside each one, and across
300,000 decodes the two modes run the same code, allocate the same words, and perform the same
667 minor collections per 10,000 iterations in the same order. Identical work, different wall
clock. The mode is also fixed before the first decode and never changes, which rules out
anything accumulating inside the runtime.

So the slow cluster carries no information about Rupa, and none about a real application
either: schedulers spin because this benchmark leaves nine of them with nothing to do, which is
not the position they are in under load. The other four columns need no equivalent because the
work is already on one thread — serde_json and pydantic-core are single-threaded outright, and
Node and the JVM keep helper threads that are not spinning for a core.

Uniform cores do not do this, which is one more reason the arm64 row and the x86-64 row are
two rows.

## Reading the numbers

`ns/op`, wall clock, one process at a time. That is the only currency five runtimes share —
there is no cross-language equivalent of the words and reductions that `bench/BUDGET.md` is
written in, which is exactly why this directory is run by hand and its numbers are published
with a machine and a date beside them rather than treated as a constant.

Expect to lose to serde by 5–10x and say so. The pitch is fastest-on-the-BEAM and within a
small factor of pydantic-core, not beating Rust.

## Running one of them on its own

Each program prints exactly one line — `<name> <ns/op> <iterations>` — so the runner can build
a table and you can run any single one without it:

```bash
cd bench/xlang/rust    && cargo run --release -- ../fixture.json
cd bench/xlang/python  && python3 main.py ../fixture.json
cd bench/xlang/js      && npm install --silent && node main.mjs ../fixture.json
cd bench/xlang/clojure && clojure -M -m bench ../fixture.json
mix run bench/xlang/elixir/rupa.exs bench/xlang/fixture.json   # from the repo root
```

`XLANG_WARMUP` and `XLANG_ITERATIONS` work on any of them individually too. The Elixir side has
one more, which prints a profile instead of a number and is the thing to reach for when a
column stops holding still:

```bash
mix run bench/xlang/elixir/profile.exs bench/xlang/fixture.json   # XLANG_CHUNK, XLANG_CHUNKS
```

The Elixir ones need nothing the repo does not already have. The other four pin their versions
in the Dockerfile, and the table prints every version it ran.

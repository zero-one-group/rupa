# bench/json.exs — what fusing JSON is worth, in each direction.
#
#     mix run bench/json.exs
#
# How the numbers are taken, and why they are words and reductions rather than a wall clock,
# is in bench/measure.exs. The fixture is bench/decode.exs's nested one, so these rows sit
# beside the decode budget rather than beside nothing.
#
# Two tables, because M7 is two independent claims:
#
#   * decode — `Rupa.decode_json/3` is `:json.decode/3` and then `Rupa.decode/3`. The rows show
#     the parse floor, the decode on its own, and the two together, so you can see whether the
#     composition costs anything beyond its parts. It does not, and it cannot be fused further
#     without a parser Rupa owns: `Rupa.Json` says why.
#
#   * encode — `Rupa.encode_json/3` emits bytes in one walk of the decoded value. The two-step
#     it replaces builds a wire map and then serialises that. The gap between those two rows is
#     the whole of what M7's encode half buys.

Code.require_file("measure.exs", __DIR__)

alias Rupa.T

iterations = 2_000

# =============================================
# The fixture
# =============================================

schema =
  T.object(%{
    id: T.string(min: 1),
    name: T.string(min: 1),
    active: T.boolean(),
    score: T.float(gte: 0),
    profile:
      T.object(%{
        age: T.integer(gte: 0, lte: 150),
        city: T.string(),
        settings: T.object(%{theme: T.string(), size: T.integer()})
      }),
    tags: T.list(T.string(min: 1))
  })

text = """
{"id":"abc","name":"Ada","active":true,"score":9.5,\
"profile":{"age":40,"city":"Jakarta","settings":{"theme":"dark","size":14}},\
"tags":["a","b"]}\
"""

codec = Rupa.compile!(schema)
named = Rupa.compile!(schema, as: Bench.Codecs.Json)

decoded = Rupa.decode_json!(codec, text)
parsed = :json.decode(text)
wire = Rupa.encode!(codec, decoded)

# =============================================
# The floors
# =============================================
#
# Parsing with nothing to check against, and serialising a map that is already the wire shape.
# Neither knows anything about a schema, so neither is something Rupa can beat — they are what
# the rest is measured against.
#
# The serialising floor takes an encoder that writes `nil` as JSON null. It needs one:
# `Rupa.encode/3` returns `nil` for a null, and `:json.encode/1` renders a bare atom as a
# string, so the obvious two-step quietly emits `"nil"` where the document should say `null`.
# `JSON.encode_to_iodata!/1` gets this right too and is what most people would reach for;
# `:json.encode/2` is the leaner of the two and so the harder row for `encode_json/3` to beat.

nullable = fn
  nil, _encoder -> "null"
  other, encoder -> :json.encode_value(other, encoder)
end

# =============================================
# Run
# =============================================

# Every path agrees on the fixture, every run of this file: three ways to bytes that decode to
# one value, and two backends doing each of them.
^decoded = Rupa.decode_json!(named, text)

fused = IO.iodata_to_binary(Rupa.encode_json!(codec, decoded))
^fused = IO.iodata_to_binary(Rupa.encode_json!(named, decoded))
two_step = IO.iodata_to_binary(:json.encode(wire, nullable))
true = :json.decode(fused) == :json.decode(two_step)
^decoded = Rupa.decode_json!(codec, fused)

empty = Bench.measure(fn -> :ok end, iterations)

parse_floor = Bench.net(fn -> :json.decode(text) end, iterations, empty)
parse_nil = Bench.net(fn -> :json.decode(text, :ok, %{null: nil}) end, iterations, empty)
decode_only = Bench.net(fn -> Rupa.decode(codec, parsed) end, iterations, empty)
decode_only_named = Bench.net(fn -> Rupa.decode(named, parsed) end, iterations, empty)
from_json = Bench.net(fn -> Rupa.decode_json(codec, text) end, iterations, empty)
from_json_named = Bench.net(fn -> Rupa.decode_json(named, text) end, iterations, empty)

write_floor = Bench.net(fn -> :json.encode(wire, nullable) end, iterations, empty)
encode_only = Bench.net(fn -> Rupa.encode(codec, decoded) end, iterations, empty)

encode_two =
  Bench.net(
    fn ->
      {:ok, term} = Rupa.encode(codec, decoded)
      :json.encode(term, nullable)
    end,
    iterations,
    empty
  )

encode_two_named =
  Bench.net(
    fn ->
      {:ok, term} = Rupa.encode(named, decoded)
      :json.encode(term, nullable)
    end,
    iterations,
    empty
  )

encode_fused = Bench.net(fn -> Rupa.encode_json(codec, decoded) end, iterations, empty)
encode_fused_named = Bench.net(fn -> Rupa.encode_json(named, decoded) end, iterations, empty)

heading = fn ->
  IO.puts(
    String.pad_trailing("case", 22) <>
      " | " <>
      String.pad_leading("us/op", 9) <>
      " | " <>
      String.pad_leading("reds/op", 9) <>
      " | " <> String.pad_leading("words/op", 9) <> " | " <> String.pad_leading("rel", 10)
  )

  IO.puts(String.duplicate("-", 70))
end

Bench.banner(iterations)

IO.puts("bytes in, decoded value out — relative to parsing alone\n")
heading.()
Bench.row(":json.decode/1", parse_floor, parse_floor)
Bench.row(":json.decode/3, nil", parse_nil, parse_floor)
Bench.row("decode, closure", decode_only, parse_floor)
Bench.row("decode, module", decode_only_named, parse_floor)
Bench.row("decode_json, closure", from_json, parse_floor)
Bench.row("decode_json, module", from_json_named, parse_floor)

IO.puts("\n\ndecoded value in, bytes out — relative to serialising alone\n")
IO.puts("two-step is encode/3 and then :json.encode/2, which is what encode_json/3 replaces.\n")
heading.()
Bench.row(":json.encode/2", write_floor, write_floor)
Bench.row("encode, closure", encode_only, write_floor)
Bench.row("two-step, closure", encode_two, write_floor)
Bench.row("encode_json, closure", encode_fused, write_floor)
Bench.row("two-step, module", encode_two_named, write_floor)
Bench.row("encode_json, module", encode_fused_named, write_floor)

IO.puts("""

What to read. In the first table, `decode_json` should land on the sum of the parse row and the
decode row — that is the composition being honest, and it is also the ceiling until a parser
Rupa owns replaces it. In the second, `encode_json` against `two-step` is the whole of
M7's encode claim: one walk of the decoded value rather than a walk that builds a map and a
walk that reads it back.
""")

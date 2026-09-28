# bench/union.exs — what tagging buys, measured.
#
#     mix run bench/union.exs
#
# The claim in the design notes is that a tagged union is flat in nesting depth and an untagged
# one doubles per level. This is that claim, at depths 1 through 7, on both backends.
#
# How the numbers are taken is in bench/measure.exs. Read `reds/op`: the shape of the curve is
# the point here, and reductions are the column that keeps its shape between machines.

Code.require_file("measure.exs", __DIR__)

alias Rupa.T

iterations = 500
depths = 1..7

# This fixture nests the same union shape in both branches at every level, so the module backend's
# *codegen* is exponential in depth -- each union regenerates a decoder to verify its branch, and at
# depth 7 the compile alone runs to minutes. The claim here is the decode-reduction curve, which the
# closure backend shows to depth 7 for nothing; the module backend is built only where its codegen
# is cheap, enough to confirm the two agree on the shape.
module_depths = 1..5

codegen = fn schema, name, depth ->
  if depth in module_depths, do: Rupa.compile!(schema, as: name), else: nil
end

# =============================================
# The fixtures
# =============================================
#
# One shape, two ways of telling the variants apart. At every level the value takes the
# *second* variant, and the two variants differ only in `zz`, which staging sorts after
# `inner` -- so the untagged decoder has to decode the whole of `inner` before it can find out
# that this level was the wrong one, and then does it again for the right one. That is the
# doubling, and it is the same shape the design notes found in Peri.

defmodule Fixture do
  @moduledoc false

  def untagged(0), do: T.integer()

  def untagged(depth) do
    inner = untagged(depth - 1)

    T.union(
      [
        T.object(%{inner: inner, zz: T.string()}),
        T.object(%{inner: inner, zz: T.integer()})
      ],
      tag: :none
    )
  end

  def tagged(0), do: T.integer()

  def tagged(depth) do
    inner = tagged(depth - 1)

    T.tagged(:type, %{
      "a" => %{inner: inner, zz: T.string()},
      "b" => %{inner: inner, zz: T.integer()}
    })
  end

  def untagged_wire(0), do: 1
  def untagged_wire(depth), do: %{"inner" => untagged_wire(depth - 1), "zz" => 1}

  def tagged_wire(0), do: 1
  def tagged_wire(depth), do: %{"type" => "b", "inner" => tagged_wire(depth - 1), "zz" => 1}
end

# Staging warns once per schema, which is the point and not something to read seven times.
{untagged, warning} =
  Bench.capturing_stderr(fn ->
    Map.new(depths, fn depth ->
      schema = Fixture.untagged(depth)
      name = Module.concat(Bench.Union, "U#{depth}")

      {depth,
       {Rupa.compile!(schema), codegen.(schema, name, depth), Fixture.untagged_wire(depth)}}
    end)
  end)

tagged =
  Map.new(depths, fn depth ->
    schema = Fixture.tagged(depth)
    name = Module.concat(Bench.Union, "T#{depth}")

    {depth, {Rupa.compile!(schema), codegen.(schema, name, depth), Fixture.tagged_wire(depth)}}
  end)

# Every fixture decodes, on both backends, to the same value. A benchmark of a failing decode
# would be measuring something else.
for {_depth, {closure, module, wire}} <- Map.merge(tagged, untagged) do
  {:ok, decoded} = Rupa.decode(closure, wire)
  if module, do: {:ok, ^decoded} = Rupa.decode(module, wire)
end

# =============================================
# Run
# =============================================

Bench.banner(iterations)

empty = Bench.measure(fn -> :ok end, iterations)

reds = fn {closure, module, wire} ->
  {
    Bench.net(fn -> Rupa.decode(closure, wire) end, iterations, empty).reductions,
    module && Bench.net(fn -> Rupa.decode(module, wire) end, iterations, empty).reductions
  }
end

cell = fn
  nil -> "—"
  reductions -> Bench.pad(reductions, 0)
end

IO.puts(
  String.pad_trailing("depth", 7) <>
    " | " <>
    String.pad_leading("tagged closure", 16) <>
    " | " <>
    String.pad_leading("tagged module", 16) <>
    " | " <>
    String.pad_leading("untagged closure", 18) <>
    " | " <> String.pad_leading("untagged module", 18)
)

IO.puts(String.duplicate("-", 86))

growth =
  for depth <- depths do
    {tagged_closure, tagged_module} = reds.(Map.fetch!(tagged, depth))
    {plain_closure, plain_module} = reds.(Map.fetch!(untagged, depth))

    [
      String.pad_trailing(to_string(depth), 7),
      String.pad_leading(Bench.pad(tagged_closure, 0), 16),
      String.pad_leading(cell.(tagged_module), 16),
      String.pad_leading(Bench.pad(plain_closure, 0), 18),
      String.pad_leading(cell.(plain_module), 18)
    ]
    |> Enum.join(" | ")
    |> IO.puts()

    {tagged_closure, plain_closure}
  end

# The shape of the curve, which is the actual claim: what the *last* level of nesting multiplied
# the work by. A cost that is flat per level has a ratio falling towards 1 as depth grows; one
# that doubles holds at 2 however deep you go.
last_factor = fn series ->
  [previous, current] = series |> Enum.take(-2)

  Float.round(current / previous, 2)
end

IO.puts("""

Depth 6 to 7, on the closure backend: tagged x#{last_factor.(Enum.map(growth, &elem(&1, 0)))}, \
untagged x#{last_factor.(Enum.map(growth, &elem(&1, 1)))}.

Tagged reads one key and calls one branch, so a level adds a constant and the ratio keeps
falling towards 1. Untagged has nothing to read, so a level costs both variants -- and the wrong
one is only wrong at the bottom -- so the ratio sits at 2 however deep it goes.
""")

IO.puts("""
And staging said so, once per schema, before any of this ran:

#{warning |> String.split("\n") |> Enum.reject(&(&1 == "")) |> List.first()}
""")

# bench/decode.exs — the decode budget.
#
#     mix run bench/decode.exs
#
# How the numbers are taken, and why they are words and reductions rather than a wall clock,
# is in bench/measure.exs.

Code.require_file("measure.exs", __DIR__)

alias Rupa.T

iterations = 2_000

# =============================================
# The fixture
# =============================================
#
# Three nested maps, a two-element list, nine leaf fields. The design notes'
# baseline shape, so the numbers stay comparable across milestones.

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

present = %{
  "id" => "abc",
  "name" => "Ada",
  "active" => true,
  "score" => 9.5,
  "profile" => %{
    "age" => 40,
    "city" => "Jakarta",
    "settings" => %{"theme" => "dark", "size" => 14}
  },
  "tags" => ["a", "b"]
}

# The same shape with three of the leaves optional and absent, which is what a real payload
# looks like and where a naive decoder spends its time.
sparse_schema =
  T.object(%{
    id: T.string(min: 1),
    name: T.optional(T.string(min: 1)),
    active: T.optional(T.boolean()),
    score: T.optional(T.float(gte: 0)),
    profile:
      T.object(%{
        age: T.integer(gte: 0, lte: 150),
        city: T.string(),
        settings: T.object(%{theme: T.string(), size: T.integer()})
      }),
    tags: T.list(T.string(min: 1))
  })

sparse = Map.drop(present, ["name", "active", "score"])

codec = Rupa.compile!(schema)
sparse_codec = Rupa.compile!(sparse_schema)

# The module backend, and what it costs to build. Codegen is the boot bill: it happens once,
# in your application's start callback, and the roadmap wants it visible rather than folded
# into a startup time nobody attributes.
{present_codegen, named} = :timer.tc(fn -> Rupa.compile!(schema, as: Bench.Codecs.Present) end)

{sparse_codegen, sparse_named} =
  :timer.tc(fn -> Rupa.compile!(sparse_schema, as: Bench.Codecs.Sparse) end)

# =============================================
# The 1.0x line
# =============================================
#
# What you would write by hand for this one shape, with the same checks.

defmodule HandWritten do
  def decode(%{
        "id" => id,
        "name" => name,
        "active" => active,
        "score" => score,
        "profile" => profile,
        "tags" => tags
      })
      when is_binary(id) and byte_size(id) > 0 and is_binary(name) and byte_size(name) > 0 and
             is_boolean(active) and is_number(score) and score >= 0 do
    with {:ok, profile} <- profile(profile), {:ok, tags} <- tags(tags, []) do
      {:ok,
       %{
         id: id,
         name: name,
         active: active,
         score: score * 1.0,
         profile: profile,
         tags: tags
       }}
    end
  end

  def decode(_data), do: {:error, :invalid}

  defp profile(%{"age" => age, "city" => city, "settings" => settings})
       when is_integer(age) and age >= 0 and age <= 150 and is_binary(city) do
    with {:ok, settings} <- settings(settings),
         do: {:ok, %{age: age, city: city, settings: settings}}
  end

  defp profile(_data), do: {:error, :invalid}

  defp settings(%{"theme" => theme, "size" => size}) when is_binary(theme) and is_integer(size) do
    {:ok, %{theme: theme, size: size}}
  end

  defp settings(_data), do: {:error, :invalid}

  defp tags([], acc), do: {:ok, :lists.reverse(acc)}

  defp tags([tag | rest], acc) when is_binary(tag) and byte_size(tag) > 0 do
    tags(rest, [tag | acc])
  end

  defp tags(_list, _acc), do: {:error, :invalid}
end

# =============================================
# Run
# =============================================

{:ok, _} = Rupa.decode(codec, present)
{:ok, _} = Rupa.decode(sparse_codec, sparse)
{:ok, _} = HandWritten.decode(present)

empty = Bench.measure(fn -> :ok end, iterations)

hand = Bench.net(fn -> HandWritten.decode(present) end, iterations, empty)
closure = Bench.net(fn -> Rupa.decode(codec, present) end, iterations, empty)
absent = Bench.net(fn -> Rupa.decode(sparse_codec, sparse) end, iterations, empty)
module = Bench.net(fn -> Rupa.decode(named, present) end, iterations, empty)
module_absent = Bench.net(fn -> Rupa.decode(sparse_named, sparse) end, iterations, empty)

# Both backends decode the same fixture to the same value, every run of this file.
{:ok, same} = Rupa.decode(codec, present)
{:ok, ^same} = Rupa.decode(named, present)

Bench.banner(iterations)

IO.puts(
  String.pad_trailing("case", 22) <>
    " | " <>
    String.pad_leading("us/op", 9) <>
    " | " <>
    String.pad_leading("reds/op", 9) <>
    " | " <> String.pad_leading("words/op", 9) <> " | " <> String.pad_leading("rel", 10)
)

IO.puts(String.duplicate("-", 70))

Bench.row("hand-written", hand, hand)
Bench.row("closure, all present", closure, hand)
Bench.row("closure, 3 absent", absent, hand)
Bench.row("module, all present", module, hand)
Bench.row("module, 3 absent", module_absent, hand)

IO.puts("""

Codegen, once per schema at boot: #{Float.round(present_codegen / 1000, 1)} ms for the nested
fixture's 6 fields, #{Float.round(sparse_codegen / 1000, 1)} ms for the sparse one.
""")

IO.puts("""

Budget, from bench/BUDGET.md: the closure backend stays within 5x of hand-written and under
200 words/op; the module backend within 2x and under 100 words/op.
""")

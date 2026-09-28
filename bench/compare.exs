# bench/compare.exs — Rupa against what Elixir developers reach for today.
#
#     mix run bench/compare.exs
#
# How the numbers are taken, and why they are words and reductions rather than a wall clock,
# is in bench/measure.exs. The fixture is bench/decode.exs's, so every row here is comparable
# to the budget table there.
#
# **What is being compared, exactly.** One shape: a string-keyed map in, a validated typed
# value out, with the same checks on the same fields. That is the only thing all four of these
# do, and it is worth saying what each of them does *differently* rather than letting a table
# imply they are interchangeable:
#
#   * Rupa and Peri both take the wire map and hand back an atom-keyed map. Peri validates in
#     place and keeps the shape; Rupa stages the schema first and the value it returns has been
#     converted, so a `date_time` would come back a `DateTime` rather than a string. There is
#     no format in this fixture, so that difference costs Rupa nothing here and would cost it
#     something on a realistic payload -- which is the direction that flatters Peri, not Rupa.
#   * Ecto casts into structs, which is more work than either. It is here because it is what
#     most projects already have, not because it is trying to be a schema library.
#   * Hand-written is the 1.0x line: what you would write for this one shape, with the same
#     checks, and no schema at all.
#
# The one check Ecto cannot state declaratively is the per-element `min: 1` on the list of
# tags; `validate_change/3` below is what that costs, and it is the honest version rather than
# quietly dropping the constraint from its column.

Code.require_file("measure.exs", __DIR__)

alias Rupa.T

iterations = 2_000

# =============================================
# The fixture
# =============================================

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

text = IO.iodata_to_binary(:json.encode(present))

# =============================================
# Rupa
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

codec = Rupa.compile!(schema)
named = Rupa.compile!(schema, as: Bench.Compare.Codec)

# =============================================
# Peri
# =============================================

peri = %{
  id: {:required, {:string, {:min, 1}}},
  name: {:required, {:string, {:min, 1}}},
  active: {:required, :boolean},
  score: {:required, {:float, {:gte, 0.0}}},
  profile:
    {:required,
     %{
       age: {:required, {:integer, {:range, {0, 150}}}},
       city: {:required, :string},
       settings: {:required, %{theme: {:required, :string}, size: {:required, :integer}}}
     }},
  tags: {:required, {:list, {:string, {:min, 1}}}}
}

# =============================================
# Ecto
# =============================================

defmodule Compare.Settings do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:theme, :string)
    field(:size, :integer)
  end

  def changeset(struct, params) do
    struct |> cast(params, [:theme, :size]) |> validate_required([:theme, :size])
  end
end

defmodule Compare.Profile do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:age, :integer)
    field(:city, :string)
    embeds_one(:settings, Compare.Settings)
  end

  def changeset(struct, params) do
    struct
    |> cast(params, [:age, :city])
    |> cast_embed(:settings, required: true)
    |> validate_required([:age, :city])
    |> validate_number(:age, greater_than_or_equal_to: 0, less_than_or_equal_to: 150)
  end
end

defmodule Compare.Payload do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:id, :string)
    field(:name, :string)
    field(:active, :boolean)
    field(:score, :float)
    field(:tags, {:array, :string})
    embeds_one(:profile, Compare.Profile)
  end

  def changeset(struct, params) do
    struct
    |> cast(params, [:id, :name, :active, :score, :tags])
    |> cast_embed(:profile, required: true)
    |> validate_required([:id, :name, :active, :score, :tags])
    |> validate_length(:id, min: 1)
    |> validate_length(:name, min: 1)
    |> validate_number(:score, greater_than_or_equal_to: 0)
    # There is no declarative way to say "every element is at least one character", so this is
    # the column's honest cost rather than a constraint dropped to make the row look better.
    |> validate_change(:tags, fn :tags, tags ->
      if Enum.all?(tags, &(&1 != "")), do: [], else: [tags: "must not be empty"]
    end)
  end

  def cast_all(params) do
    %__MODULE__{} |> changeset(params) |> Ecto.Changeset.apply_action(:insert)
  end
end

# =============================================
# The 1.0x line
# =============================================

defmodule Compare.HandWritten do
  @moduledoc false

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
       %{id: id, name: name, active: active, score: score * 1.0, profile: profile, tags: tags}}
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
# Every one of them accepts the fixture
# =============================================
#
# Asserted before anything is measured, so a row can never be fast because it stopped early.

{:ok, _} = Compare.HandWritten.decode(present)
{:ok, _} = Rupa.decode(codec, present)
{:ok, _} = Rupa.decode(named, present)
{:ok, _} = Peri.validate(peri, present)
{:ok, _} = Compare.Payload.cast_all(present)
{:ok, _} = Rupa.decode_json(codec, text)

# And every one of them refuses a payload that breaks one constraint, which is the other half
# of "the same checks": a column that validates less is not a faster column.
broken = put_in(present, ["profile", "age"], 999)

{:error, _} = Compare.HandWritten.decode(broken)
{:error, _} = Rupa.decode(codec, broken)
{:error, _} = Peri.validate(peri, broken)
{:error, _} = Compare.Payload.cast_all(broken)

# =============================================
# Run
# =============================================

empty = Bench.measure(fn -> :ok end, iterations)

hand = Bench.net(fn -> Compare.HandWritten.decode(present) end, iterations, empty)
closure = Bench.net(fn -> Rupa.decode(codec, present) end, iterations, empty)
module = Bench.net(fn -> Rupa.decode(named, present) end, iterations, empty)
peri_run = Bench.net(fn -> Peri.validate(peri, present) end, iterations, empty)
ecto_run = Bench.net(fn -> Compare.Payload.cast_all(present) end, iterations, empty)

floor = Bench.net(fn -> :json.decode(text) end, iterations, empty)
json_closure = Bench.net(fn -> Rupa.decode_json(codec, text) end, iterations, empty)
json_module = Bench.net(fn -> Rupa.decode_json(named, text) end, iterations, empty)

Bench.banner(iterations)

header = fn ->
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

IO.puts("a wire map in, a validated typed value out — relative to hand-written\n")
header.()

Bench.row("hand-written", hand, hand)
Bench.row("Rupa, module", module, hand)
Bench.row("Rupa, closure", closure, hand)
Bench.row("Peri.validate/2", peri_run, hand)
Bench.row("Ecto embedded cast", ecto_run, hand)

IO.puts("\n\nbytes in — relative to parsing alone, which validates nothing\n")
header.()

Bench.row(":json.decode/1", floor, floor)
Bench.row("Rupa, module", json_module, floor)
Bench.row("Rupa, closure", json_closure, floor)

IO.puts("""

What to read. The first table is the claim: fastest-on-the-BEAM for the shape every one of
these is trying to do, and within a small factor of code written for one payload and nothing
else. The second is the one that matters to a request handler, because bytes are what arrives
— and the gap between the floor and Rupa is how much validation costs on top of parsing, which
is the number `bench/json.exs` draws in the other direction.

Versions: Peri #{Application.spec(:peri, :vsn)}, Ecto #{Application.spec(:ecto, :vsn)}.
""")

# =============================================
# The budget, asserted
# =============================================
#
# This file runs in CI, and a benchmark that only prints is a benchmark nobody reads until
# someone happens to look. So the claims it makes are checked here and the process exits
# non-zero when one stops holding. Words and reductions only: `us/op` swings by a factor of two
# on a shared runner, which is why `bench/BUDGET.md` tells you to distrust that column.
#
# The margins against Peri and Ecto are deliberately loose. Measured they are ~65x and ~50x on
# reductions; ten is the number that catches "Rupa got an order of magnitude worse" without
# going red because someone else's library got faster, which would be good news.

checks = [
  {"module backend within the words budget", trunc(module.words) <= 100},
  {"module backend within the reductions budget", trunc(module.reductions) <= 40},
  {"closure backend within the words budget", trunc(closure.words) <= 200},
  {"closure backend within the reductions budget", trunc(closure.reductions) <= 130},
  {"module backend does 10x less work than Peri", module.reductions * 10 <= peri_run.reductions},
  {"module backend does 10x less work than Ecto", module.reductions * 10 <= ecto_run.reductions},
  {"module backend allocates less than hand-written x2", module.words <= hand.words * 2}
]

case Enum.reject(checks, &elem(&1, 1)) do
  [] ->
    IO.puts("Budget: #{length(checks)} checks, all holding.\n")

  failed ->
    IO.puts("Budget: #{length(failed)} of #{length(checks)} checks no longer hold.\n")
    Enum.each(failed, fn {what, _} -> IO.puts("  * #{what}") end)

    IO.puts("""

    bench/BUDGET.md is what these are from. A milestone that moves a number past its budget
    either fixes it or changes that file with a reason.
    """)

    System.halt(1)
end

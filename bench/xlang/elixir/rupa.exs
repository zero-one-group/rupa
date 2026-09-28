# bench/xlang/elixir/rupa.exs — Rupa's column in the cross-language table.
#
#     mix run bench/xlang/elixir/rupa.exs bench/xlang/fixture.json
#
# One line out: `<name> <ns/op> <iterations>`. bench/xlang/README.md says what is being timed
# and what each column is allowed to do differently.

alias Rupa.T

[path] = System.argv()
text = File.read!(path)

# Setup, outside the loop: this is the whole argument for staging, so it had better not be
# counted as run-time work in the one table where a compiled library is being compared to
# interpreted ones.
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

codec = Rupa.compile!(schema, as: XLang.Codec)

# The fixture has to decode before anything is timed, so a fast column can never be one that
# quietly failed.
{:ok, _} = Rupa.decode_json(codec, text)

# Both are read from the environment so every column can be re-run at a different warmup with
# one variable, which is the only way to tell a slow library from an under-warmed one.
warmup = String.to_integer(System.get_env("XLANG_WARMUP", "50000"))
iterations = String.to_integer(System.get_env("XLANG_ITERATIONS", "100000"))

run = fn n ->
  Enum.each(1..n, fn _ -> Rupa.decode_json!(codec, text) end)
end

run.(warmup)
{micros, :ok} = :timer.tc(fn -> run.(iterations) end)

IO.puts("rupa #{Float.round(micros * 1000 / iterations, 1)} #{iterations}")

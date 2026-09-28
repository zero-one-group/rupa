# bench/xlang/elixir/profile.exs — where does the Elixir column's number move, and when?
#
#     mix run bench/xlang/elixir/profile.exs bench/xlang/fixture.json
#
# The same work as rupa.exs, reported in chunks rather than as one number, with the process's
# own accounting beside each one. The two explanations for a column that wobbles look different
# here. A step -- fast for a while, then higher and staying there -- is the runtime, and the GC
# and heap columns beside it should say which part. Chunks scattered with no pattern, landing
# somewhere else the next time, is the operating system moving the process between cores and
# has nothing to do with Rupa.

alias Rupa.T

[path] = System.argv()
text = File.read!(path)

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
{:ok, _} = Rupa.decode_json(codec, text)

chunk = String.to_integer(System.get_env("XLANG_CHUNK", "10000"))
chunks = String.to_integer(System.get_env("XLANG_CHUNKS", "30"))

minor_gcs = fn ->
  {:garbage_collection, gc} = Process.info(self(), :garbage_collection)
  Keyword.fetch!(gc, :minor_gcs)
end

heap_words = fn ->
  {:total_heap_size, words} = Process.info(self(), :total_heap_size)
  words
end

# How many threads this VM thinks it has is half the question when the other half is which
# cores the host decided to give them, so it is printed rather than assumed.
IO.puts("""
schedulers online #{:erlang.system_info(:schedulers_online)}, \
dirty cpu #{:erlang.system_info(:dirty_cpu_schedulers_online)}, \
logical processors #{:erlang.system_info(:logical_processors_available)}
#{chunks} chunks of #{chunk}, one process throughout

chunk |     ns/op | minor GCs | heap words\
""")

Enum.reduce(1..chunks, minor_gcs.(), fn n, before ->
  {micros, :ok} =
    :timer.tc(fn -> Enum.each(1..chunk, fn _ -> Rupa.decode_json!(codec, text) end) end)

  now = minor_gcs.()

  :io.format("~5w | ~9.1f | ~9w | ~10w~n", [
    n,
    micros * 1000 / chunk,
    now - before,
    heap_words.()
  ])

  now
end)

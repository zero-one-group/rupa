# bench/measure.exs — how every benchmark in this directory counts.
#
# Not a benchmark itself: `bench/decode.exs` and `bench/union.exs` both start with
#
#     Code.require_file("measure.exs", __DIR__)
#
# No benchmarking dependency. The number that decides whether Rupa is usable under sustained
# load is words per op, and that comes from the process heap, not from a wall clock on a box
# that is also doing something else. Reductions are the scheduler's own view of the same work
# and are stable across machines; microseconds are the one column you should distrust.
#
# Method, for each case: a fresh process, N iterations, and the delta in allocated heap and in
# reductions divided by N. An empty loop is measured the same way and subtracted, so what is
# left is the work.

defmodule Bench do
  @moduledoc false

  # Words allocated is read the way benchee reads it: trace the process's garbage collections
  # and sum, for each one, the heap it had used since the last collection ended. A forced
  # collection after the loop flushes the tail.

  def measure(fun, iterations) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do: (:go -> :ok)
        loop(fun, iterations)
        :erlang.garbage_collect()
        send(parent, {ref, :erlang.process_info(self(), :reductions)})
        receive do: (:stop -> :ok)
      end)

    :erlang.trace(pid, true, [:garbage_collection])
    send(pid, :go)

    {micros, {:reductions, reductions}} = :timer.tc(fn -> receive do: ({^ref, info} -> info) end)

    :erlang.trace(pid, false, [:garbage_collection])
    words = allocated(pid, 0, 0)
    send(pid, :stop)

    %{
      micros: micros / iterations,
      words: words / iterations,
      reductions: reductions / iterations
    }
  end

  @doc "The same measurement with the loop's own cost taken out of it."
  def net(fun, iterations, empty) do
    measured = measure(fun, iterations)

    %{
      micros: measured.micros - empty.micros,
      words: measured.words - empty.words,
      reductions: measured.reductions - empty.reductions
    }
  end

  defp allocated(pid, acc, last_end) do
    receive do
      {:trace, ^pid, kind, info} when kind in [:gc_minor_start, :gc_major_start] ->
        allocated(pid, acc + Keyword.fetch!(info, :heap_size) - last_end, last_end)

      {:trace, ^pid, kind, info} when kind in [:gc_minor_end, :gc_major_end] ->
        allocated(pid, acc, Keyword.fetch!(info, :heap_size))

      {:trace, ^pid, _kind, _info} ->
        allocated(pid, acc, last_end)
    after
      0 -> acc
    end
  end

  defp loop(_fun, 0), do: :ok

  defp loop(fun, remaining) do
    fun.()
    loop(fun, remaining - 1)
  end

  def row(name, measured, baseline) do
    [
      String.pad_trailing(name, 22),
      pad(measured.micros, 3),
      pad(measured.reductions, 0),
      pad(measured.words, 0),
      pad(measured.micros / baseline.micros, 2) <> "x"
    ]
    |> Enum.join(" | ")
    |> IO.puts()
  end

  def pad(number, places) do
    number |> :erlang.float_to_binary([{:decimals, places}]) |> String.pad_leading(9)
  end

  def banner(iterations) do
    IO.puts("""

    #{:erlang.system_info(:system_version) |> to_string() |> String.trim()}\
    Elixir #{System.version()}, #{:erlang.system_info(:logical_processors_available)} schedulers
    #{iterations} iterations per case, #{DateTime.utc_now() |> DateTime.to_date()}
    """)
  end

  # `IO.warn/1` writes to the `:standard_error` device by name, so standing a StringIO in its
  # place for the duration is enough to hold on to what staging said rather than scrolling it
  # past. Used here to print the warning once, deliberately, instead of once per schema.
  def capturing_stderr(fun) do
    {:ok, string_io} = StringIO.open("")
    previous = Process.whereis(:standard_error)

    Process.unregister(:standard_error)
    Process.register(string_io, :standard_error)

    try do
      {fun.(), elem(StringIO.contents(string_io), 1)}
    after
      Process.unregister(:standard_error)
      Process.register(previous, :standard_error)
    end
  end
end

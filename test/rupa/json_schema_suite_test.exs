defmodule Rupa.JsonSchemaSuiteTest do
  use ExUnit.Case, async: true

  # The official JSON-Schema-Test-Suite, vendored and trimmed to the keywords Rupa claims.
  # test/fixtures/json-schema-suite/README.md says where it came from and why it lives here.
  #
  # The suite tests validation — does this instance satisfy this schema — and Rupa is a
  # decoder, so a case runs by decoding its schema into a Rupa schema and asking `valid?/2` about
  # every instance. A case whose schema Rupa cannot read is skipped under the reason
  # `Rupa.JsonSchema` gave, which is the point of the exercise: the skip list is the list of
  # things Rupa does not claim, and it should hold no surprises.
  #
  # `@deviations` is the other list, and the one that matters. Those are cases Rupa *can* read
  # and answers differently from the spec, on purpose. Each one is named down to the instance,
  # with the reason, and `Rupa.JsonSchema`'s moduledoc carries the same list in prose. Anything
  # not in either list has to pass.
  #
  # Both lists are asserted rather than printed. An earlier cut printed a report on every run and
  # asked a reader to notice if it had changed, which is not a gate — a reader who has seen it
  # forty times does not read it the forty-first. `RUPA_SUITE_REPORT=1` still prints it, for
  # writing up a milestone.

  @dir Path.join([__DIR__, "..", "fixtures", "json-schema-suite", "draft2020-12"])

  # Rupa compares numbers the way the BEAM does. Every entry below is that one decision seen
  # from a different angle, and `Rupa.JsonSchema`'s moduledoc states it once in prose.
  @by_term "a float is not an integer on the BEAM, and Rupa compares by term rather " <>
             "than by mathematical value — reconciling the two would cost a check on " <>
             "every decode, in every schema, to serve documents that write 1.0 and mean 1"

  # Every reason a case can be skipped under. A new one means Rupa stopped reading something it
  # used to read, or the corpus grew a shape nobody has looked at; one disappearing means Rupa
  # now handles it and `Rupa.JsonSchema` should say so. Either way it is a change worth failing
  # on rather than a number to skim.
  # `invalid_default` is Rupa reading the document but refusing to compile it: JSON Schema treats
  # `default` as a pure annotation, so a default outside the field's own constraints is still a
  # valid schema there, while Rupa materialises defaults and so insists they decode. One
  # `default.json` case (a `number` with `maximum: 3` and `default: 5`) lands here.
  @skips ~w(
    untyped_schema invalid_scalar unsupported_keyword unsupported_schema
    unsupported_type_union unsupported_open_tuple invalid_pattern invalid_default
  )a

  @deviations %{
    {"type.json", "integer type matches integers",
     "a float with zero fractional part is an integer"} => @by_term,
    {"const.json", "const with 0 does not match other zero-like types", "float zero is valid"} =>
      @by_term,
    {"const.json", "const with 1 does not match true", "float one is valid"} => @by_term,
    {"const.json", "const with -2.0 matches integer and float types", "integer -2 is valid"} =>
      @by_term,
    {"const.json", "float and integers are equal up to 64-bit representation limits",
     "float is valid"} => @by_term,
    {"enum.json", "enum with 0 does not match false", "float zero is valid"} => @by_term,
    {"enum.json", "enum with 1 does not match true", "float one is valid"} => @by_term
  }

  test "the official suite, on the keywords Rupa claims" do
    results = @dir |> files() |> Enum.flat_map(&run/1)

    {skipped, ran} = Enum.split_with(results, &match?({:skip, _, _}, &1))
    {failed, passed} = Enum.split_with(ran, &match?({:fail, _, _}, &1))
    {deviations, failures} = Enum.split_with(failed, &deviation?/1)

    if System.get_env("RUPA_SUITE_REPORT"), do: report(passed, deviations, skipped, failures)

    reasons = skipped |> Enum.map(fn {:skip, _where, reason} -> reason end) |> Enum.uniq()

    assert Enum.sort(reasons) == Enum.sort(@skips), """
    the reasons cases are skipped under have changed.

      no longer seen: #{inspect(@skips -- reasons)}
      new:            #{inspect(reasons -- @skips)}

    A reason that has gone means Rupa reads something it used to refuse, and `Rupa.JsonSchema`
    should say so. A new one means it refuses something nobody has looked at yet.
    """

    stale = Map.keys(@deviations) -- Enum.map(deviations, fn {:fail, where, _} -> where end)

    assert stale == [], """
    #{length(stale)} deviation(s) listed here that the suite no longer reports. Rupa agrees with
    the spec on these now, so the entries should go:

    #{Enum.map_join(stale, "\n", &"  #{inspect(&1)}")}
    """

    assert failures == [], """
    #{length(failures)} case(s) Rupa claims to handle and answers differently from the spec.
    Either the implementation is wrong, or the disagreement is deliberate and belongs in
    @deviations here and in Rupa.JsonSchema's moduledoc.

    #{Enum.map_join(Enum.take(failures, 20), "\n", &describe/1)}
    """
  end

  defp files(dir) do
    dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  end

  defp run(path) do
    file = Path.basename(path)

    path
    |> File.read!()
    |> parse()
    |> Enum.flat_map(fn group -> group(file, group) end)
  end

  # The suite's own files are JSON, and Rupa reads a JSON null as `nil` — so the fixtures are
  # parsed the way `Rupa.decode_json/3` parses a document, not the way `:json.decode/1` does.
  defp parse(text) do
    {value, :ok, _rest} = :json.decode(text, :ok, %{null: nil})
    value
  end

  defp group(file, %{"description" => description, "schema" => document, "tests" => tests}) do
    case compile(document) do
      {:ok, codec} ->
        Enum.map(tests, fn one -> instance(file, description, codec, one) end)

      {:skip, reason} ->
        [{:skip, {file, description}, reason}]
    end
  end

  defp compile(document) do
    with {:ok, schema} <- Rupa.JsonSchema.decode(document),
         {:ok, codec} <- Rupa.compile(schema) do
      {:ok, codec}
    else
      {:error, [error | _rest]} -> {:skip, error.code}
    end
  end

  defp instance(file, description, codec, %{"description" => about} = one) do
    where = {file, description, about}

    if Rupa.valid?(codec, one["data"]) == one["valid"],
      do: {:pass, where, nil},
      else: {:fail, where, one["valid"]}
  end

  defp deviation?({:fail, where, _expected}), do: Map.has_key?(@deviations, where)

  defp describe({_kind, {file, description, about}, expected}) do
    "  #{file}: #{description} / #{about} — the suite says #{inspect(expected)}"
  end

  # Not the gate — the assertions above are. This is for a human writing up what changed, and it
  # only runs when one asks for it.
  defp report(passed, deviations, skipped, failures) do
    ran = length(passed) + length(deviations) + length(failures)

    IO.puts("""

    JSON-Schema-Test-Suite, draft2020-12, #{length(files(@dir))} files
    #{length(passed)}/#{ran} instances agree (#{percent(length(passed), ran)}), \
    #{length(deviations)} deviate on purpose, #{length(skipped)} cases skipped

    #{reasons(skipped)}\
    #{deviation_lines(deviations)}\
    """)
  end

  defp reasons([]), do: ""

  defp reasons(skipped) do
    lines =
      skipped
      |> Enum.frequencies_by(fn {:skip, _where, reason} -> reason end)
      |> Enum.sort_by(fn {_reason, count} -> -count end)
      |> Enum.map_join("\n", fn {reason, count} ->
        "  #{String.pad_leading(to_string(count), 4)}  #{reason}"
      end)

    "skipped, by what Rupa said it could not read:\n" <> lines <> "\n"
  end

  defp deviation_lines([]), do: ""

  # Grouped by reason rather than by case: there are more instances than there are decisions,
  # and it is the decisions that want reading.
  defp deviation_lines(deviations) do
    lines =
      deviations
      |> Enum.group_by(fn {:fail, where, _expected} -> Map.fetch!(@deviations, where) end)
      |> Enum.map_join("\n\n", fn {reason, cases} ->
        "  #{reason}\n" <>
          Enum.map_join(cases, "\n", fn {:fail, {file, _case, about}, _expected} ->
            "      #{file}: #{about}"
          end)
      end)

    "\ndeliberate deviations:\n" <> lines <> "\n"
  end

  defp percent(_part, 0), do: "0%"
  defp percent(part, whole), do: "#{Float.round(part * 100 / whole, 1)}%"
end

defmodule Rupa.FormatSuiteTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  # The official JSON-Schema-Test-Suite's `optional/format` corpus, for the ten formats Rupa has,
  # vendored beside the rest of the suite (test/fixtures/json-schema-suite/README.md). Its
  # schemas are `{"format": X}` with no type, which `Rupa.JsonSchema.decode/1` refuses by design,
  # so this runs each string case at the format itself: through `Rupa.Format`, and through a
  # compiled `T.string(format: X)` on both backends. The non-string cases are JSON Schema's "a
  # format ignores other types", which a typed Rupa node has no way to say.
  #
  # There is no list of deviations, and that is the point: every string case agrees, and one
  # that stops agreeing fails here rather than drifting.

  @dir Path.join([__DIR__, "..", "fixtures", "json-schema-suite", "draft2020-12"])

  @formats %{
    "date-time" => :date_time,
    "date" => :date,
    "time" => :time,
    "duration" => :duration,
    "uuid" => :uuid,
    "email" => :email,
    "uri" => :uri,
    "ipv4" => :ipv4,
    "ipv6" => :ipv6,
    "hostname" => :hostname
  }

  test "the corpus has a file for every format and no more" do
    files = @dir |> Path.join("optional/format/*.json") |> Path.wildcard()

    assert files |> Enum.map(&Path.basename(&1, ".json")) |> Enum.sort() ==
             @formats |> Map.keys() |> Enum.sort()

    assert Enum.sort(Map.values(@formats)) == Enum.sort(Rupa.Format.names())
  end

  for {file, format} <- @formats do
    @corpus file
    @format format

    test "#{file}: every string case agrees" do
      cases = cases(@corpus)
      closure = Rupa.compile!(T.string(format: @format))
      {:ok, module} = Rupa.compile(T.string(format: @format), as: module_name(@format))

      disagreements =
        Enum.flat_map(cases, fn {description, data, valid} ->
          answers = [
            match?({:ok, _}, Rupa.Format.decode(@format, data)),
            Rupa.valid?(closure, data),
            Rupa.valid?(module, data)
          ]

          if answers == [valid, valid, valid],
            do: [],
            else: [
              "  #{inspect(data)} (#{description}): #{valid} there, #{inspect(answers)} here"
            ]
        end)

      assert cases != []

      assert disagreements == [], """
      #{length(disagreements)} case(s) where Rupa and the corpus disagree about #{@corpus}. The
      three answers are Rupa.Format, the closure backend and the module backend.

      #{Enum.join(disagreements, "\n")}
      """
    end
  end

  defp cases(file) do
    [@dir, "optional", "format", file <> ".json"]
    |> Path.join()
    |> File.read!()
    |> :json.decode()
    |> Enum.flat_map(fn group -> group["tests"] end)
    |> Enum.filter(&is_binary(&1["data"]))
    |> Enum.map(&{&1["description"], &1["data"], &1["valid"]})
  end

  defp module_name(format), do: Module.concat(Rupa.FormatSuite, Macro.camelize("#{format}"))
end

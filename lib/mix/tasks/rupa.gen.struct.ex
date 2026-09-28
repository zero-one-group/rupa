defmodule Mix.Tasks.Rupa.Gen.Struct do
  @shortdoc "Writes a struct module for every into: in a schema"

  @moduledoc """
  Writes the struct modules a schema's `into:` options name.

      $ mix rupa.gen.struct MyApp.Schemas.user
      * creating lib/my_app/user.ex
      * creating lib/my_app/address.ex

  The argument names a zero-arity function in your own project that returns a schema. The task
  compiles the project, calls it, stages the schema, and writes one file per `into:` module it
  finds — the root's and every nested one — at the path that module's name conventionally has
  under `lib/`.

  What it writes is a `defstruct` and a `@type t`, and nothing else: no `use`, no import of
  Rupa, no behaviour. The file is yours from the moment it lands. Re-running the task shows
  what a change to the schema would write, and `--force` is how you take it.

  Staging is what makes the keys right. They are the names after `rename_all:`, `from:` and
  `keys:` have been spent — the keys `Rupa.decode/3` will actually put in the struct — so the
  generated module is the one `Rupa.compile/2` will accept rather than one that looks close.

  ## Options

    * `--force` — overwrite files that already exist. Without it, they are left alone and
      reported.
    * `--dry-run` — print what would be written, and write nothing.

  ## The gap it closes

  `into:` is a soft dependency: `Rupa.compile/2` refuses a schema whose struct module is not
  loaded, or is missing a key the object decodes to. So the loop is to change the schema, run
  this, and commit both.
  """

  use Mix.Task

  alias Rupa.Error
  alias Rupa.IR
  alias Rupa.Stage

  @switches [force: :boolean, dry_run: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, argv} = OptionParser.parse!(argv, strict: @switches)

    Mix.Task.run("compile", [])

    argv
    |> target()
    |> schema()
    |> modules()
    |> Enum.each(&write(&1, opts))
  end

  defp target([arg]) do
    parts = String.split(arg, ".")
    {name, namespace} = List.pop_at(parts, -1)

    cond do
      namespace == [] or not Enum.all?(namespace, &upper?/1) ->
        Mix.raise("expected a module and a function, as in MyApp.Schemas.user, got #{arg}")

      upper?(name) ->
        Mix.raise("#{arg} names a module; this task wants the function that returns the schema")

      true ->
        {Module.concat(namespace), String.to_atom(name)}
    end
  end

  defp target(_argv) do
    Mix.raise("expected exactly one argument: the function returning the schema")
  end

  defp upper?(part), do: String.first(part) =~ ~r/\p{Lu}/u

  defp schema({module, function}) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      staged(module, function)
    else
      Mix.raise("#{inspect(module)}.#{function}/0 is not defined")
    end
  end

  # `structs: :skip` on purpose: this task is what makes those modules exist, so it cannot be
  # made to wait for them.
  defp staged(module, function) do
    case Stage.run(apply(module, function, []), structs: :skip) do
      {:ok, program} ->
        {program, "#{inspect(module)}.#{function}/0"}

      {:error, errors} ->
        Mix.raise("#{inspect(module)}.#{function}/0 is not a valid schema:\n" <> report(errors))
    end
  end

  defp report(errors) do
    Enum.map_join(errors, "\n", fn error ->
      "  " <> Error.pointer(error) <> " " <> Error.message(error)
    end)
  end

  # =============================================
  # Collecting
  # =============================================

  defp modules({%{root: root, defs: defs}, source}) do
    collected = Enum.reduce([root | Map.values(defs)], %{}, &collect(&1, &2, defs))

    collected
    |> Map.values()
    |> Enum.sort_by(& &1.module)
    |> Enum.map(&Map.put(&1, :source, source))
  end

  defp collect(%IR.Object{into: nil} = object, acc, defs), do: fields(object, acc, defs)

  defp collect(%IR.Object{into: module} = object, acc, defs) do
    found = %{module: module, keys: Enum.map(object.fields, &key(&1, defs))}

    case Map.fetch(acc, module) do
      {:ok, ^found} ->
        fields(object, acc, defs)

      {:ok, _other} ->
        Mix.raise("#{inspect(module)} is the into: of two objects with different fields")

      :error ->
        fields(object, Map.put(acc, module, found), defs)
    end
  end

  defp collect(%IR.Tagged{branches: branches}, acc, defs) do
    Enum.reduce(branches, acc, &collect(&1.ir, &2, defs))
  end

  defp collect(%IR.Fixed{members: members}, acc, defs),
    do: Enum.reduce(members, acc, &collect(&1, &2, defs))

  defp collect(%IR.Union{members: members}, acc, defs),
    do: Enum.reduce(members, acc, &collect(&1, &2, defs))

  defp collect(%IR.Array{of: inner}, acc, defs), do: collect(inner, acc, defs)
  defp collect(%IR.Dict{of: inner}, acc, defs), do: collect(inner, acc, defs)
  defp collect(%IR.Nullable{of: inner}, acc, defs), do: collect(inner, acc, defs)
  defp collect(_leaf, acc, _defs), do: acc

  defp fields(%IR.Object{fields: fields}, acc, defs) do
    Enum.reduce(fields, acc, &collect(&1.ir, &2, defs))
  end

  defp key(%IR.Field{} = field, defs) do
    %{name: field.key, type: Enum.join(alternatives(field, defs), " | "), default: field.default}
  end

  # An absent optional field leaves the module's own default behind, so the type carries the
  # `nil` that stands for absent. A field with a `default:` never can: decoding fills it in.
  defp alternatives(%IR.Field{presence: :optional, default: :none, ir: ir}, defs) do
    Enum.uniq(alts(ir, defs) ++ ["nil"])
  end

  defp alternatives(%IR.Field{ir: ir}, defs), do: Enum.uniq(alts(ir, defs))

  # =============================================
  # Types
  # =============================================
  #
  # A nested struct is written as `%MyApp.Address{}` rather than `MyApp.Address.t()`: it says
  # the same thing and needs no `t/0` on the other module, so a hand-written struct someone
  # already had works as an `into:` without being asked for a typespec first.

  defp alts(%IR.Scalar{kind: :string, format: format}, _defs), do: [scalar_format(format)]
  defp alts(%IR.Scalar{kind: :integer}, _defs), do: ["integer()"]
  defp alts(%IR.Scalar{kind: :float}, _defs), do: ["float()"]
  defp alts(%IR.Scalar{kind: :boolean}, _defs), do: ["boolean()"]
  defp alts(%IR.Scalar{kind: :null}, _defs), do: ["nil"]
  defp alts(%IR.Const{values: values}, _defs), do: Enum.map(values, &constant/1)
  defp alts(%IR.Object{into: nil}, _defs), do: ["map()"]
  defp alts(%IR.Object{into: module}, _defs), do: ["%#{inspect(module)}{}"]
  defp alts(%IR.Array{of: inner}, defs), do: ["[#{joined(inner, defs)}]"]
  defp alts(%IR.Dict{of: inner}, defs), do: ["%{optional(String.t()) => #{joined(inner, defs)}}"]
  defp alts(%IR.Nullable{of: inner}, defs), do: alts(inner, defs) ++ ["nil"]
  defp alts(%IR.Union{members: members}, defs), do: Enum.flat_map(members, &alts(&1, defs))

  defp alts(%IR.Fixed{members: members}, defs) do
    ["{#{Enum.map_join(members, ", ", &joined(&1, defs))}}"]
  end

  defp alts(%IR.Tagged{branches: branches}, defs) do
    Enum.map(branches, fn branch -> "{#{inspect(branch.tag)}, #{joined(branch.ir, defs)}}" end)
  end

  # A recursive ref is a struct when the definition it names is one, and otherwise the only
  # honest thing left: this is where a type would have to be written by hand.
  defp alts(%IR.Ref{name: name}, defs) do
    case Map.fetch!(defs, name) do
      %IR.Object{into: module} when module != nil -> ["%#{inspect(module)}{}"]
      _other -> ["term()"]
    end
  end

  defp joined(ir, defs), do: ir |> alts(defs) |> Enum.uniq() |> Enum.join(" | ")

  defp scalar_format(format) when format in [:date_time], do: "DateTime.t()"
  defp scalar_format(:date), do: "Date.t()"
  defp scalar_format(:time), do: "Time.t()"
  defp scalar_format(:duration), do: "Duration.t()"
  defp scalar_format(_stays_a_string), do: "String.t()"

  defp constant(value) when is_boolean(value), do: "boolean()"
  defp constant(value) when is_atom(value), do: inspect(value)
  defp constant(value) when is_integer(value), do: "integer()"
  defp constant(value) when is_float(value), do: "float()"
  defp constant(_string), do: "String.t()"

  # =============================================
  # Writing
  # =============================================

  defp write(%{module: module} = target, opts) do
    path = Path.join("lib", Macro.underscore(module) <> ".ex")
    source = render(target)

    cond do
      opts[:dry_run] -> say(:cyan, "would write", path <> "\n\n" <> indent(source))
      not File.exists?(path) -> create(path, source, "creating")
      opts[:force] -> create(path, source, "replacing")
      true -> say(:yellow, "skipping", "#{path} (exists; pass --force to overwrite)")
    end
  end

  defp create(path, source, verb) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    say(:green, verb, path)
  end

  defp say(colour, verb, message) do
    Mix.shell().info([colour, "* ", verb, " ", :reset, message])
  end

  defp indent(source), do: source |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  defp render(%{module: module, keys: keys, source: source}) do
    """
    defmodule #{inspect(module)} do
      @moduledoc \"\"\"
      Written by `mix rupa.gen.struct` from `#{source}`.

      Yours to edit. Re-running the task shows what a change to the schema would write.
      \"\"\"

      @type t :: #{struct_type(keys)}

      defstruct #{defstruct_list(keys)}
    end
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  # Both of these go through a printer rather than through interpolation, because a decoded key
  # is an atom and not every atom is a bare identifier. `keys: :atom` on a string-named object
  # is the supported way to make a struct out of a document's property names, and a document is
  # perfectly entitled to call one `first-name` -- which has to come out as `"first-name":` in
  # both places, and would be a syntax error spelled any other way.
  defp struct_type(keys) do
    pairs = Enum.map(keys, fn key -> {key.name, Code.string_to_quoted!(key.type)} end)

    Macro.to_string({:%, [], [{:__MODULE__, [], nil}, {:%{}, [], pairs}]})
  end

  # A keyword list has to have its bare names first, so the fields carrying a default go last
  # whatever order they were staged in. The value is routed through `inspect/1` and back, which
  # is what writes it the way source would -- a `Date` as `~D[...]`, a `MapSet` as
  # `MapSet.new([...])` -- and raises rather than writing a broken file if a schema ever holds
  # something that does not inspect as code.
  defp defstruct_list(keys) do
    {plain, defaulted} = Enum.split_with(keys, &(&1.default == :none))

    pairs =
      Enum.map(defaulted, fn %{name: name, default: {:value, value}} ->
        {name,
         Code.string_to_quoted!(inspect(value, limit: :infinity, printable_limit: :infinity))}
      end)

    Macro.to_string(Enum.map(plain, & &1.name) ++ pairs)
  end
end

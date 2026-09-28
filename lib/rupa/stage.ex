defmodule Rupa.Stage do
  @moduledoc """
  The staging pass: schema in, `Rupa.IR` out.

  This is where the work a decoder would otherwise repeat on every call happens once. Refs are
  resolved and, unless they are on a cycle, inlined outright. Object fields become an ordered
  list carrying their names, whether they are required, and their default. Constraints become
  an ordered check list. `enum` and `literal` collapse into one lookup table.

  Wire names are spent here too: `rename_all:`, `from:`, `to:` and `keys:` become the three
  names a field carries, so no backend ever looks at a case convention and no atom is ever
  interned from wire data.

  It runs `Rupa.Schema.validate/1` first, so a malformed schema never reaches the IR, and it
  checks `into:` against the module it names once the decoded keys are known.

  Staging is the one place in Rupa with a side effect, and it is one line: a schema that nests
  untagged unions gets an `IO.warn/1`, because that is the only construct in the vocabulary
  whose cost doubles with depth and the only one you can write without meaning to.
  """

  alias Rupa.Closure
  alias Rupa.Error
  alias Rupa.IR
  alias Rupa.Schema

  @string_checks [:len, :min, :max, :pattern]
  @number_checks [:gte, :gt, :lte, :lt, :multiple_of]
  @array_checks [:min, :max, :unique]

  # The four formats that decode to a value and re-encode to a canonical spelling. A `len:`/
  # `pattern:` on one checks the incoming spelling, which the canonical spelling need not match, so
  # the codec would accept an input it then cannot re-encode. The other six formats hand the string
  # back unchanged, so a check on them round-trips and is allowed.
  @converting_formats [:date_time, :date, :time, :duration]

  @scalars [:string, :integer, :float, :boolean, :null]

  @doc """
  Validates a schema and stages it.

  `structs: :skip` leaves `into:` on the IR without checking that the module it names exists.
  That is for `mix rupa.gen.struct`, which stages a schema in order to write those modules;
  everything else wants the default, `structs: :check`.

      iex> {:ok, program} = Rupa.Stage.run(%{name: Rupa.T.string(min: 1)})
      iex> program.root
      %Rupa.IR.Object{
        fields: [
          %Rupa.IR.Field{
            key: :name,
            from: "name",
            to: "name",
            ir: %Rupa.IR.Scalar{kind: :string, checks: [min: 1], format: nil},
            presence: :required,
            default: :none
          }
        ],
        unknown: :strip
      }
  """
  @spec run(term(), keyword()) :: {:ok, IR.program()} | {:error, [Error.t()]}
  def run(schema, opts \\ []) do
    with {:ok, schema} <- Schema.validate(schema) do
      definitions = definitions(schema)
      cyclic = cyclic(definitions)

      try do
        program = %{
          root: node(schema, definitions, cyclic, []),
          defs: staged(definitions, cyclic)
        }

        acyclic!(program)

        program =
          if Keyword.get(opts, :structs, :check) == :check do
            structs!(program)
            defaults!(program)
          else
            program
          end

        warn_nested_unions(program)
        {:ok, program}
      catch
        {:rupa_stage, error} -> {:error, [error]}
      end
    end
  end

  defp staged(definitions, cyclic) do
    Map.new(cyclic, fn name ->
      {name, node(Map.fetch!(definitions, name), definitions, cyclic, [:defs, name])}
    end)
  end

  # =============================================
  # Definitions and cycles
  # =============================================

  defp definitions(schema) do
    schema |> collect(%{}) |> Map.put(:root, schema)
  end

  defp collect(schema, acc) do
    acc = Enum.reduce(own_defs(schema), acc, fn {name, s}, inner -> Map.put(inner, name, s) end)
    Enum.reduce(children(schema) ++ Enum.map(own_defs(schema), &elem(&1, 1)), acc, &collect/2)
  end

  defp own_defs({_kind, _payload, opts}) when is_list(opts), do: defs_in(opts)
  defp own_defs({_kind, opts}) when is_list(opts), do: defs_in(opts)

  defp defs_in(opts) do
    Enum.flat_map(opts, fn
      {:defs, defs} when is_map(defs) -> Map.to_list(defs)
      _entry -> []
    end)
  end

  defp children({:object, fields, _opts}), do: Map.values(fields)
  defp children({:tagged, branches, _opts}), do: Map.values(branches)

  defp children({kind, inner, _opts}) when kind in [:list, :map_of, :optional, :nullable],
    do: [inner]

  defp children({kind, members, _opts}) when kind in [:tuple, :union], do: members
  defp children(_leaf), do: []

  # A name is cyclic when it can reach itself. Only those stay as `%IR.Ref{}`; everything else
  # is inlined, so the decoder never looks anything up in the common case. Edges skip nested
  # `defs:`, because each definition is its own node in this graph.
  defp cyclic(definitions) do
    graph = Map.new(definitions, fn {name, schema} -> {name, refs(schema, [])} end)

    for {name, _edges} <- graph, reaches?(graph, name, name), into: MapSet.new(), do: name
  end

  defp refs({:ref, name, _opts}, acc), do: [name | acc]
  defp refs(schema, acc), do: Enum.reduce(children(schema), acc, &refs/2)

  defp reaches?(graph, from, target) do
    step(Map.get(graph, from, []), graph, target, MapSet.new())
  end

  defp step([], _graph, _target, _seen), do: false

  defp step([name | rest], graph, target, seen) do
    cond do
      name == target -> true
      MapSet.member?(seen, name) -> step(rest, graph, target, seen)
      true -> step(Map.get(graph, name, []) ++ rest, graph, target, MapSet.put(seen, name))
    end
  end

  # =============================================
  # Degenerate cycles
  # =============================================
  #
  # A healthy recursive ref survives staging *inside* a node that consumes input -- a list, an
  # object field, a tuple, a tagged branch -- and the decoder makes progress through that node
  # before it loops. A ref reached with nothing consuming in between is an unproductive loop that
  # never touches the value: `T.ref(:root)` alone, `x -> y -> x`, or a chain through the two
  # transitions that hand the *same* input on -- `nullable`, which tries its inner on the value
  # unchanged, and an untagged union, which tries every member on it. So those two are walked
  # through and everything else is a boundary; a ref met before a boundary is `:circular_ref`.
  # `Rupa.Gen` and `Rupa.explain/1` inherit this, because both go through staging.

  defp acyclic!(%{root: root, defs: defs}) do
    resolvable!(root, defs, [], [])
    Enum.each(defs, fn {name, ir} -> resolvable!(ir, defs, [name], [:defs, name]) end)
  end

  defp resolvable!(%IR.Ref{name: name}, defs, seen, path) do
    if name in seen do
      throw({:rupa_stage, Error.new(path, :circular_ref, %{name: name})})
    else
      resolvable!(Map.fetch!(defs, name), defs, [name | seen], path)
    end
  end

  defp resolvable!(%IR.Nullable{of: inner}, defs, seen, path) do
    resolvable!(inner, defs, seen, path)
  end

  defp resolvable!(%IR.Union{members: members}, defs, seen, path) do
    Enum.each(members, &resolvable!(&1, defs, seen, path))
  end

  defp resolvable!(_node, _defs, _seen, _path), do: :ok

  # =============================================
  # Nodes
  # =============================================

  defp node({:ref, name, _opts}, definitions, cyclic, path) do
    if MapSet.member?(cyclic, name) do
      %IR.Ref{name: name}
    else
      node(Map.fetch!(definitions, name), definitions, cyclic, path)
    end
  end

  defp node({kind, opts}, _definitions, _cyclic, path) when kind in @scalars do
    format = Keyword.get(opts, :format)
    checks = checks(kind, opts)

    if format in @converting_formats and checks != [] do
      meta = %{format: format, checks: Keyword.keys(checks)}
      throw({:rupa_stage, Error.new(path, :unsupported_format_constraint, meta)})
    end

    %IR.Scalar{kind: kind, checks: checks, format: format}
  end

  defp node({:literal, value, _opts}, _definitions, _cyclic, path) do
    const([value], path)
  end

  defp node({:enum, values, _opts}, _definitions, _cyclic, path) do
    const(values, path)
  end

  defp node({:object, fields, opts}, definitions, cyclic, path) do
    staged =
      fields
      |> Enum.sort_by(fn {key, _schema} -> key end)
      |> Enum.map(&field(&1, definitions, cyclic, path, opts))

    collisions!(staged, path)

    %IR.Object{
      fields: staged,
      unknown: Keyword.get(opts, :unknown, :strip),
      into: Keyword.get(opts, :into)
    }
  end

  defp node({:list, inner, opts}, definitions, cyclic, path) do
    %IR.Array{
      of: node(inner, definitions, cyclic, path ++ [:of]),
      checks: take(opts, @array_checks)
    }
  end

  defp node({:map_of, inner, _opts}, definitions, cyclic, path) do
    %IR.Dict{of: node(inner, definitions, cyclic, path ++ [:of])}
  end

  defp node({:nullable, inner, _opts}, definitions, cyclic, path) do
    %IR.Nullable{of: node(inner, definitions, cyclic, path)}
  end

  defp node({:tuple, members, _opts}, definitions, cyclic, path) do
    staged =
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} -> node(member, definitions, cyclic, path ++ [index]) end)

    %IR.Fixed{members: staged}
  end

  defp node({:union, members, _opts}, definitions, cyclic, path) do
    staged =
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} -> node(member, definitions, cyclic, path ++ [index]) end)

    %IR.Union{members: staged}
  end

  defp node({:tagged, branches, opts}, definitions, cyclic, path) do
    tag = Keyword.fetch!(opts, :tag)
    content = Keyword.get(opts, :content)
    tag_wire = Atom.to_string(tag)

    staged =
      branches
      |> Map.to_list()
      |> Enum.sort()
      |> Enum.map(&branch(&1, definitions, cyclic, path, content))

    if is_nil(content), do: tag_collisions!(staged, tag_wire, path)

    %IR.Tagged{
      tag: tag,
      tag_wire: tag_wire,
      content: content,
      content_wire: wire_name(content),
      branches: staged
    }
  end

  # Internally tagged, the tag rides in the branch's own map, so a branch field that reads or
  # writes the tag's wire key would fight the tag over that key: on the wire out, both are
  # emitted and one silently wins (`encode_json/3` would even write the key twice). That is a
  # schema the wire cannot express, so it stops the pass rather than round-tripping wrong.
  # An internally tagged branch is always an object: `Rupa.Schema.validate/1` rejects any other
  # shape with `:untagged_branch` before staging runs, so the field match here cannot fail.
  defp tag_collisions!(branches, tag_wire, path) do
    Enum.each(branches, fn %IR.Branch{ir: %IR.Object{fields: fields}, wire: wire} ->
      if Enum.any?(fields, fn field -> tag_wire in [field.from, field.to] end) do
        throw({:rupa_stage, Error.new(path ++ [wire], :tag_wire_conflict, %{key: tag_wire})})
      end
    end)
  end

  # The decoded tag is an atom, interned here from the branch name the schema gave -- which is
  # a literal in your source, not something that arrived on the wire. That is the same place an
  # object field name comes from, and it is why decoding a tagged union still cannot reach the
  # atom table.
  defp branch({wire, schema}, definitions, cyclic, path, content) do
    ir = node(schema, definitions, cyclic, path ++ [wire])

    %IR.Branch{
      wire: wire,
      tag: String.to_atom(wire),
      ir: ir,
      drop_tag: drop_tag?(content, ir)
    }
  end

  # Internally tagged, the tag sits in the same map as the branch's own fields, so a branch that
  # strips unknown keys ignores it for nothing and anything else has to be handed the map
  # without it. Adjacent tagging keeps the two apart, so there is never anything to drop.
  defp drop_tag?(content, _ir) when is_atom(content) and not is_nil(content), do: false
  defp drop_tag?(_content, %IR.Object{unknown: :strip}), do: false
  defp drop_tag?(_content, _ir), do: true

  defp wire_name(nil), do: nil
  defp wire_name(name), do: Atom.to_string(name)

  defp field({key, schema}, definitions, cyclic, path, object_opts) do
    field_path = path ++ [key]
    {presence, inner, default} = presence(schema)
    {from, to} = wire_keys(key, opts(schema), object_opts)

    %IR.Field{
      key: decoded_key(key, object_opts),
      from: from,
      to: to,
      ir: node(inner, definitions, cyclic, field_path),
      presence: presence,
      default: default
    }
  end

  defp presence({:optional, inner, opts}), do: {:optional, inner, default(opts)}

  defp presence(schema) do
    case default(opts(schema)) do
      :none -> {:required, schema, :none}
      found -> {:optional, schema, found}
    end
  end

  defp default(opts) do
    if Keyword.has_key?(opts, :default), do: {:value, Keyword.fetch!(opts, :default)}, else: :none
  end

  defp opts({_kind, opts}) when is_list(opts), do: opts
  defp opts({_kind, _payload, opts}) when is_list(opts), do: opts

  # =============================================
  # Structs
  # =============================================
  #
  # `into:` is a soft dependency on a module, and this is where it is made to pay up: the module
  # has to be loaded and carry a `defstruct` that already has every key the object decodes to.
  # Checking the staged keys rather than the written ones is what makes it worth doing -- these
  # are the names after `rename_all:`, `from:` and `keys:`, which is exactly what `decode/3` will
  # put in the struct. Renaming a field and forgetting to re-run `mix rupa.gen.struct` is then a
  # schema error naming the key, rather than a struct that quietly comes back with a default in
  # it. The path runs through the decoded value, because that is the shape the module describes.
  #
  # `mix rupa.gen.struct` stages with `structs: :skip`, because it is the thing that writes them.

  defp structs!(%{root: root, defs: defs}) do
    into!(root, [])
    Enum.each(defs, fn {name, ir} -> into!(ir, [:defs, name]) end)
  end

  defp into!(%IR.Object{into: nil} = object, path), do: into_children!(object, path)

  defp into!(%IR.Object{into: module} = object, path) do
    keys = struct_keys!(module, path)

    case Enum.reject(Enum.map(object.fields, & &1.key), &MapSet.member?(keys, &1)) do
      [] ->
        into_children!(object, path)

      missing ->
        meta = %{module: module, keys: missing}
        throw({:rupa_stage, Error.new(path, :struct_field_missing, meta)})
    end
  end

  defp into!(%IR.Tagged{branches: branches}, path) do
    Enum.each(branches, fn branch -> into!(branch.ir, path ++ [branch.tag]) end)
  end

  defp into!(%IR.Fixed{members: members}, path), do: indexed!(members, path)
  defp into!(%IR.Union{members: members}, path), do: indexed!(members, path)
  defp into!(%IR.Array{of: inner}, path), do: into!(inner, path ++ [:of])
  defp into!(%IR.Dict{of: inner}, path), do: into!(inner, path ++ [:of])
  defp into!(%IR.Nullable{of: inner}, path), do: into!(inner, path)
  defp into!(_leaf, _path), do: :ok

  defp into_children!(%IR.Object{fields: fields}, path) do
    Enum.each(fields, fn field -> into!(field.ir, path ++ [field.key]) end)
  end

  defp indexed!(nodes, path) do
    nodes
    |> Enum.with_index()
    |> Enum.each(fn {ir, index} -> into!(ir, path ++ [index]) end)
  end

  # `:__struct__` comes out of the set, because it is not a field: a schema naming it would
  # otherwise pass the check and then overwrite the tag the merge just put there, quietly
  # handing back something that is no longer a struct of anything.
  defp struct_keys!(module, path) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) do
      module.__struct__() |> Map.keys() |> MapSet.new() |> MapSet.delete(:__struct__)
    else
      throw({:rupa_stage, Error.new(path, :not_a_struct, %{module: module})})
    end
  end

  # =============================================
  # Defaults
  # =============================================
  #
  # A `default:` is a decoded value that stands in for an absent field, so it has to *be* a value
  # that field could decode to -- otherwise `decode/3` hands back something `encode/3` then
  # refuses, and the round trip the library rests on does not close. The check is to encode the
  # default through the field's own encoder: that is exactly the type-and-format pass encode runs,
  # and no more, so a default is held to being the right shape without being held to the
  # constraints (a `default:` fires on absent and skips constraint checking, the way JSON Schema
  # leaves an unused default unvalidated). `T.integer(default: "x")` and a `date_time` default
  # given as a string are what this catches. Skipped under `structs: :skip` alongside the struct
  # check, because `mix rupa.gen.struct` is what makes the `into:` modules a struct default would
  # need exist in the first place.

  # A default is normalised by decoding through the field's subtree (below), so the subtree's own
  # defaults have to be in their final form first: children before parents, and one whole pass
  # over the program before another, because a default under a recursive definition decodes
  # through the definition table. The pass repeats until nothing changes. On an acyclic
  # dependency between defaults each pass settles at least one more, so `count + 1` passes are
  # enough; a default still moving after that is materialising another level of itself every time
  # it fires -- `%{next: T.ref(:root, default: %{})}` -- and no finite value of it is ever stable,
  # so it is refused rather than looped on.
  defp defaults!(program) do
    settle(program, program, count_defaults(program) + 1)
  end

  defp settle(original, program, passes_left) do
    settled = pass(program)

    cond do
      settled === program -> program
      passes_left > 0 -> settle(original, settled, passes_left - 1)
      true -> throw({:rupa_stage, moved(original, program, settled)})
    end
  end

  defp pass(program) do
    %{
      program
      | root: each_field(program.root, [], program),
        defs:
          Map.new(program.defs, fn {name, ir} ->
            {name, each_field(ir, [:defs, name], program)}
          end)
    }
  end

  defp count_defaults(program) do
    program |> ir_nodes() |> Enum.map(&count_defaults_in/1) |> Enum.sum()
  end

  defp count_defaults_in(node) do
    own =
      case node do
        %IR.Object{fields: fields} -> Enum.count(fields, &(&1.default != :none))
        _other -> 0
      end

    own +
      (node
       |> steps()
       |> Enum.map(fn {_segment, child} -> count_defaults_in(child) end)
       |> Enum.sum())
  end

  # The first field whose default the last pass still changed, at its path, with the default as
  # it was written rather than as it had grown.
  defp moved(original, before, after_pass) do
    trees =
      [{original.root, before.root, after_pass.root, []}] ++
        Enum.map(original.defs, fn {name, ir} ->
          {ir, Map.fetch!(before.defs, name), Map.fetch!(after_pass.defs, name), [:defs, name]}
        end)

    [{path, value} | _rest] =
      Enum.flat_map(trees, fn {o, b, a, path} -> moved_fields(o, b, a, path) end)

    Error.new(path, :recursive_default, %{value: value})
  end

  defp moved_fields(original, before, after_pass, path) do
    own =
      case {original, before, after_pass} do
        {%IR.Object{fields: o}, %IR.Object{fields: b}, %IR.Object{fields: a}} ->
          for {{x, y}, z} <- Enum.zip(Enum.zip(o, b), a),
              y.default !== z.default,
              do: {path ++ [x.key], elem(x.default, 1)}

        _other ->
          []
      end

    below =
      [steps(original), steps(before), steps(after_pass)]
      |> Enum.zip()
      |> Enum.flat_map(fn {{segment, o}, {_s1, b}, {_s2, a}} ->
        moved_fields(o, b, a, path ++ List.wrap(segment))
      end)

    own ++ below
  end

  # A node's children, each with the path segment `each_field/3` gives it (`nil` for none).
  defp steps(%IR.Object{fields: fields}), do: Enum.map(fields, &{&1.key, &1.ir})
  defp steps(%IR.Tagged{branches: branches}), do: Enum.map(branches, &{&1.tag, &1.ir})
  defp steps(%IR.Fixed{members: members}), do: Enum.with_index(members, &{&2, &1})
  defp steps(%IR.Union{members: members}), do: Enum.with_index(members, &{&2, &1})
  defp steps(%IR.Array{of: inner}), do: [{:of, inner}]
  defp steps(%IR.Dict{of: inner}), do: [{:of, inner}]
  defp steps(%IR.Nullable{of: inner}), do: [{nil, inner}]
  defp steps(_leaf), do: []

  defp each_field(%IR.Object{fields: fields} = object, path, program) do
    fields =
      Enum.map(fields, fn field ->
        field_path = path ++ [field.key]
        field = %{field | ir: each_field(field.ir, field_path, program)}
        normalize_default(field, field_path, program)
      end)

    %{object | fields: fields}
  end

  defp each_field(%IR.Tagged{branches: branches} = tagged, path, program) do
    branches =
      Enum.map(branches, fn branch ->
        %{branch | ir: each_field(branch.ir, path ++ [branch.tag], program)}
      end)

    %{tagged | branches: branches}
  end

  defp each_field(%IR.Fixed{members: members} = fixed, path, program),
    do: %{fixed | members: each_indexed(members, path, program)}

  defp each_field(%IR.Union{members: members} = union, path, program),
    do: %{union | members: each_indexed(members, path, program)}

  defp each_field(%IR.Array{of: inner} = array, path, program),
    do: %{array | of: each_field(inner, path ++ [:of], program)}

  defp each_field(%IR.Dict{of: inner} = dict, path, program),
    do: %{dict | of: each_field(inner, path ++ [:of], program)}

  defp each_field(%IR.Nullable{of: inner} = nullable, path, program),
    do: %{nullable | of: each_field(inner, path, program)}

  defp each_field(leaf, _path, _program), do: leaf

  defp each_indexed(nodes, path, program) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {ir, index} -> each_field(ir, path ++ [index], program) end)
  end

  # A default is materialised onto an absent field with no per-decode check, so it has to be a
  # value the field would actually accept AND already be in its own decoded form -- otherwise a
  # decode materialises the field to something a round trip then changes (a nested default fires, a
  # stripped key vanishes). So the default is put through the field once, wire and back, and the
  # value that comes out is stored in its place: valid by construction, and a fixpoint. The trip
  # runs against a name-symmetric copy of the field (`from`/`to` neutralised), because a migration
  # field is deliberately not its own inverse and its output must not be read through its input.
  # A default the field cannot encode-and-decode is still `:invalid_default`, with its path.
  defp normalize_default(%IR.Field{default: {:value, value}, ir: ir} = field, path, %{defs: defs}) do
    program = IR.Rewrite.symmetric_program(%{root: ir, defs: defs})
    {encode, encode_defs} = Closure.build_encoder(program)
    {decode, decode_defs} = Closure.build(program)

    with {:ok, wire} <- encode.(value, {:halt, encode_defs}),
         {:ok, decoded} <- decode.(wire, {:halt, decode_defs}) do
      %{field | default: {:value, decoded}}
    else
      {:error, _errors} ->
        throw({:rupa_stage, Error.new(path, :invalid_default, %{value: value})})
    end
  end

  defp normalize_default(field, _path, _program), do: field

  # =============================================
  # Nested untagged unions
  # =============================================
  #
  # An untagged union costs one decode attempt per variant. A union inside a union multiplies
  # them, so depth is exponential -- the one shape in the vocabulary that can be slow by
  # accident. `IO.warn/1` rather than a log line: Rupa has nothing to start and never logs, and
  # this is what the compiler itself uses to say "this is valid, and you may not have meant it".

  defp warn_nested_unions(program) do
    reaching = reaching_unions(program.defs)

    if Enum.any?(ir_nodes(program), &nests_union?(&1, reaching)) do
      IO.warn("""
      this schema nests untagged unions, so decoding costs one attempt per variant per level \
      and doubles with depth. Rupa.T.tagged/3 stays flat at any depth; if you meant the \
      untagged one, nothing here is wrong.\
      """)
    end
  end

  defp ir_nodes(%{root: root, defs: defs}), do: [root | Map.values(defs)]

  defp nests_union?(%IR.Union{members: members}, reaching) do
    Enum.any?(members, &holds_union?(&1, reaching))
  end

  defp nests_union?(node, reaching) do
    Enum.any?(ir_children(node), &nests_union?(&1, reaching))
  end

  defp holds_union?(%IR.Union{}, _reaching), do: true
  defp holds_union?(%IR.Ref{name: name}, reaching), do: MapSet.member?(reaching, name)

  defp holds_union?(node, reaching) do
    Enum.any?(ir_children(node), &holds_union?(&1, reaching))
  end

  # Which definitions can reach a union, refs and all. Least fixpoint, the same shape
  # `Rupa.Gen` uses for termination: start knowing nothing and keep adding names whose subtree
  # bottoms out in something already known, until a pass adds nothing.
  defp reaching_unions(defs), do: grow_unions(defs, MapSet.new())

  defp grow_unions(defs, seen) do
    grown = for {name, ir} <- defs, holds_union?(ir, seen), into: MapSet.new(), do: name

    if MapSet.size(grown) == MapSet.size(seen), do: grown, else: grow_unions(defs, grown)
  end

  # No `%IR.Union{}` clause: both callers above match a union before they ever get here, which
  # is what makes "a union that holds a union" the thing being asked rather than a walk that
  # has to remember where it has been.
  defp ir_children(%IR.Object{fields: fields}), do: Enum.map(fields, & &1.ir)
  defp ir_children(%IR.Tagged{branches: branches}), do: Enum.map(branches, & &1.ir)
  defp ir_children(%IR.Fixed{members: members}), do: members
  defp ir_children(%IR.Array{of: inner}), do: [inner]
  defp ir_children(%IR.Dict{of: inner}), do: [inner]
  defp ir_children(%IR.Nullable{of: inner}), do: [inner]
  defp ir_children(_leaf), do: []

  # =============================================
  # Names
  # =============================================
  #
  # The three names a field carries are decided here and never looked at again: `from` is the
  # key decode reads, `to` is the key encode writes, and `key` is what the decoded map holds.
  # `keys: :string` changes that last one's type and not its name, which is what keeps it
  # orthogonal to renaming -- and what makes encode able to read back what it wrote.

  # One of `from:` and `to:` names the field's wire key in both directions, so a field renamed
  # once still round-trips. Both of them, naming different keys, is the one way to make encode
  # stop being decode's inverse -- which is what you want when you are reading an old name and
  # writing a new one, and is not something to arrive at by giving a single option.
  defp wire_keys(key, opts, object_opts) do
    renamed = rename(spelled(key), Keyword.get(object_opts, :rename_all))

    case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
      {nil, nil} -> {renamed, renamed}
      {from, nil} -> {from, from}
      {nil, to} -> {to, to}
      {from, to} -> {from, to}
    end
  end

  defp spelled(key) when is_atom(key), do: Atom.to_string(key)
  defp spelled(key), do: key

  # The decoded key's type follows the name you wrote, so neither default interns anything: an
  # atom-named object decodes to atom keys, a string-named one to string keys. A string-named
  # object is what `Rupa.JsonSchema.decode/1` produces from a document whose field names you did
  # not choose, and `keys: :atom` is then the single explicit place one of those names becomes
  # an atom. That is a name in a schema, not a key off a document -- the same rule the branch
  # name below already follows, and the second and last `String.to_atom/1` in the repo.
  defp decoded_key(key, object_opts) when is_atom(key) do
    case Keyword.get(object_opts, :keys, :atom) do
      :atom -> key
      :string -> Atom.to_string(key)
    end
  end

  defp decoded_key(key, object_opts) do
    case Keyword.get(object_opts, :keys, :string) do
      :string -> key
      :atom -> String.to_atom(key)
    end
  end

  # `rename_all:` reads the field name as words and writes them back in the style asked for, so
  # it works on a name written in any of the three rather than only on snake_case. A run of
  # capitals is one word -- `user_id` and `userID` both read as `["user", "id"]` -- which keeps
  # `:camelCase` and `:snake_case` inverses on the names people actually write.
  defp rename(name, nil), do: name

  defp rename(name, style) do
    case words(name) do
      [] -> name
      [first | rest] -> join(style, first, rest)
    end
  end

  defp join(:snake_case, first, rest), do: Enum.join([first | rest], "_")
  defp join(:kebab, first, rest), do: Enum.join([first | rest], "-")

  defp join(:camelCase, first, rest) do
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end

  defp words(name) do
    name
    |> String.replace(~r/(\p{Lu}+)(\p{Lu}\p{Ll})/u, "\\1 \\2")
    |> String.replace(~r/([\p{Ll}\d])(\p{Lu})/u, "\\1 \\2")
    |> String.split(["_", "-", " "], trim: true)
    |> Enum.map(&String.downcase/1)
  end

  # Two fields reading one wire key, or writing one, is a schema the wire cannot express: one
  # of them would quietly win. A rename collision is easy to write by accident, so it stops the
  # pass rather than turning up as a missing field much later.
  defp collisions!(fields, path) do
    Enum.each([:from, :to], fn direction ->
      keys = Enum.map(fields, &Map.fetch!(&1, direction))

      case keys -- Enum.uniq(keys) do
        [] -> :ok
        [key | _rest] -> throw({:rupa_stage, Error.new(path, :duplicate_wire_key, %{key: key})})
      end
    end)
  end

  defp const(values, path) do
    pairs = Enum.map(values, fn value -> {wire(value), value} end)
    lookup = Map.new(pairs)

    if map_size(lookup) != length(pairs) do
      throw({:rupa_stage, Error.new(path, :ambiguous_const, %{values: values})})
    end

    %IR.Const{lookup: lookup, reverse: Map.new(pairs, fn {w, v} -> {v, w} end), values: values}
  end

  defp wire(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp wire(value), do: value

  defp checks(:string, opts), do: take(opts, @string_checks)
  defp checks(kind, opts) when kind in [:integer, :float], do: take(opts, @number_checks)
  defp checks(_kind, _opts), do: []

  defp take(opts, keys) do
    for key <- keys, Keyword.has_key?(opts, key), do: {key, Keyword.fetch!(opts, key)}
  end
end

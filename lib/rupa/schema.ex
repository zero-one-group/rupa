defmodule Rupa.Schema do
  @moduledoc """
  The schema term: what it is, how to check one, and how to rewrite one.

  A schema is a tuple, `{kind, opts}` or `{kind, payload, opts}`, built by `Rupa.T`. Nothing
  in it is a function, so a schema prints, compares, hashes with `:erlang.phash2/1`, and
  embeds in generated code as a literal. `validate/1` is the only thing that judges a schema;
  the constructors themselves hand back whatever you gave them.

  ## Present, absent, null

  Three states, kept apart on purpose.

    * A field is **required** unless its term is wrapped in `Rupa.T.optional/2` or carries
      `default:`. A required key must be present and must not be `null`.
    * `Rupa.T.optional/2` says the **key may be absent**. Absent decodes to the key simply not
      being in the map — not to `nil`.
    * `Rupa.T.nullable/2` says the **value may be JSON null**, which decodes to `nil`. It says
      nothing about the key being absent.
    * `default:` fires on absent only. An explicit `null` is never replaced by a default; it is
      either allowed, by `nullable`, or an error.

  So `T.optional(T.nullable(T.string()))` is the field that may be missing, may be null, and is
  otherwise a string — and decoding tells you which of the three you got.

  ## Field names

  A field's name is an atom or a string, and an object's names are all of one or all of the
  other — mixing them is `:mixed_field_names`, because it would make the decoded map's shape
  depend on which field you were looking at.

  Write atoms when you know the fields as you write the code, which is most of the time. Strings
  are for an object whose field names you did not choose — one that came out of
  `Rupa.JsonSchema.decode/1`, say — and they are what makes that path total: nothing is interned
  from a document that arrived over the wire.

  ## Names on the wire

  A field's wire key is a string, and by default it is the name spelled out. Four options move
  that apart, all of them settled at compile time.

    * `rename_all:` is an **object** option — `:camelCase`, `:snake_case` or `:kebab`. It reads
      each field name as words and writes them back in that style, both directions, so
      `%{first_name: ...}` with `rename_all: :camelCase` reads and writes `"firstName"`. It
      applies to that object and not to the objects inside it; `walk/2` is how you apply one to
      a whole tree.
    * `from:` and `to:` override it for one field: `from:` is the key the value arrives under,
      `to:` the key it leaves under. Give one and the other follows it, so a field renamed by
      hand still round-trips; give both, naming different keys, and you have said that this
      field reads an old name and writes a new one — the one way to make `Rupa.encode/3` stop
      being `Rupa.decode/3`'s inverse, which is exactly what a migration wants. Like `default:`,
      they belong on the field's own term — the node in the object's field map,
      `Rupa.T.optional/2` included — and anywhere else is `:misplaced_rename`.
    * `keys:` is the **object** option for the other side: `:atom` or `:string`, deciding the
      type of the key the decoded map holds. It changes the key's type, never its name, so it
      stays out of the wire's way — and encoding reads back whichever it wrote. It defaults to
      the type of the name you wrote, so an atom-named object decodes to atom keys and a
      string-named one to string keys, and neither default interns anything.

  Renaming never interns an atom from wire data: the atoms are the field names, and they exist
  before any data does. `keys: :atom` on a string-named object is the one place a name becomes
  an atom, and it is a name in a schema rather than a key off a document — the same rule every
  other atom in a schema already follows. Two fields that land on one wire key are refused at
  compile time rather than one of them quietly winning.

  ## Structs

  `into:` on an object names a struct module to decode into. It is an option on the object, not
  on the compile, so nesting works: an address three levels down becomes a `MyApp.Address` the
  same way the root becomes a `MyApp.User`. A module name is an atom, so the schema still
  prints, hashes and embeds as a literal; what it adds is a soft dependency on that module,
  which `Rupa.compile/2` checks — the module must be loaded and must already have every key the
  object decodes to, or you get a schema error rather than a surprise at decode time.
  `mix rupa.gen.struct` writes those modules from the schema.

  A struct has atom keys and every one of them always, which rules three things out. `keys:`
  must resolve to `:atom`, so `keys: :string` is refused and a string-named object needs the
  explicit `keys: :atom` that interning already makes you ask for. `unknown: :keep` is refused,
  because a struct has nowhere to put the keys it would carry. And `Rupa.T.optional/2` keeps
  working but stops meaning three things: the key is always there, so what decoding leaves
  behind for an absent field is that field's `defstruct` default, and encoding writes that same
  value back as absent — which is what keeps the round trip closing. For a struct
  `mix rupa.gen.struct` wrote, that value is `nil`, so an absent key and an explicit null reach
  the same struct and both leave as absent. A struct you wrote yourself may default the field to
  something else, and then that something else is what stands for absent, and `nil` is a value
  like any other.

  ## Paths

  Errors from `validate/1` carry a path through the schema:

    * an atom is an object field, or a `defs:` entry after the `:defs` segment
    * `:of` is a list's element type or a `map_of`'s value type
    * an integer is a position in a tuple or a variant of a union
    * a string is a branch of a tagged union, or a field of a string-named object
  """

  alias Rupa.Error

  @scalars [:string, :integer, :float, :boolean, :null]
  @inner [:list, :map_of, :optional, :nullable]
  @members [:tuple, :union]

  @formats [
    :date_time,
    :date,
    :time,
    :duration,
    :uuid,
    :email,
    :uri,
    :ipv4,
    :ipv6,
    :hostname
  ]

  @common_opts [:default, :from, :to]
  @kind_opts %{
    string: [:min, :max, :len, :pattern, :format],
    integer: [:gte, :gt, :lte, :lt, :multiple_of],
    float: [:gte, :gt, :lte, :lt, :multiple_of],
    boolean: [],
    null: [],
    literal: [],
    enum: [],
    ref: [],
    object: [:rename_all, :unknown, :keys, :into, :defs],
    list: [:min, :max, :unique],
    map_of: [],
    tuple: [],
    optional: [],
    nullable: [],
    union: [:tag],
    tagged: [:tag, :content]
  }

  @renames [:camelCase, :snake_case, :kebab]
  @unknowns [:strip, :error, :keep]
  @key_modes [:atom, :string]

  @type name :: atom()
  @type opts :: keyword()

  @type t ::
          {:string | :integer | :float | :boolean | :null, opts()}
          | {:literal, term(), opts()}
          | {:enum, [term()], opts()}
          | {:ref, name(), opts()}
          | {:object, %{(atom() | String.t()) => t()}, opts()}
          | {:list | :map_of | :optional | :nullable, t(), opts()}
          | {:tuple | :union, [t()], opts()}
          | {:tagged, %{String.t() => t()}, opts()}

  @doc """
  The built-in formats, in the order they are documented.

      iex> :uuid in Rupa.Schema.formats()
      true
  """
  @spec formats() :: [atom()]
  def formats, do: @formats

  @doc """
  Puts a schema in canonical form: bare maps become objects, and options are sorted by key.

  `Rupa.T` does this as it builds, so a term you did not hand-write is already canonical. Two
  schemas that mean the same thing are then the same term, which is what makes
  `:erlang.phash2/1` a usable identity for a compiled codec.

      iex> Rupa.Schema.normalize(%{name: {:string, []}})
      {:object, %{name: {:string, []}}, []}

      iex> Rupa.Schema.normalize({:string, [min: 1, len: 2]})
      {:string, [len: 2, min: 1]}
  """
  @spec normalize(term()) :: term()
  def normalize(schema)

  def normalize(fields) when is_map(fields) and not is_struct(fields) do
    {:object, normalize_fields(fields), []}
  end

  def normalize({kind, opts}) when kind in @scalars and is_list(opts) do
    {kind, normalize_opts(opts)}
  end

  def normalize({kind, payload, opts}) when kind in [:literal, :ref] and is_list(opts) do
    {kind, payload, normalize_opts(opts)}
  end

  def normalize({:enum, values, opts}) when is_list(values) and is_list(opts) do
    {:enum, values, normalize_opts(opts)}
  end

  def normalize({:object, fields, opts}) when is_map(fields) and is_list(opts) do
    {:object, normalize_fields(fields), normalize_opts(opts)}
  end

  def normalize({kind, inner, opts}) when kind in @inner and is_list(opts) do
    {kind, normalize(inner), normalize_opts(opts)}
  end

  def normalize({kind, members, opts})
      when kind in @members and is_list(members) and is_list(opts) do
    {kind, Enum.map(members, &normalize/1), normalize_opts(opts)}
  end

  def normalize({:tagged, branches, opts}) when is_map(branches) and is_list(opts) do
    {:tagged, normalize_fields(branches), normalize_opts(opts)}
  end

  def normalize(other), do: other

  defp normalize_fields(fields) do
    Map.new(fields, fn {key, value} -> {key, normalize(value)} end)
  end

  defp normalize_opts(opts) do
    opts
    |> Enum.map(fn
      {:defs, defs} when is_map(defs) -> {:defs, normalize_fields(defs)}
      entry -> entry
    end)
    |> Enum.sort_by(&opt_key/1)
  end

  defp opt_key({key, _value}), do: key
  defp opt_key(entry), do: entry

  @doc """
  Rewrites every node of a schema, children first.

  The function is handed each node after its children have been rewritten, and whatever it
  returns takes that node's place. Nodes inside `defs:` are rewritten too.

  The schema is normalised first, so the function always sees canonical `{kind, ...}` nodes: a
  bare map arrives as `{:object, fields, opts}` -- and is descended into -- rather than as the
  leaf it would otherwise look like. That is what lets one `{:object, _, _}` clause restyle every
  object in a tree written the idiomatic bare-map way.

      iex> schema = %{age: {:integer, []}}
      iex> Rupa.Schema.walk(schema, fn
      ...>   {:integer, opts} -> {:integer, [{:gte, 0} | opts]}
      ...>   node -> node
      ...> end)
      {:object, %{age: {:integer, [gte: 0]}}, []}
  """
  @spec walk(t(), (t() -> t())) :: t()
  def walk(schema, fun) when is_function(fun, 1) do
    schema |> normalize() |> rewrite(fun)
  end

  defp rewrite(schema, fun), do: schema |> walk_children(fun) |> fun.()

  defp walk_children({:object, fields, opts}, fun) do
    {:object, Map.new(fields, fn {k, v} -> {k, rewrite(v, fun)} end), walk_defs(opts, fun)}
  end

  defp walk_children({:tagged, branches, opts}, fun) do
    {:tagged, Map.new(branches, fn {k, v} -> {k, rewrite(v, fun)} end), walk_defs(opts, fun)}
  end

  defp walk_children({kind, inner, opts}, fun) when kind in @inner do
    {kind, rewrite(inner, fun), walk_defs(opts, fun)}
  end

  defp walk_children({kind, members, opts}, fun) when kind in @members do
    {kind, Enum.map(members, &rewrite(&1, fun)), walk_defs(opts, fun)}
  end

  defp walk_children({kind, payload, opts}, fun) when is_list(opts) do
    {kind, payload, walk_defs(opts, fun)}
  end

  defp walk_children({kind, opts}, fun) when is_list(opts) do
    {kind, walk_defs(opts, fun)}
  end

  defp walk_children(leaf, _fun), do: leaf

  defp walk_defs(opts, fun) when is_list(opts) do
    Enum.map(opts, fn
      {:defs, defs} when is_map(defs) ->
        {:defs, Map.new(defs, fn {k, v} -> {k, rewrite(v, fun)} end)}

      entry ->
        entry
    end)
  end

  defp walk_defs(opts, _fun), do: opts

  @doc """
  Checks that a term is a well-formed schema, and returns it in canonical form.

  This is structure only: that every node is a kind Rupa knows, that its options are ones that
  kind takes and hold values of the right shape, that no branch of the tree holds a function,
  and that every `Rupa.T.ref/2` resolves. It says nothing about whether any data would decode.

  Every problem is reported, not just the first.

      iex> Rupa.Schema.validate(%{name: {:string, [min: 1]}})
      {:ok, {:object, %{name: {:string, [min: 1]}}, []}}

      iex> {:error, [error]} = Rupa.Schema.validate({:string, [format: :ssn]})
      iex> {error.path, error.code}
      {[], :unknown_format}
  """
  @spec validate(term()) :: {:ok, t()} | {:error, [Error.t()]}
  def validate(schema) do
    schema = normalize(schema)
    {defs, duplicates} = collect_defs(schema)
    context = %{defs: defs, at: :other}

    case duplicates ++ check(schema, [], context) do
      [] -> {:ok, schema}
      errors -> {:error, Enum.sort_by(errors, &{&1.path, &1.code})}
    end
  end

  @doc """
  `validate/1`, raising `Rupa.SchemaError` instead of returning errors.

      iex> Rupa.Schema.validate!({:boolean, []})
      {:boolean, []}
  """
  @spec validate!(term()) :: t()
  def validate!(schema) do
    case validate(schema) do
      {:ok, schema} -> schema
      {:error, errors} -> raise Rupa.SchemaError, errors: errors
    end
  end

  # =============================================
  # Defs
  # =============================================

  defp collect_defs(schema) do
    {seen, errors} = reduce_nodes(schema, {%{}, []}, &merge_defs/2)
    {MapSet.new(Map.keys(seen)), Enum.reverse(errors)}
  end

  defp reduce_nodes(node, acc, fun) do
    Enum.reduce(child_nodes(node), fun.(node, acc), &reduce_nodes(&1, &2, fun))
  end

  # The payload guards keep the walk from crashing on a malformed node -- `Map.values/1` on a
  # non-map, `++` on a non-list. A shape that fails one falls through to the 3-tuple catch-all,
  # collects no children, and `check_node/3` reports it as `:unknown_type` a moment later.
  defp child_nodes({:object, fields, opts}) when is_map(fields) do
    Map.values(fields) ++ def_nodes(opts)
  end

  defp child_nodes({:tagged, branches, opts}) when is_map(branches) do
    Map.values(branches) ++ def_nodes(opts)
  end

  defp child_nodes({kind, inner, opts}) when kind in @inner, do: [inner | def_nodes(opts)]

  defp child_nodes({kind, members, opts}) when kind in @members and is_list(members) do
    members ++ def_nodes(opts)
  end

  defp child_nodes({_kind, _payload, opts}), do: def_nodes(opts)
  defp child_nodes({_kind, opts}), do: def_nodes(opts)
  defp child_nodes(_leaf), do: []

  defp def_nodes(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {:defs, defs} when is_map(defs) -> Map.values(defs)
      _entry -> []
    end)
  end

  defp def_nodes(_opts), do: []

  defp merge_defs({_kind, _payload, opts}, acc) when is_list(opts), do: put_defs(opts, acc)
  defp merge_defs({_kind, opts}, acc) when is_list(opts), do: put_defs(opts, acc)
  defp merge_defs(_node, acc), do: acc

  defp put_defs(opts, acc) do
    Enum.reduce(opts, acc, fn
      {:defs, defs}, inner when is_map(defs) -> Enum.reduce(defs, inner, &put_def/2)
      _entry, inner -> inner
    end)
  end

  defp put_def({name, schema}, {seen, errors}) do
    case Map.fetch(seen, name) do
      :error -> {Map.put(seen, name, schema), errors}
      {:ok, ^schema} -> {seen, errors}
      {:ok, _other} -> {seen, [Error.new([:defs, name], :duplicate_def, %{name: name}) | errors]}
    end
  end

  # =============================================
  # Structure
  # =============================================

  defp check(schema, path, context) do
    field_only(schema, path, context) ++ check_node(schema, path, context)
  end

  # `from:` and `to:` name the wire key a field arrives under and the one it leaves under, and
  # `default:` fires when a field is absent -- so all three belong on the field's own term and
  # say nothing anywhere else. Anywhere else they are refused rather than quietly ignored: a
  # `default:` on a list element, a root or a tagged branch can never fire, and a schema that
  # looks like it has one is worse than one that says it cannot. The context's `at:` says where
  # the term sits: `:field` (a field's own term), `:wrapped` (directly inside an optional or
  # nullable, where `check_wrapper/5` reports a stray `default:` as the more pointed
  # `:nested_default`), or `:other`.
  defp field_only({_kind, opts}, path, context) when is_list(opts) do
    placed_on_field(opts, path, context)
  end

  defp field_only({_kind, _payload, opts}, path, context) when is_list(opts) do
    placed_on_field(opts, path, context)
  end

  defp field_only(_leaf, _path, _context), do: []

  defp placed_on_field(_opts, _path, %{at: :field}), do: []

  defp placed_on_field(opts, path, %{at: at}) do
    given = for {key, _value} <- opts, do: key

    renames =
      for key <- [:from, :to],
          key in given,
          do: Error.new(path, :misplaced_rename, %{option: key})

    defaults =
      if at == :other and :default in given,
        do: [Error.new(path, :misplaced_default, %{})],
        else: []

    renames ++ defaults
  end

  defp check_node({kind, opts}, path, _context) when kind in @scalars and is_list(opts) do
    check_opts(kind, opts, path)
  end

  defp check_node({:literal, value, opts}, path, _context) when is_list(opts) do
    check_opts(:literal, opts, path) ++ check_scalar(value, path)
  end

  defp check_node({:enum, values, opts}, path, _context) when is_list(values) and is_list(opts) do
    check_opts(:enum, opts, path) ++ check_enum(values, path)
  end

  defp check_node({:ref, name, opts}, path, context) when is_list(opts) do
    check_opts(:ref, opts, path) ++ check_ref(name, path, context)
  end

  defp check_node({:object, fields, opts}, path, context) when is_map(fields) and is_list(opts) do
    check_opts(:object, opts, path) ++
      check_names(fields, path) ++
      check_struct_key(fields, opts, path) ++
      check_into(fields, opts, path) ++
      Enum.flat_map(fields, &check_field(&1, path, context)) ++ check_defs(opts, path, context)
  end

  defp check_node({kind, inner, opts}, path, context)
       when kind in [:list, :map_of] and is_list(opts) do
    check_opts(kind, opts, path) ++ check(inner, path ++ [:of], %{context | at: :other})
  end

  defp check_node({kind, inner, opts}, path, context) when kind in [:optional, :nullable] do
    check_wrapper(kind, inner, opts, path, context)
  end

  defp check_node({:tuple, members, opts}, path, context)
       when is_list(members) and is_list(opts) do
    check_opts(:tuple, opts, path) ++ check_members(members, path, context)
  end

  defp check_node({:union, members, opts}, path, context)
       when is_list(members) and is_list(opts) do
    check_opts(:union, opts, path) ++
      check_union(members, path) ++
      check_members(members, path, context)
  end

  defp check_node({:tagged, branches, opts}, path, context)
       when is_map(branches) and is_list(opts) do
    check_opts(:tagged, opts, path) ++ check_branches(branches, opts, path, context)
  end

  defp check_node(other, path, _context) do
    [Error.new(path, :unknown_type, %{value: other})]
  end

  # An object's names are all atoms or all strings. Mixing them would leave `keys:` with nothing
  # coherent to default to, and the decoded map's shape depending on which field you looked at.
  defp check_names(fields, path) do
    keys = Map.keys(fields)

    mixed =
      if Enum.any?(keys, &is_atom/1) and Enum.any?(keys, &is_binary/1),
        do: [Error.new(path, :mixed_field_names, %{})],
        else: []

    mixed ++ Enum.flat_map(keys, &utf8(&1, path))
  end

  # Every string a schema carries into the wire -- a field name, a `from:`/`to:`, a literal or
  # enum value, a tagged branch's name -- is rendered to JSON, or interned as an atom, while the
  # schema is staged. A binary that is not UTF-8 would raise out of that rendering, in the middle
  # of `Rupa.compile/2`, for a caller who may never ask for JSON at all; so it is refused here,
  # with its path, under the same code the JSON boundary uses for a value at run time. A `default:`
  # is not a static fragment -- it is a value of the field's type, checked when it is encoded.
  defp utf8(value, path) when is_binary(value) do
    if String.valid?(value), do: [], else: [Error.new(path, :invalid_utf8, %{value: value})]
  end

  defp utf8(_other, _path), do: []

  # A decoded map with a `:__struct__` key passes for a struct everywhere Elixir looks, and would
  # crash the first `inspect/1` that believed it. The one name that could put it there is refused:
  # as an atom field name, or as a string one under `keys: :atom`. As a string key it is only a
  # string, and a document is entitled to it.
  defp check_struct_key(fields, opts, path) do
    interned? = Map.has_key?(fields, "__struct__") and Keyword.get(opts, :keys) == :atom

    if Map.has_key?(fields, :__struct__) or interned?,
      do: [Error.new(path, :reserved_field_name, %{field: :__struct__})],
      else: []
  end

  # A struct has atom keys and every one of them, always, so two of the object's own options
  # cannot hold beside `into:`. Both are checked against what the object actually resolves to
  # rather than against what was written: a string-named object defaults `keys:` to `:string`,
  # which is the same collision spelled by leaving an option out.
  defp check_into(fields, opts, path) do
    case Keyword.get(opts, :into) do
      nil -> []
      module when is_atom(module) and not is_boolean(module) -> into_opts(fields, opts, path)
      _invalid -> []
    end
  end

  defp into_opts(fields, opts, path) do
    names = if Enum.any?(Map.keys(fields), &is_binary/1), do: :string, else: :atom

    struct_keys(Keyword.get(opts, :keys, names), names, path) ++
      struct_unknown(Keyword.get(opts, :unknown, :strip), path)
  end

  defp struct_keys(:atom, _names, _path), do: []
  defp struct_keys(:string, names, path), do: [Error.new(path, :struct_keys, %{names: names})]
  defp struct_keys(_invalid, _names, _path), do: []

  defp struct_unknown(:keep, path), do: [Error.new(path, :struct_keeps_unknown, %{})]
  defp struct_unknown(_policy, _path), do: []

  defp check_field({key, schema}, path, context) when is_atom(key) or is_binary(key) do
    check(schema, path ++ [key], %{context | at: :field})
  end

  defp check_field({key, schema}, path, context) do
    [Error.new(path, :invalid_field_name, %{field: key})] ++
      check(schema, path ++ [key], %{context | at: :field})
  end

  defp check_members(members, path, context) do
    members
    |> Enum.with_index()
    |> Enum.flat_map(fn {member, index} ->
      check(member, path ++ [index], %{context | at: :other})
    end)
  end

  defp check_union(members, path) when length(members) < 2 do
    [Error.new(path, :union_too_small, %{})]
  end

  defp check_union(_members, _path), do: []

  defp check_wrapper(kind, inner, opts, path, context) when is_list(opts) do
    misplaced(kind, path, context) ++
      check_opts(kind, opts, path) ++
      nested(kind, inner, path) ++
      check(inner, path, %{context | at: :wrapped})
  end

  defp check_wrapper(_kind, _inner, opts, path, _context) do
    [Error.new(path, :unknown_type, %{value: opts})]
  end

  defp misplaced(:optional, path, %{at: at}) when at != :field,
    do: [Error.new(path, :misplaced_optional, %{})]

  defp misplaced(_kind, _path, _context), do: []

  # Nullable of nullable says nothing twice; nullable of null says nothing at all, and the module
  # backend's type checker would rightly report the null clause it leaves unreachable.
  defp nested(:nullable, {:nullable, _inner, _opts}, path) do
    [Error.new(path, :nested_nullable, %{})]
  end

  defp nested(:nullable, {:null, _opts}, path) do
    [Error.new(path, :nested_nullable, %{})]
  end

  defp nested(_kind, inner, path), do: nested_default(inner, path)

  defp nested_default({_kind, opts}, path) when is_list(opts), do: default_error(opts, path)

  defp nested_default({_kind, _payload, opts}, path) when is_list(opts),
    do: default_error(opts, path)

  defp nested_default(_inner, _path), do: []

  defp default_error(opts, path) do
    if Enum.any?(opts, &match?({:default, _}, &1)) do
      [Error.new(path, :nested_default, %{})]
    else
      []
    end
  end

  defp check_defs(opts, path, context) do
    opts
    |> Enum.flat_map(fn
      {:defs, defs} when is_map(defs) -> Map.to_list(defs)
      _entry -> []
    end)
    |> Enum.flat_map(fn {name, schema} ->
      check(schema, path ++ [:defs, name], %{context | at: :other})
    end)
  end

  defp check_ref(name, path, %{defs: defs}) do
    if name == :root or (is_atom(name) and MapSet.member?(defs, name)) do
      []
    else
      [Error.new(path, :unresolved_ref, %{name: name})]
    end
  end

  defp check_branches(branches, _opts, path, _context) when map_size(branches) == 0 do
    [Error.new(path, :empty_branches, %{})]
  end

  defp check_branches(branches, opts, path, context) do
    adjacent? = Enum.any?(opts, &match?({:content, _}, &1))

    Enum.flat_map(branches, fn {tag, schema} ->
      branch_name(tag, path) ++
        branch_shape(adjacent?, schema, path ++ [tag]) ++
        check(schema, path ++ [tag], %{context | at: :other})
    end)
  end

  defp branch_name(tag, path) when is_binary(tag), do: utf8(tag, path)
  defp branch_name(tag, path), do: [Error.new(path, :invalid_branch_name, %{value: tag})]

  defp branch_shape(false, {:object, _fields, _opts}, _path), do: []
  defp branch_shape(false, _schema, path), do: [Error.new(path, :untagged_branch, %{})]
  defp branch_shape(true, _schema, _path), do: []

  defp check_enum([], path), do: [Error.new(path, :empty_enum, %{})]

  defp check_enum(values, path) do
    Enum.flat_map(values, &check_scalar(&1, path)) ++ duplicates(values, path)
  end

  defp duplicates(values, path) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} ->
      Error.new(path, :duplicate_enum_value, %{value: value})
    end)
  end

  defp check_scalar(value, path) when is_binary(value), do: utf8(value, path)
  defp check_scalar(value, _path) when is_number(value), do: []
  defp check_scalar(value, _path) when is_boolean(value), do: []
  defp check_scalar(nil, path), do: [Error.new(path, :invalid_scalar, %{value: nil})]
  defp check_scalar(value, _path) when is_atom(value), do: []
  defp check_scalar(value, path), do: [Error.new(path, :invalid_scalar, %{value: value})]

  # =============================================
  # Options
  # =============================================

  defp check_opts(kind, opts, path) do
    allowed = Map.fetch!(@kind_opts, kind) ++ @common_opts
    {pairs, strays} = Enum.split_with(opts, &match?({_key, _value}, &1))

    Enum.map(strays, &Error.new(path, :unknown_option, %{option: &1, kind: kind})) ++
      unknown_opts(pairs, allowed, kind, path) ++
      duplicate_opts(pairs, path) ++
      Enum.flat_map(pairs, &check_opt(&1, allowed, path)) ++
      cross_opts(kind, pairs, path)
  end

  defp unknown_opts(pairs, allowed, kind, path) do
    for {key, _value} <- pairs,
        key not in allowed,
        do: Error.new(path, :unknown_option, %{option: key, kind: kind})
  end

  defp duplicate_opts(pairs, path) do
    pairs
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> Error.new(path, :duplicate_option, %{option: key}) end)
  end

  defp check_opt({key, value}, allowed, path) do
    cond do
      key not in allowed -> []
      key != :defs and function?(value) -> [Error.new(path, :function_in_schema, %{option: key})]
      true -> opt_value(key, value, path)
    end
  end

  defp opt_value(key, value, path) when key in [:min, :max, :len] do
    expect(is_integer(value) and value >= 0, key, value, "a non-negative integer", path)
  end

  defp opt_value(key, value, path) when key in [:gte, :gt, :lte, :lt] do
    expect(is_number(value), key, value, "a number", path)
  end

  defp opt_value(:multiple_of, value, path) do
    expect(is_number(value) and value > 0, :multiple_of, value, "a positive number", path)
  end

  defp opt_value(:unique, value, path) do
    expect(is_boolean(value), :unique, value, "a boolean", path)
  end

  defp opt_value(key, value, path) when key in [:from, :to] do
    expect(is_binary(value), key, value, "a string", path) ++ utf8(value, path)
  end

  defp opt_value(:rename_all, value, path) do
    expect(value in @renames, :rename_all, value, one_of(@renames), path)
  end

  defp opt_value(:unknown, value, path) do
    expect(value in @unknowns, :unknown, value, one_of(@unknowns), path)
  end

  defp opt_value(:keys, value, path) do
    expect(value in @key_modes, :keys, value, one_of(@key_modes), path)
  end

  # A module name is an atom, which is all a schema term needs it to be: it still prints, hashes
  # and embeds as a literal. Whether that module exists and has the right fields is a question
  # for staging, which knows the decoded keys by then.
  defp opt_value(:into, value, path) do
    expect(
      is_atom(value) and not is_nil(value) and not is_boolean(value),
      :into,
      value,
      "a module",
      path
    )
  end

  defp opt_value(:content, value, path) do
    expect(is_atom(value) and not is_nil(value), :content, value, "an atom", path)
  end

  defp opt_value(:format, value, path) do
    if value in @formats do
      []
    else
      [Error.new(path, :unknown_format, %{format: value})]
    end
  end

  defp opt_value(:pattern, value, path) when is_binary(value) do
    case Regex.compile(value) do
      {:ok, _regex} ->
        []

      {:error, {reason, at}} ->
        [Error.new(path, :invalid_pattern, %{reason: "#{reason} at #{at}"})]
    end
  end

  defp opt_value(:pattern, value, path) do
    expect(false, :pattern, value, "a string holding a regular expression", path)
  end

  # `:root` is the name the schema itself answers to (`T.ref(:root)` is `"#"`), so a `defs:` entry
  # under it could only ever be shadowed -- a ref would reach the root, never the definition --
  # and that is refused rather than left to surprise.
  defp opt_value(:defs, value, path) when is_map(value) do
    for {name, _schema} <- value,
        not is_atom(name) or name == :root,
        do: Error.new(path, def_name_code(name), %{name: name})
  end

  defp opt_value(:defs, value, path) do
    expect(false, :defs, value, "a map of name to schema", path)
  end

  defp opt_value(_key, _value, _path), do: []

  defp def_name_code(:root), do: :reserved_def_name
  defp def_name_code(_name), do: :invalid_def_name

  defp expect(true, _key, _value, _expected, _path), do: []

  defp expect(false, key, value, expected, path) do
    [Error.new(path, :invalid_option, %{option: key, value: value, expected: expected})]
  end

  defp one_of(values), do: "one of " <> Enum.map_join(values, ", ", &inspect/1)

  defp cross_opts(:string, pairs, path) do
    conflict(pairs, [:len, :min], path) ++
      conflict(pairs, [:len, :max], path) ++ bounds(pairs, :min, :max, path)
  end

  defp cross_opts(kind, pairs, path) when kind in [:integer, :float] do
    conflict(pairs, [:gte, :gt], path) ++
      conflict(pairs, [:lte, :lt], path) ++
      bounds(pairs, :gte, :lte, path) ++
      bounds(pairs, :gt, :lt, path)
  end

  defp cross_opts(:list, pairs, path), do: bounds(pairs, :min, :max, path)

  defp cross_opts(:union, pairs, path) do
    if Keyword.get(pairs, :tag) == :none do
      []
    else
      [Error.new(path, :untagged_union_needs_opt_in, %{})]
    end
  end

  defp cross_opts(:tagged, pairs, path) do
    tag = Keyword.get(pairs, :tag)

    cond do
      not (is_atom(tag) and not is_nil(tag) and tag != :none) ->
        [Error.new(path, :invalid_tag, %{value: tag})]

      # Adjacent tagging keeps the tag and the branch in two keys; naming them the same collapses
      # that back into one, and the tag would sit where the branch belongs.
      Keyword.get(pairs, :content) == tag ->
        [Error.new(path, :tag_content_conflict, %{tag: tag})]

      true ->
        []
    end
  end

  defp cross_opts(_kind, _pairs, _path), do: []

  defp conflict(pairs, keys, path) do
    if Enum.all?(keys, &Keyword.has_key?(pairs, &1)) do
      [Error.new(path, :conflicting_options, %{options: keys})]
    else
      []
    end
  end

  defp bounds(pairs, lower_key, upper_key, path) do
    lower = Keyword.get(pairs, lower_key)
    upper = Keyword.get(pairs, upper_key)

    if is_number(lower) and is_number(upper) and lower > upper do
      [Error.new(path, :contradictory_bounds, %{options: [lower_key, upper_key]})]
    else
      []
    end
  end

  defp function?(value) when is_function(value), do: true
  defp function?(value) when is_list(value), do: Enum.any?(value, &function?/1)

  defp function?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&function?/1)
  end

  defp function?(value) when is_map(value) do
    value |> Map.to_list() |> Enum.any?(fn {key, inner} -> function?(key) or function?(inner) end)
  end

  defp function?(_value), do: false
end

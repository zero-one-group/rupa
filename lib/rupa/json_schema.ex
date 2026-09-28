defmodule Rupa.JsonSchema do
  @moduledoc """
  JSON Schema draft 2020-12, in both directions.

  `encode/1` is total: Rupa's vocabulary is a subset of JSON Schema's declarative one, so every
  schema that validates has a document. `decode/1` is not, and cannot be — JSON Schema says far
  more than Rupa does. What it will not do is fail quietly: a keyword Rupa has no answer for is
  a named error with the path to it, never a silently dropped constraint.

  ## `encode/1` writes what the wire sees

  It stages the schema first, so the document describes the document — `rename_all:`, `from:`
  and `keys:` are already spent, and the property names are the wire keys rather than the field
  names. A field carrying both `from:` and `to:` reads one key and writes another, and what the
  document describes is the one it reads.

  Staging also resolves refs, so a `$ref` that is not on a cycle is inlined and only genuine
  recursion comes back out as `$defs` and `$ref`. The document says the same thing either way;
  it is just longer.

  ## `decode/1` interns nothing

  The objects it produces are named with strings, so no property name in a document ever becomes
  an atom. That is the whole reason `Rupa.Schema` grew string field names, and it is what makes
  it safe to decode a schema that arrived over the wire. `keys: :atom` is still there if you
  want atoms out of a document you trust.

  Two constructs in Rupa's own vocabulary cannot come back this way, because both would have to
  intern an atom from the document to exist at all:

    * a **tagged union** — its decoded tag is an atom, so `oneOf` decodes to nothing
    * a **recursive ref** — `$defs` names are atoms, so a `$ref` on a cycle decodes to nothing

  Both encode fine; neither decodes. A `$ref` that is *not* on a cycle is inlined instead, which
  needs no name at all, so ordinary reuse through `$defs` works.

  ## Where Rupa and JSON Schema disagree

  Documented rather than papered over, and measured: the official JSON-Schema-Test-Suite is
  vendored under `test/fixtures/json-schema-suite/` and every case runs on every build. What
  follows is the whole of what it reports.

  **Rupa is more permissive on three, and `encode/1` emits the keyword anyway**, so a reader
  that follows the spec is stricter than Rupa rather than looser:

    * **`format` asserts.** JSON Schema makes `format` an annotation by default; Rupa's formats
      validate and several convert. `Rupa.Schema.formats/0` is the fixed set.
    * **`pattern` is PCRE**, not ECMA-262, because it compiles with Erlang's `:re`.
    * **`minLength` and `maxLength` count grapheme clusters**, not code points — what a reader
      would count.

  **Rupa is stricter on one**, and it is one decision seen from several angles: *a number is
  compared by term, not by mathematical value*. JSON Schema says `1.0` is an `integer`, that
  `{"const": 0}` matches `0.0`, and that an `enum` of `1` matches `1.0`. On the BEAM those are
  different terms, and reconciling them would put a check on every decode in every schema to
  serve the documents that write `1.0` and mean `1`.

  Everything else the suite asks, on the keywords Rupa claims, Rupa answers the way the spec
  says. A keyword it does not claim is a skip with a reason, never a quiet pass.
  """

  alias Rupa.Closure
  alias Rupa.Error
  alias Rupa.IR
  alias Rupa.Schema
  alias Rupa.Stage

  @draft "https://json-schema.org/draft/2020-12/schema"

  @wire_formats %{
    date_time: "date-time",
    date: "date",
    time: "time",
    duration: "duration",
    uuid: "uuid",
    email: "email",
    uri: "uri",
    ipv4: "ipv4",
    ipv6: "ipv6",
    hostname: "hostname"
  }

  @formats Map.new(@wire_formats, fn {name, wire} -> {wire, name} end)

  @doc """
  Turns a schema into a draft 2020-12 document, as a decoded JSON term.

  The only errors are the schema's own, because staging runs first.

      iex> Rupa.JsonSchema.encode!(%{name: Rupa.T.string(min: 1)})
      %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string", "minLength" => 1}},
        "required" => ["name"]
      }
  """
  @spec encode(term()) :: {:ok, map()} | {:error, [Error.t()]}
  def encode(schema) do
    with {:ok, program} <- Stage.run(schema), do: {:ok, document(program)}
  end

  @doc """
  `encode/1`, raising `Rupa.SchemaError` instead of returning errors.

      iex> Rupa.JsonSchema.encode!(Rupa.T.boolean())
      %{"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "boolean"}
  """
  @spec encode!(term()) :: map()
  def encode!(schema) do
    case encode(schema) do
      {:ok, document} -> document
      {:error, errors} -> raise Rupa.SchemaError, errors: errors
    end
  end

  @doc """
  Turns a draft 2020-12 document into a schema, or says what it could not.

  Takes the document as a decoded term, or as JSON text. The objects it produces are named with
  strings, so nothing in the document becomes an atom.

      iex> {:ok, schema} = Rupa.JsonSchema.decode(~s({"type": "string", "minLength": 1}))
      iex> schema
      {:string, [min: 1]}

      iex> {:error, [error]} = Rupa.JsonSchema.decode(%{"allOf" => []})
      iex> {error.code, error.meta.keyword}
      {:unsupported_keyword, "allOf"}

  A schema it hands back compiles: what the document says in a way Rupa refuses -- a `minLength`
  above its `maxLength`, a `pattern` on a `date-time` -- is reported here, as the schema error
  `Rupa.compile/2` would have given, rather than left for the compile to find.

      iex> {:error, [error]} = Rupa.JsonSchema.decode(%{"type" => "string", "minLength" => 5, "maxLength" => 2})
      iex> error.code
      :contradictory_bounds
  """
  @spec decode(term()) :: {:ok, Schema.t()} | {:error, [Error.t()]}
  def decode(document) when is_binary(document) do
    with {:ok, parsed} <- Rupa.Json.parse(document), do: decode(parsed)
  end

  def decode(document) do
    with {:ok, resolved} <- resolve(document),
         {:ok, schema} <- read(resolved, []),
         {:ok, _program} <- Stage.run(schema) do
      {:ok, schema}
    end
  end

  @doc """
  `decode/1`, raising `Rupa.SchemaError` instead of returning errors.

      iex> Rupa.JsonSchema.decode!(%{"type" => "integer", "minimum" => 0})
      {:integer, [gte: 0]}
  """
  @spec decode!(term()) :: Schema.t()
  def decode!(document) do
    case decode(document) do
      {:ok, schema} -> schema
      {:error, errors} -> raise Rupa.SchemaError, errors: errors
    end
  end

  # =============================================
  # Out
  # =============================================

  # `:root` is the schema itself, so a ref to it is `"#"` and it needs no `$defs` entry. Anything
  # else on a cycle does.
  defp document(%{root: root, defs: defs} = program) do
    named = Map.delete(defs, :root)
    base = Map.put(out(root, program), "$schema", @draft)

    case map_size(named) do
      0 ->
        base

      _ ->
        Map.put(base, "$defs", Map.new(named, fn {n, ir} -> {to_string(n), out(ir, program)} end))
    end
  end

  defp out(%IR.Scalar{kind: kind} = scalar, _program) do
    %{"type" => scalar_type(kind)}
    |> put_checks(scalar.checks, kind)
    |> put_format(scalar.format)
  end

  defp out(%IR.Const{values: [only]} = const, _program) do
    %{"const" => Map.fetch!(const.reverse, only)}
  end

  defp out(%IR.Const{values: values} = const, _program) do
    %{"enum" => Enum.map(values, &Map.fetch!(const.reverse, &1))}
  end

  defp out(%IR.Object{} = object, program), do: object_out(object, %{}, [], program)

  defp out(%IR.Array{of: inner, checks: checks}, program) do
    %{"type" => "array", "items" => out(inner, program)}
    |> put_checks(checks, :array)
  end

  # `prefixItems` must be non-empty when present (draft 2020-12), so a zero-length tuple is written
  # as the array that admits no items at all -- `items: false` with no prefix -- and read back the
  # same way.
  defp out(%IR.Fixed{members: []}, _program) do
    %{"type" => "array", "items" => false, "maxItems" => 0}
  end

  defp out(%IR.Fixed{members: members}, program) do
    %{
      "type" => "array",
      "prefixItems" => Enum.map(members, &out(&1, program)),
      "items" => false,
      "minItems" => length(members)
    }
  end

  defp out(%IR.Dict{of: inner}, program) do
    %{"type" => "object", "additionalProperties" => out(inner, program)}
  end

  defp out(%IR.Nullable{of: inner}, program) do
    %{"anyOf" => [out(inner, program), %{"type" => "null"}]}
  end

  defp out(%IR.Union{members: members}, program) do
    %{"anyOf" => Enum.map(members, &out(&1, program))}
  end

  defp out(%IR.Tagged{} = tagged, program) do
    %{"oneOf" => Enum.map(tagged.branches, &branch_out(tagged, &1, program))}
  end

  defp out(%IR.Ref{name: :root}, _program), do: %{"$ref" => "#"}

  # A `$defs` name is a `$defs` *key*, but a `$ref` reaches it through a JSON Pointer inside a URI
  # fragment. So the key is written verbatim while the pointer is escaped in two layers, the inverse
  # of `ref_name/2`: the pointer's `~`/`/` (RFC 6901), then the fragment's percent-encoding (RFC
  # 3986). Without the outer layer a name holding a literal `%` or space would decode to a different
  # name in a standards-compliant consumer.
  defp out(%IR.Ref{name: name}, _program) do
    %{"$ref" => "#/$defs/" <> encode_fragment(escape_pointer(to_string(name)))}
  end

  defp escape_pointer(token) do
    token |> String.replace("~", "~0") |> String.replace("/", "~1")
  end

  defp encode_fragment(token), do: URI.encode(token, &URI.char_unreserved?/1)

  defp unescape_pointer(token) do
    token |> String.replace("~1", "/") |> String.replace("~0", "~")
  end

  # An object, plus whatever a tagged union needs folded into it: the discriminator property and
  # the requirement that it is there.
  defp object_out(%IR.Object{fields: fields, unknown: unknown}, extra, extra_required, program) do
    properties = Map.new(fields, fn field -> {field.from, field_out(field, program)} end)
    required = for field <- fields, field.presence == :required, do: field.from

    %{"type" => "object"}
    |> put_unless_empty("properties", Map.merge(properties, extra))
    |> put_unless_empty("required", Enum.sort(required ++ extra_required))
    |> put_closed(unknown)
  end

  defp field_out(%IR.Field{default: :none} = field, program), do: out(field.ir, program)

  # `default:` is an annotation in JSON Schema and a decoded value in Rupa, so what goes in the
  # document is the wire form -- which only the field's own encoder knows. The document describes
  # the wire the decoder *reads*, so the encoder is built over the inbound copy of the program
  # (every field writing its `from` name): a migration field's default then spells its keys the
  # way the surrounding `properties` do, rather than the way the real encoder would write them.
  # Staging has already put every default through its field and rejected the ones that do not
  # fit, so the encoder cannot fail here.
  defp field_out(%IR.Field{default: {:value, value}} = field, %{defs: defs} = program) do
    inbound = IR.Rewrite.inbound_program(%{root: field.ir, defs: defs})
    {encode, encode_defs} = Closure.build_encoder(inbound)
    {:ok, wire} = encode.(value, {:halt, encode_defs})

    Map.put(out(field.ir, program), "default", wire)
  end

  defp branch_out(%IR.Tagged{content: nil} = tagged, branch, program) do
    tag = %{tagged.tag_wire => %{"const" => branch.wire}}

    object_out(branch.ir, tag, [tagged.tag_wire], program)
  end

  defp branch_out(tagged, branch, program) do
    %{
      "type" => "object",
      "properties" => %{
        tagged.tag_wire => %{"const" => branch.wire},
        tagged.content_wire => out(branch.ir, program)
      },
      "required" => Enum.sort([tagged.tag_wire, tagged.content_wire])
    }
  end

  defp scalar_type(:float), do: "number"
  defp scalar_type(kind), do: to_string(kind)

  defp put_closed(document, :error), do: Map.put(document, "additionalProperties", false)
  defp put_closed(document, _policy), do: document

  defp put_unless_empty(document, _key, empty) when empty == %{} or empty == [], do: document
  defp put_unless_empty(document, key, value), do: Map.put(document, key, value)

  defp put_format(document, nil), do: document
  defp put_format(document, format), do: Map.put(document, "format", @wire_formats[format])

  defp put_checks(document, checks, kind) do
    Enum.reduce(checks, document, fn check, acc -> put_check(acc, check, kind) end)
  end

  defp put_check(document, {:len, len}, :string) do
    document |> Map.put("minLength", len) |> Map.put("maxLength", len)
  end

  defp put_check(document, {:min, min}, :string), do: Map.put(document, "minLength", min)
  defp put_check(document, {:max, max}, :string), do: Map.put(document, "maxLength", max)
  defp put_check(document, {:pattern, source}, :string), do: Map.put(document, "pattern", source)
  defp put_check(document, {:min, min}, :array), do: Map.put(document, "minItems", min)
  defp put_check(document, {:max, max}, :array), do: Map.put(document, "maxItems", max)
  defp put_check(document, {:unique, true}, :array), do: Map.put(document, "uniqueItems", true)
  defp put_check(document, {:unique, false}, :array), do: document
  defp put_check(document, {:gte, bound}, _kind), do: Map.put(document, "minimum", bound)
  defp put_check(document, {:gt, bound}, _kind), do: Map.put(document, "exclusiveMinimum", bound)
  defp put_check(document, {:lte, bound}, _kind), do: Map.put(document, "maximum", bound)
  defp put_check(document, {:lt, bound}, _kind), do: Map.put(document, "exclusiveMaximum", bound)

  defp put_check(document, {:multiple_of, step}, _kind) do
    Map.put(document, "multipleOf", step)
  end

  # =============================================
  # In
  # =============================================

  @scalar_types %{
    "string" => :string,
    "integer" => :integer,
    "number" => :float,
    "boolean" => :boolean,
    "null" => :null
  }

  @unsupported ~w(
    allOf oneOf not if then else
    dependentRequired dependentSchemas patternProperties propertyNames
    contains minContains maxContains
    unevaluatedItems unevaluatedProperties
    minProperties maxProperties
    $anchor $dynamicAnchor $dynamicRef $id $recursiveRef contentEncoding contentMediaType
  )

  # Keywords that annotate rather than assert: they never change what validates, so any construct
  # may carry them. `default` is read by `presence/4` at the object level and is an annotation
  # everywhere else.
  @annotations ~w(title description default examples $comment $schema $id deprecated readOnly writeOnly)

  # A `$ref` that is not on a cycle needs no name, so it is inlined before anything else looks at
  # the document — the same thing staging does to Rupa's own refs, just earlier. One on a cycle
  # would need a `$defs` name, and a `$defs` name is an atom, so it stops here instead.
  defp resolve(document) when is_map(document) do
    case Map.get(document, "$defs", %{}) do
      defs when is_map(defs) ->
        document |> Map.delete("$defs") |> inline(defs, [], [])

      # `$defs` is read below by `Map.fetch/2`, which raises on the wrong shape. A document is
      # untrusted input, so a malformed keyword is a structured error rather than a crash.
      _malformed ->
        {:error, [Error.new([], :invalid_keyword, %{keyword: "$defs"})]}
    end
  end

  defp resolve(document), do: {:ok, document}

  # Draft 2020-12 applies a `$ref`'s siblings alongside the referenced schema. Rupa inlines the
  # target and has nowhere to fold siblings in, so rather than dropping them it refuses -- the
  # same "never quietly" rule the rest of this module follows. A lone `$ref` is the common case
  # and still works.
  defp inline(%{"$ref" => ref} = node, defs, stack, path) when is_binary(ref) do
    case Map.delete(node, "$ref") do
      empty when map_size(empty) == 0 ->
        with {:ok, name} <- ref_name(ref, path),
             :ok <- unseen(name, stack, path),
             {:ok, target} <- fetch_def(defs, name, path) do
          inline(target, defs, [name | stack], path)
        end

      _siblings ->
        {:error, [Error.new(path, :unsupported_ref_siblings, %{})]}
    end
  end

  defp inline(node, defs, stack, path) when is_map(node) do
    Enum.reduce_while(node, {:ok, node}, fn {keyword, value}, {:ok, acc} ->
      case inline_under(keyword, value, defs, stack, path) do
        {:ok, replaced} -> {:cont, {:ok, Map.put(acc, keyword, replaced)}}
        {:error, _errors} = error -> {:halt, error}
      end
    end)
  end

  defp inline(node, _defs, _stack, _path), do: {:ok, node}

  # Only the keywords Rupa can read hold schemas worth walking into. A `$ref` under one it cannot
  # read is left where it is, and the keyword itself is refused a moment later.
  defp inline_under(keyword, value, defs, stack, path)
       when keyword in ["items", "additionalProperties"] and is_map(value) do
    inline(value, defs, stack, path ++ [:of])
  end

  defp inline_under("properties", value, defs, stack, path) when is_map(value) do
    inline_each(Map.to_list(value), defs, stack, path, &{:ok, Map.new(&1)})
  end

  defp inline_under(keyword, value, defs, stack, path)
       when keyword in ["prefixItems", "anyOf"] and is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {member, index} -> {index, member} end)
    |> inline_each(defs, stack, path, &{:ok, Enum.map(&1, fn {_index, node} -> node end)})
  end

  defp inline_under(_keyword, value, _defs, _stack, _path), do: {:ok, value}

  defp inline_each(pairs, defs, stack, path, rebuild) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {segment, node}, {:ok, acc} ->
      case inline(node, defs, stack, path ++ [segment]) do
        {:ok, replaced} -> {:cont, {:ok, [{segment, replaced} | acc]}}
        {:error, _errors} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> acc |> Enum.reverse() |> rebuild.()
      {:error, _errors} = error -> error
    end
  end

  defp ref_name("#", path) do
    {:error, [Error.new(path, :unsupported_recursive_ref, %{name: "#"})]}
  end

  # A `$ref` is a URI reference whose fragment is a JSON Pointer, so it peels in two layers: the
  # fragment's percent-encoding (RFC 3986) first, then the pointer's `~` escaping (RFC 6901). After
  # `#/$defs/` a single token is a definition name; a `/` left after percent-decoding is a deeper
  # pointer into the definition, which Rupa resolves one level only -- so it is refused rather than
  # matched against a coincidental flat key.
  defp ref_name("#/$defs/" <> encoded, path) when encoded != "" do
    decoded = URI.decode(encoded)

    if String.contains?(decoded, "/") do
      {:error, [Error.new(path, :unsupported_ref, %{ref: "#/$defs/" <> encoded})]}
    else
      {:ok, unescape_pointer(decoded)}
    end
  end

  defp ref_name(ref, path), do: {:error, [Error.new(path, :unsupported_ref, %{ref: ref})]}

  defp unseen(name, stack, path) do
    if name in stack,
      do: {:error, [Error.new(path, :unsupported_recursive_ref, %{name: name})]},
      else: :ok
  end

  defp fetch_def(defs, name, path) do
    case Map.fetch(defs, name) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, [Error.new(path, :unresolved_ref, %{name: name})]}
    end
  end

  defp read(document, path) when is_map(document) do
    case Enum.find(@unsupported, &Map.has_key?(document, &1)) do
      nil -> read_kind(document, path)
      keyword -> {:error, [Error.new(path, :unsupported_keyword, %{keyword: keyword})]}
    end
  end

  defp read(document, path) do
    {:error, [Error.new(path, :unsupported_schema, %{value: document})]}
  end

  # `const: null` is `T.null()`, not a literal `nil` -- but only when the rest of the document
  # agrees. `narrow/2` drops the value if a sibling `type` excludes it, so `{const: null, type:
  # string}` is the contradiction it looks like rather than a quietly-accepted null.
  defp read_kind(%{"const" => nil} = document, path) do
    case narrow([nil], document) do
      [nil] -> only({:ok, {:null, []}}, document, ~w(const type), path)
      [] -> {:error, [Error.new(path, :unsupported_schema, %{value: nil})]}
    end
  end

  # A `null` among the values is the one member Rupa's closed sets do not hold -- null is its own
  # type -- so it comes out as the nullable it means: `[null, "a"]` is a nullable enum of `"a"`,
  # and `[null]` alone is `T.null/0`.
  defp read_kind(%{"enum" => values} = document, path) when is_list(values) do
    only(enum_of(narrow(values, document), path), document, ~w(enum type), path)
  end

  defp read_kind(%{"const" => value} = document, path) do
    case narrow([value], document) do
      [kept] -> only(closed(:literal, kept, path), document, ~w(const type), path)
      [] -> {:error, [Error.new(path, :unsupported_schema, %{value: value})]}
    end
  end

  defp read_kind(%{"anyOf" => members} = document, path) do
    only(read_any_of(members, path), document, ~w(anyOf), path)
  end

  defp read_kind(%{"type" => "object"} = document, path) do
    only(
      read_object(document, path),
      document,
      ~w(type properties additionalProperties required),
      path
    )
  end

  defp read_kind(%{"type" => "array"} = document, path), do: read_array(document, path)

  defp read_kind(%{"type" => type} = document, path) when is_map_key(@scalar_types, type) do
    kind = Map.fetch!(@scalar_types, type)
    only(read_scalar(kind, document, path), document, consumed(kind), path)
  end

  # `["string", "null"]` is how most documents spell a nullable, in either order, and one type in
  # a list is just that type. Anything wider needs each member to carry only the constraints that
  # belong to it, which the document does not say — so it stops here rather than guessing.
  defp read_kind(%{"type" => [single]} = document, path) do
    read_kind(Map.put(document, "type", single), path)
  end

  defp read_kind(%{"type" => ["null", other]} = document, path),
    do: nullable_of(other, document, path)

  defp read_kind(%{"type" => [other, "null"]} = document, path),
    do: nullable_of(other, document, path)

  defp read_kind(%{"type" => types}, path) when is_list(types) do
    {:error, [Error.new(path, :unsupported_type_union, %{types: types})]}
  end

  defp read_kind(%{"type" => type}, path) do
    {:error, [Error.new(path, :unknown_type, %{value: type})]}
  end

  # Every Rupa node has a type. A document that constrains without saying what it is constraining
  # applies only to the values of that type and passes everything else, which is a shape the
  # vocabulary cannot say at all.
  defp read_kind(_document, path) do
    {:error, [Error.new(path, :untyped_schema, %{})]}
  end

  # JSON Schema keywords all apply together, so a construct that reads one keyword cannot drop the
  # rest of the object -- a `{const: 1, minimum: 2}` where `1 < 2` would validate nothing, and
  # accepting the const alone gets it wrong. Each construct passes the keywords it consumes; any
  # other assertion keyword left over is refused, the same way a `$ref`'s siblings are. Annotations
  # never assert, so they are always allowed. An already-failed read passes straight through.
  defp only({:error, _errors} = error, _document, _consumed, _path), do: error

  defp only({:ok, _schema} = ok, document, consumed, path) do
    case Map.keys(document) -- (consumed ++ @annotations) do
      [] ->
        ok

      extra ->
        {:error,
         [Error.new(path, :unsupported_keyword_combination, %{keywords: Enum.sort(extra)})]}
    end
  end

  defp consumed(:string), do: ~w(type format minLength maxLength pattern)

  defp consumed(kind) when kind in [:integer, :float] do
    ~w(type minimum exclusiveMinimum maximum exclusiveMaximum multipleOf)
  end

  defp consumed(_kind), do: ~w(type)

  defp nullable_of(type, document, path) do
    with {:ok, inner} <- read_kind(Map.put(document, "type", type), path) do
      {:ok, nullable(inner)}
    end
  end

  # A nullable null is a null: `["null", "null"]`, `anyOf: [{type: null}, {type: null}]` and an
  # `enum` of just `null` all say the one thing, and `T.nullable/1` around `T.null/0` is refused
  # by `Rupa.Schema` as saying it twice.
  defp nullable({:null, []}), do: {:null, []}
  defp nullable(inner), do: {:nullable, inner, []}

  # The wire values stay as they are -- a string enum decodes to strings, not to atoms, which is
  # the same reason the objects are named with strings.
  defp closed(:enum, values, _path) when is_list(values) and values != [] do
    {:ok, {:enum, values, []}}
  end

  defp closed(:literal, value, _path), do: {:ok, {:literal, value, []}}

  defp closed(kind, value, path),
    do: {:error, [Error.new(path, :unsupported_schema, %{value: {kind, value}})]}

  # The values are made unique first: the spec only says they *should* be, and Rupa's own enum
  # refuses a value listed twice.
  defp enum_of(values, path) do
    case values |> Enum.uniq() |> Enum.split_with(&is_nil/1) do
      {[], unique} -> closed(:enum, unique, path)
      {[nil], []} -> {:ok, {:null, []}}
      {[nil], rest} -> with({:ok, inner} <- closed(:enum, rest, path), do: {:ok, nullable(inner)})
    end
  end

  # A value the declared type excludes can never validate, so leaving it out says the same thing
  # in fewer words -- and leaves no `type` for Rupa to quietly ignore beside the closed set.
  defp narrow(values, %{"type" => type}) when is_binary(type) do
    Enum.filter(values, &json_type?(&1, type))
  end

  # A `type` array narrows against every alternative at once: a value survives if it matches any of
  # them. Without this the array falls through unfiltered while `read_kind` still marks `type`
  # consumed, so `{const: 1, type: ["string"]}` would keep a value the array forbids.
  defp narrow(values, %{"type" => types}) when is_list(types) do
    Enum.filter(values, fn value -> Enum.any?(types, &json_type?(value, &1)) end)
  end

  defp narrow(values, _document), do: values

  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "number"), do: is_number(value)
  defp json_type?(value, "boolean"), do: is_boolean(value)
  defp json_type?(value, "null"), do: is_nil(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(value, "array"), do: is_list(value)
  defp json_type?(_value, _type), do: false

  defp read_scalar(kind, document, path) do
    with {:ok, opts} <- scalar_opts(kind, document, path), do: {:ok, {kind, Enum.sort(opts)}}
  end

  defp scalar_opts(:string, document, path) do
    with {:ok, format} <- read_format(document, path) do
      {:ok,
       format ++
         bound(document, "minLength", :min) ++
         bound(document, "maxLength", :max) ++ bound(document, "pattern", :pattern)}
    end
  end

  defp scalar_opts(kind, document, _path) when kind in [:integer, :float] do
    {:ok,
     bound(document, "minimum", :gte) ++
       bound(document, "exclusiveMinimum", :gt) ++
       bound(document, "maximum", :lte) ++
       bound(document, "exclusiveMaximum", :lt) ++ bound(document, "multipleOf", :multiple_of)}
  end

  defp scalar_opts(_kind, _document, _path), do: {:ok, []}

  defp read_format(%{"format" => wire}, path) do
    case Map.fetch(@formats, wire) do
      {:ok, format} -> {:ok, [format: format]}
      :error -> {:error, [Error.new(path, :unknown_format, %{format: wire})]}
    end
  end

  defp read_format(_document, _path), do: {:ok, []}

  defp bound(document, keyword, option) do
    case Map.fetch(document, keyword) do
      {:ok, value} -> [{option, value}]
      :error -> []
    end
  end

  defp read_object(document, path) do
    properties = Map.get(document, "properties", %{})

    with :ok <- keyword_shape(document, path),
         :ok <- covered(document, properties, path) do
      object_of(properties, Map.get(document, "additionalProperties"), document, path)
    end
  end

  # `required` and `properties` are read below by `Enum` and `map_size`, which raise on the wrong
  # shape. A document is untrusted input, so a malformed keyword is a structured error rather
  # than a crash -- or, worse, a silent empty object when `properties` is not a map.
  defp keyword_shape(document, path) do
    cond do
      not valid_required?(Map.get(document, "required", [])) ->
        {:error, [Error.new(path, :invalid_keyword, %{keyword: "required"})]}

      not is_map(Map.get(document, "properties", %{})) ->
        {:error, [Error.new(path, :invalid_keyword, %{keyword: "properties"})]}

      true ->
        :ok
    end
  end

  defp valid_required?(required) when is_list(required), do: Enum.all?(required, &is_binary/1)
  defp valid_required?(_required), do: false

  # `properties` says what the named keys hold and `additionalProperties` says what the rest
  # hold. Rupa's object is the first and its map-of is the second; one term cannot be both.
  defp object_of(properties, extra, _document, path)
       when map_size(properties) > 0 and is_map(extra) do
    {:error, [Error.new(path, :unsupported_mixed_object, %{})]}
  end

  defp object_of(properties, _extra, document, path) when map_size(properties) > 0 do
    with {:ok, fields} <- read_properties(properties, document, path) do
      {:ok, {:object, fields, unknown_opt(document)}}
    end
  end

  defp object_of(_properties, extra, _document, path) when is_map(extra) do
    with {:ok, of} <- read(extra, path ++ [:of]), do: {:ok, {:map_of, of, []}}
  end

  defp object_of(_properties, _extra, document, _path) do
    {:ok, {:object, %{}, unknown_opt(document)}}
  end

  # `required` naming a key `properties` does not describe says "this must be here, and may hold
  # anything". Rupa has no way to say that, so reading the object would drop the requirement on
  # the floor -- which is the one thing this module promises not to do.
  defp covered(document, properties, path) do
    case Enum.reject(Map.get(document, "required", []), &Map.has_key?(properties, &1)) do
      [] -> :ok
      [name | _rest] -> {:error, [Error.new(path, :unsupported_bare_required, %{name: name})]}
    end
  end

  defp read_properties(properties, document, path) do
    required = MapSet.new(Map.get(document, "required", []))

    properties
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn {name, sub}, {fields, errors} ->
      case read(sub, path ++ [name]) do
        {:ok, schema} -> {Map.put(fields, name, presence(schema, sub, name, required)), errors}
        {:error, found} -> {fields, errors ++ found}
      end
    end)
    |> case do
      {fields, []} -> {:ok, fields}
      {_fields, errors} -> {:error, errors}
    end
  end

  # `required` and `default` mean different things and `required` wins. In JSON Schema `default` is
  # an annotation that never waives `required` -- a required field must be present on the wire -- so
  # a name in `required` stays required and the default is dropped. Rupa's own `default:` means
  # optional, so it is only read for a name `required` does not list; there it also makes the field
  # optional, which is the same pair `encode/1` writes, so the two directions close.
  defp presence(schema, sub, name, required) do
    cond do
      MapSet.member?(required, name) ->
        schema

      match?(%{"default" => _raw}, sub) ->
        with_default(schema, default_value(schema, sub["default"]))

      true ->
        {:optional, schema, []}
    end
  end

  # A document default is a wire value; Rupa's `default:` holds the decoded one, so the raw value is
  # decoded through the property's own decoder -- a `date` string becomes a `Date`, a list of them a
  # list of `Date`s, and so on, matching what a present field would have decoded to. A default the
  # decoder rejects is left as written, and staging then reports it as `:invalid_default` with the
  # field's path rather than this guessing.
  defp default_value(schema, raw) do
    with {:ok, program} <- Stage.run(schema),
         {decode, defs} = Closure.build(program),
         {:ok, decoded} <- decode.(raw, {:halt, defs}) do
      decoded
    else
      _other -> raw
    end
  end

  defp with_default({kind, opts}, value), do: {kind, [{:default, value} | opts]}
  defp with_default({kind, payload, opts}, value), do: {kind, payload, [{:default, value} | opts]}

  defp unknown_opt(%{"additionalProperties" => false}), do: [unknown: :error]
  defp unknown_opt(_document), do: []

  # A tuple carries no `uniqueItems` -- the tuple IR has no uniqueness check -- so it is not in the
  # consumed set and a `uniqueItems: true` beside `prefixItems` is refused rather than dropped.
  defp read_array(%{"prefixItems" => members} = document, path) when is_list(members) do
    result =
      with :ok <- closed_tuple(document, path, length(members)),
           {:ok, staged} <- read_members(members, path) do
        {:ok, {:tuple, staged, []}}
      end

    only(result, document, ~w(type prefixItems items minItems maxItems), path)
  end

  # `items: false` with no `prefixItems` is an array that admits no items -- the zero-length tuple.
  # A `minItems`/`maxItems` that asks for anything but zero contradicts that, so it is refused
  # rather than silently dropped.
  defp read_array(%{"items" => false} = document, path) do
    result =
      if Map.get(document, "minItems", 0) == 0 and Map.get(document, "maxItems", 0) == 0 do
        {:ok, {:tuple, [], []}}
      else
        {:error, [Error.new(path, :unsupported_open_tuple, %{size: 0})]}
      end

    only(result, document, ~w(type items minItems maxItems), path)
  end

  defp read_array(%{"items" => inner} = document, path) when is_map(inner) do
    result =
      with {:ok, of} <- read(inner, path ++ [:of]) do
        {:ok, {:list, of, Enum.sort(array_opts(document))}}
      end

    only(result, document, ~w(type items minItems maxItems uniqueItems), path)
  end

  defp read_array(_document, path), do: {:error, [Error.new(path, :untyped_schema, %{})]}

  # A Rupa tuple is exactly as long as its members, and `prefixItems` on its own pins neither end:
  # a shorter array satisfies it, and so does a longer one unless something closes it. Both ends
  # have to sit at exactly the length -- `minItems` equal to it, and either `items: false` or a
  # `maxItems` equal to it -- and a `maxItems` at any other value is a bound the tuple cannot
  # express, so it is refused rather than dropped.
  defp closed_tuple(document, path, size) do
    max = Map.get(document, "maxItems")

    if Map.get(document, "minItems") == size and capped?(document, size) and
         (is_nil(max) or max == size),
       do: :ok,
       else: {:error, [Error.new(path, :unsupported_open_tuple, %{size: size})]}
  end

  defp capped?(%{"items" => false}, _size), do: true
  defp capped?(document, size), do: Map.get(document, "maxItems") == size

  defp read_members(members, path) do
    members
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {member, index}, {staged, errors} ->
      case read(member, path ++ [index]) do
        {:ok, schema} -> {[schema | staged], errors}
        {:error, found} -> {staged, errors ++ found}
      end
    end)
    |> case do
      {staged, []} -> {:ok, Enum.reverse(staged)}
      {_staged, errors} -> {:error, errors}
    end
  end

  defp array_opts(document) do
    bound(document, "minItems", :min) ++
      bound(document, "maxItems", :max) ++ unique_opt(document)
  end

  defp unique_opt(%{"uniqueItems" => true}), do: [unique: true]
  defp unique_opt(_document), do: []

  # `anyOf` of exactly a schema and a bare null is how `encode/1` writes a nullable, so it reads
  # back as one. `map_size(null) == 1` because the pattern is partial: a second branch carrying
  # more than `type` (a `const`, a `not`, …) is a real branch, not the null shortcut, and has to go
  # through `read/2` and the keyword check like any other -- otherwise its assertions vanish and
  # `nil` is accepted though the branch forbids it.
  defp read_any_of([inner, %{"type" => "null"} = null], path) when map_size(null) == 1 do
    with {:ok, of} <- read(inner, path ++ [0]), do: {:ok, nullable(of)}
  end

  defp read_any_of(members, path) when is_list(members) and length(members) > 1 do
    with {:ok, staged} <- read_members(members, path), do: {:ok, {:union, staged, [tag: :none]}}
  end

  defp read_any_of(members, path) do
    {:error, [Error.new(path, :unsupported_schema, %{value: members})]}
  end
end

defmodule Rupa.T do
  @moduledoc """
  The constructors. Every one of them returns a plain term.

      alias Rupa.T

      T.string(min: 1)
      #=> {:string, [min: 1]}

  There is no macro here and no state anywhere: `T.string/1` is a function that builds a
  tuple, and you are free to write the tuple yourself. What the constructors add is canonical
  form — a bare map becomes an object, and options come back sorted by key, so two spellings
  of the same schema are the same term and hash the same under `:erlang.phash2/1`.

  Nothing here checks anything. `Rupa.Schema.validate/1` is the judge, and it reports every
  problem in the tree at once.

  ## The vocabulary

  Scalars carry only options: `string/1`, `integer/1`, `float/1`, `boolean/1`, `null/1`.
  Everything else carries a payload as well: `literal/2`, `enum/2`, `object/2`, `list/2`,
  `map_of/2`, `tuple/2`, `optional/2`, `nullable/2`, `ref/2`, `union/2`, `tagged/3`.

  Options every kind takes: `default:`, `from:`, `to:`. The rest are per kind and listed on
  each function.

  ## Required, optional, nullable

  A field is required unless it is wrapped in `optional/2` or carries `default:`. `optional/2`
  is about the **key**, `nullable/2` is about the **value**, and they compose. See
  `Rupa.Schema` for the whole rule.

  ## Names on the wire

  `from:` and `to:` rename one field; `rename_all:` and `keys:` on `object/2` do it wholesale.
  All four belong to the object field, not to the type, so they go on the term the object's
  field map holds — see `Rupa.Schema` for the rule and what each one means.
  """

  alias Rupa.Schema

  @type t :: Schema.t()

  @doc """
  A string. Options: `min:`, `max:`, `len:`, `pattern:`, `format:`.

  `pattern:` is PCRE source in a string, compiled once when the schema is compiled. `format:`
  is one of `Rupa.Schema.formats/0`. The four formats that decode to a value -- `:date_time`,
  `:date`, `:time`, `:duration` -- re-encode to a canonical spelling the incoming one need not
  match, so a length or pattern check cannot hold beside them and is refused at compile time;
  the six that hand the string back unchanged take one.

      iex> Rupa.T.string(min: 1)
      {:string, [min: 1]}
  """
  @spec string(keyword()) :: t()
  def string(opts \\ []), do: Schema.normalize({:string, opts})

  @doc """
  An integer. Options: `gte:`, `gt:`, `lte:`, `lt:`, `multiple_of:`.

      iex> Rupa.T.integer(gte: 0, lte: 150)
      {:integer, [gte: 0, lte: 150]}
  """
  @spec integer(keyword()) :: t()
  def integer(opts \\ []), do: Schema.normalize({:integer, opts})

  @doc """
  A float. Options: `gte:`, `gt:`, `lte:`, `lt:`, `multiple_of:`.

      iex> Rupa.T.float(gt: 0)
      {:float, [gt: 0]}
  """
  @spec float(keyword()) :: t()
  def float(opts \\ []), do: Schema.normalize({:float, opts})

  @doc """
  A boolean.

      iex> Rupa.T.boolean()
      {:boolean, []}
  """
  @spec boolean(keyword()) :: t()
  def boolean(opts \\ []), do: Schema.normalize({:boolean, opts})

  @doc """
  JSON `null`, and nothing else. For "this value may be null", reach for `nullable/2`.

      iex> Rupa.T.null()
      {:null, []}
  """
  @spec null(keyword()) :: t()
  def null(opts \\ []), do: Schema.normalize({:null, opts})

  @doc """
  One exact value — JSON Schema's `const`. Strings, atoms, numbers and booleans.

      iex> Rupa.T.literal("v2")
      {:literal, "v2", []}
  """
  @spec literal(term(), keyword()) :: t()
  def literal(value, opts \\ []), do: Schema.normalize({:literal, value, opts})

  @doc """
  A closed set of values — JSON Schema's `enum`.

      iex> Rupa.T.enum([:admin, :member], default: :member)
      {:enum, [:admin, :member], [default: :member]}
  """
  @spec enum([term()], keyword()) :: t()
  def enum(values, opts \\ []), do: Schema.normalize({:enum, values, opts})

  @doc """
  An object, from a map of field name to schema. Options: `rename_all:`, `unknown:`, `keys:`,
  `into:`, `defs:`.

  A bare map is already an object, so `object/1` matters only when you want the options.

  `rename_all:` spells every field's wire key in one style, `keys:` chooses whether the decoded
  map is keyed by atoms or strings, and `unknown:` says what to do with a wire key the schema
  does not name — `:strip`, `:error` or `:keep`.

  Field names are atoms, or strings for an object whose names you did not choose — see
  `Rupa.Schema` for the rule and for what `keys:` then defaults to.

  `into:` names a struct module to decode into, and it is an option on **this** object rather
  than on the compile, so an object nested three levels down becomes a struct the same way the
  root does. `Rupa.Schema` has what it cannot hold with, and `mix rupa.gen.struct` writes the
  modules.

      iex> Rupa.T.object(%{id: Rupa.T.uuid()}, unknown: :error)
      {:object, %{id: {:string, [format: :uuid]}}, [unknown: :error]}

      iex> Rupa.T.object(%{"id" => Rupa.T.uuid()})
      {:object, %{"id" => {:string, [format: :uuid]}}, []}

      iex> Rupa.T.object(%{first_name: Rupa.T.string()}, rename_all: :camelCase)
      {:object, %{first_name: {:string, []}}, [rename_all: :camelCase]}

      iex> Rupa.T.object(%{name: Rupa.T.string()}, into: URI)
      {:object, %{name: {:string, []}}, [into: URI]}

      iex> Rupa.T.object(%{name: Rupa.T.string()})
      {:object, %{name: {:string, []}}, []}
  """
  @spec object(map(), keyword()) :: t()
  def object(fields, opts \\ []), do: Schema.normalize({:object, fields, opts})

  @doc """
  A list of one element type. Options: `min:`, `max:`, `unique:`.

  `unique:` is checked on the decoded elements, not the wire: two entries that differ only where
  decoding discards — a stripped unknown key, an integer that decodes like a float — count as the
  same value, so the decoded list round-trips.

      iex> Rupa.T.list(Rupa.T.integer(), max: 5)
      {:list, {:integer, []}, [max: 5]}
  """
  @spec list(term(), keyword()) :: t()
  def list(of, opts \\ []), do: Schema.normalize({:list, of, opts})

  @doc """
  An object of unknown keys and one value type — JSON Schema's `additionalProperties`.

      iex> Rupa.T.map_of(Rupa.T.integer())
      {:map_of, {:integer, []}, []}
  """
  @spec map_of(term(), keyword()) :: t()
  def map_of(of, opts \\ []), do: Schema.normalize({:map_of, of, opts})

  @doc """
  A fixed-length list, one schema per position — JSON Schema's `prefixItems`.

      iex> Rupa.T.tuple([Rupa.T.float(), Rupa.T.float()])
      {:tuple, [{:float, []}, {:float, []}], []}
  """
  @spec tuple([term()], keyword()) :: t()
  def tuple(members, opts \\ []), do: Schema.normalize({:tuple, members, opts})

  @doc """
  The key may be absent. Only meaningful on an object field.

  Absent decodes to the key not being there, not to `nil`. Pair it with `default:` on the
  `optional` itself to fill the gap instead.

      iex> Rupa.T.optional(Rupa.T.string())
      {:optional, {:string, []}, []}
  """
  @spec optional(term(), keyword()) :: t()
  def optional(schema, opts \\ []), do: Schema.normalize({:optional, schema, opts})

  @doc """
  The value may be JSON `null`, which decodes to `nil`. Says nothing about the key.

      iex> Rupa.T.nullable(Rupa.T.string())
      {:nullable, {:string, []}, []}
  """
  @spec nullable(term(), keyword()) :: t()
  def nullable(schema, opts \\ []), do: Schema.normalize({:nullable, schema, opts})

  @doc """
  A named reference — JSON Schema's `$ref`. `:root` is `"#"`; any other name resolves against
  `defs:`.

      iex> Rupa.T.ref(:root)
      {:ref, :root, []}
  """
  @spec ref(atom(), keyword()) :: t()
  def ref(name, opts \\ []), do: Schema.normalize({:ref, name, opts})

  @doc """
  An untagged union — JSON Schema's `anyOf`. Opt in with `tag: :none`.

  It costs one decode attempt per variant, in the order you wrote them, and the first that
  takes the value wins. Nesting multiplies that, so Rupa makes you say you meant it — and warns
  when you nest one anyway. `tagged/3` is the one that stays flat.

  Because the first that fits wins, a variant an earlier one already accepts is never reached:
  `union([T.float(), T.integer()], tag: :none)` decodes every number as a float. Rupa does not
  check for that, and on the module backend the compiler may say so in its own words, about a
  function in the generated codec rather than about the schema.

  Encoding costs one decode too. A decoded value does not record which branch it came from, so to
  stay a true inverse the encoder writes each branch in turn and keeps the first whose wire decodes
  back to the value — otherwise a branch that merely accepts the value's type could drop a field a
  later branch kept. A value no branch round-trips is a `:no_variant` error, the same as decoding
  one nothing accepts.

      iex> Rupa.T.union([Rupa.T.integer(), Rupa.T.string()], tag: :none)
      {:union, [{:integer, []}, {:string, []}], [tag: :none]}
  """
  @spec union([term()], keyword()) :: t()
  def union(members, opts \\ []), do: Schema.normalize({:union, members, opts})

  @doc """
  A tagged union — JSON Schema's `oneOf` with a discriminator.

  `tag` is the field holding the branch name. Without `content:` the branches are internally
  tagged, so each one is an object that carries the tag itself; with `content:` they are
  adjacently tagged, serde style, and a branch can be any schema.

  Either way it decodes to `{tag, value}` — `{:circle, %{r: 1.0}}` — with the tag interned
  from the branch name at compile time, so a decoded value is one `case` away from handled.

      iex> Rupa.T.tagged(:type, %{"circle" => %{r: Rupa.T.float()}})
      {:tagged, %{"circle" => {:object, %{r: {:float, []}}, []}}, [tag: :type]}
  """
  @spec tagged(atom(), map(), keyword()) :: t()
  def tagged(tag, branches, opts \\ []) do
    Schema.normalize({:tagged, branches, [{:tag, tag} | opts]})
  end

  @doc """
  A string in `format: :date_time`, RFC 3339's, which decodes to a `DateTime` in UTC.

      iex> Rupa.T.datetime()
      {:string, [format: :date_time]}
  """
  @spec datetime(keyword()) :: t()
  def datetime(opts \\ []), do: formatted(:date_time, opts)

  @doc """
  A string in `format: :date`, which decodes to a `Date`.

      iex> Rupa.T.date()
      {:string, [format: :date]}
  """
  @spec date(keyword()) :: t()
  def date(opts \\ []), do: formatted(:date, opts)

  @doc """
  A string in `format: :time`, RFC 3339's `full-time`, which decodes to a `Time` in UTC. The
  offset is part of the format: `"08:30:00+07:00"` decodes to `~T[01:30:00]`, and `"08:30:00"`
  is an error.

      iex> Rupa.T.time()
      {:string, [format: :time]}
  """
  @spec time(keyword()) :: t()
  def time(opts \\ []), do: formatted(:time, opts)

  @doc """
  A string in `format: :duration`, which decodes to a `Duration`.

      iex> Rupa.T.duration()
      {:string, [format: :duration]}
  """
  @spec duration(keyword()) :: t()
  def duration(opts \\ []), do: formatted(:duration, opts)

  @doc """
  A validated UUID, which stays a string.

      iex> Rupa.T.uuid()
      {:string, [format: :uuid]}
  """
  @spec uuid(keyword()) :: t()
  def uuid(opts \\ []), do: formatted(:uuid, opts)

  @doc """
  A validated email address, which stays a string.

      iex> Rupa.T.email()
      {:string, [format: :email]}
  """
  @spec email(keyword()) :: t()
  def email(opts \\ []), do: formatted(:email, opts)

  @doc """
  A validated URI, which stays a string.

      iex> Rupa.T.uri()
      {:string, [format: :uri]}
  """
  @spec uri(keyword()) :: t()
  def uri(opts \\ []), do: formatted(:uri, opts)

  @doc """
  A validated IPv4 address, which stays a string.

      iex> Rupa.T.ipv4()
      {:string, [format: :ipv4]}
  """
  @spec ipv4(keyword()) :: t()
  def ipv4(opts \\ []), do: formatted(:ipv4, opts)

  @doc """
  A validated IPv6 address, which stays a string.

      iex> Rupa.T.ipv6()
      {:string, [format: :ipv6]}
  """
  @spec ipv6(keyword()) :: t()
  def ipv6(opts \\ []), do: formatted(:ipv6, opts)

  @doc """
  A validated hostname, which stays a string.

      iex> Rupa.T.hostname()
      {:string, [format: :hostname]}
  """
  @spec hostname(keyword()) :: t()
  def hostname(opts \\ []), do: formatted(:hostname, opts)

  defp formatted(format, opts) when is_list(opts) do
    Schema.normalize({:string, Keyword.put(opts, :format, format)})
  end

  defp formatted(_format, opts), do: Schema.normalize({:string, opts})

  @doc """
  Keeps only the named fields of an object.

  These four are honest map work on the field map, so they rewrite the root object: a
  `ref(:root)` anywhere inside now points at the rewritten object, not the original.

      iex> user = %{id: Rupa.T.uuid(), name: Rupa.T.string(), email: Rupa.T.email()}
      iex> Rupa.T.pick(user, [:id])
      {:object, %{id: {:string, [format: :uuid]}}, []}
  """
  @spec pick(term(), [atom()]) :: t()
  def pick(schema, keys) do
    {fields, opts} = fields!(schema, "pick/2")
    known!(fields, keys, "pick/2")
    {:object, Map.take(fields, keys), opts}
  end

  @doc """
  Drops the named fields of an object.

      iex> user = %{id: Rupa.T.uuid(), email: Rupa.T.email()}
      iex> Rupa.T.omit(user, [:email])
      {:object, %{id: {:string, [format: :uuid]}}, []}
  """
  @spec omit(term(), [atom()]) :: t()
  def omit(schema, keys) do
    {fields, opts} = fields!(schema, "omit/2")
    known!(fields, keys, "omit/2")
    {:object, Map.drop(fields, keys), opts}
  end

  @doc """
  Makes every field of an object optional, one level deep.

  A field that already carries `default:` is left alone: it was never required.

      iex> Rupa.T.partial(%{name: Rupa.T.string(), age: Rupa.T.integer(default: 0)})
      {:object, %{name: {:optional, {:string, []}, []}, age: {:integer, [default: 0]}}, []}
  """
  @spec partial(term()) :: t()
  def partial(schema) do
    {fields, opts} = fields!(schema, "partial/1")
    {:object, Map.new(fields, fn {key, value} -> {key, loosen(value)} end), opts}
  end

  @doc """
  Merges two objects. The right-hand side wins on both fields and options.

  `defs:` entries are merged rather than replaced, and two entries of the same name with
  different schemas raise.

      iex> Rupa.T.merge(%{a: Rupa.T.string()}, %{b: Rupa.T.integer()})
      {:object, %{a: {:string, []}, b: {:integer, []}}, []}
  """
  @spec merge(term(), term()) :: t()
  def merge(left, right) do
    {left_fields, left_opts} = fields!(left, "merge/2")
    {right_fields, right_opts} = fields!(right, "merge/2")

    {:object, Map.merge(left_fields, right_fields), merge_opts(left_opts, right_opts)}
  end

  defp fields!(schema, called) do
    case Schema.normalize(schema) do
      {:object, fields, opts} when is_map(fields) and is_list(opts) ->
        if Keyword.keyword?(opts) do
          {fields, opts}
        else
          raise ArgumentError, "#{called} got an object whose options are not a keyword list"
        end

      other ->
        raise ArgumentError, "#{called} expects an object, got #{inspect(other)}"
    end
  end

  defp known!(fields, keys, called) do
    case Enum.reject(keys, &Map.has_key?(fields, &1)) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "#{called} names #{inspect(missing)}, which the object does not have"
    end
  end

  defp loosen({:optional, _inner, _opts} = already), do: already

  defp loosen(schema) do
    if defaulted?(schema), do: schema, else: wrap(schema)
  end

  # `from:` and `to:` belong on the field's own term, so wrapping a field carries them out to
  # the wrapper rather than burying them under it.
  defp wrap({kind, opts}) when is_list(opts), do: lift(opts, &{kind, &1})
  defp wrap({kind, payload, opts}) when is_list(opts), do: lift(opts, &{kind, payload, &1})
  defp wrap(schema), do: {:optional, schema, []}

  defp lift(opts, rebuild) do
    {moved, kept} = Enum.split_with(opts, &rename?/1)
    {:optional, rebuild.(kept), moved}
  end

  defp rename?({key, _value}) when key in [:from, :to], do: true
  defp rename?(_entry), do: false

  defp defaulted?({_kind, opts}) when is_list(opts), do: Keyword.has_key?(opts, :default)

  defp defaulted?({_kind, _payload, opts}) when is_list(opts) do
    Keyword.has_key?(opts, :default)
  end

  defp defaulted?(_schema), do: false

  defp merge_opts(left, right) do
    merged = Keyword.merge(left, right)

    case {Keyword.get(left, :defs), Keyword.get(right, :defs)} do
      {nil, _any} -> Enum.sort_by(merged, &elem(&1, 0))
      {_any, nil} -> Enum.sort_by(merged, &elem(&1, 0))
      {left_defs, right_defs} -> put_defs(merged, left_defs, right_defs)
    end
  end

  defp put_defs(merged, left_defs, right_defs) do
    Enum.each(left_defs, fn {name, schema} ->
      case Map.fetch(right_defs, name) do
        {:ok, ^schema} -> :ok
        :error -> :ok
        {:ok, _other} -> raise ArgumentError, "merge/2 got two defs named #{inspect(name)}"
      end
    end)

    merged
    |> Keyword.put(:defs, Map.merge(left_defs, right_defs))
    |> Enum.sort_by(&elem(&1, 0))
  end
end

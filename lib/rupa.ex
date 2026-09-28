defmodule Rupa do
  @moduledoc """
  A macro-less, serde-like schema library for Elixir.

  A schema is a plain term. There are no macros, and no functions inside a schema either, so a
  schema prints, hashes with `:erlang.phash2/1`, composes at runtime, and round-trips through
  JSON Schema. `compile/1` stages a schema once into an executable codec; `decode/3` runs it.

      iex> codec = Rupa.compile!(%{name: Rupa.T.string(min: 1), age: Rupa.T.integer(gte: 0)})
      iex> Rupa.decode(codec, %{"name" => "Ada", "age" => 40})
      {:ok, %{name: "Ada", age: 40}}

  The vocabulary is JSON Schema's declarative subset and nothing more. Refinements, transforms
  and custom codecs are deliberately absent: domain conversion is a plain function you call on
  the decoded value.

  ## Where to start

    * `Rupa.T` — the constructors, and the table of what each kind takes.
    * `Rupa.Schema` — what a schema term is, `Rupa.Schema.validate/1`, and the rule for
      present, absent and null.
    * `Rupa.IR` and `explain/1` — what staging turned your schema into.
    * `Rupa.Error` — the shape every error takes.
    * `Rupa.Json` — `decode_json/3` and `encode_json/3`, and which of them fuses.
    * `Rupa.JsonSchema` — the same schema as a draft 2020-12 document, and back.
    * `mix rupa.gen.struct` — the struct modules `into:` names, written from the schema.

  ## Wire data is string-keyed

  `decode/3` reads string keys, because that is what a JSON document has, and returns atom
  keys interned from the schema at compile time. A key the schema does not name is never
  converted to an atom, so there is no way to exhaust the atom table with wire data.

  The two sides are named separately: `rename_all:`, `from:` and `to:` say what the wire calls
  a field, `keys:` says whether the decoded map is keyed by atoms or strings, and all four are
  spent at compile time. `Rupa.Schema` has the rule.

  ## Two backends, one IR

  `compile(schema)` returns a closure tree, which is what you want for a schema you did not
  know at boot. `compile(schema, as: MyApp.Codecs.User)` generates a module, which is what you
  want for one you did. Both are staged by the same pass, and both decode and encode to the
  same value — the test suite asserts that on every case it has — so the choice is about cost,
  not behaviour.

  ## Unions decode to a tagged tuple

  `Rupa.T.tagged/3` gives you `{:circle, %{r: 1.0}}` — the tag as an atom interned from the
  schema, the branch decoded beside it — so a `case` on a decoded value is one clause per
  branch. It is the same shape whether the tag travels inside the branch's own object or in an
  envelope beside it, and `Rupa.T.union/2` is the untagged version you have to ask for.

  ## JSON is a first-class edge

  `decode_json/3` takes text, `encode_json/3` writes it. Encoding fuses — one walk of your
  value, straight to iodata, with no wire map in between — and decoding does not, because
  `:json`'s callbacks will not say which field a value belongs to until after it is built.
  `Rupa.Json` has the reading of the API that this rests on.

  ## Objects can decode into structs

  `Rupa.T.object(%{...}, into: MyApp.User)` decodes that object into a struct, and it is an
  option on the object rather than on the compile, so nesting works: an address three levels
  down becomes a `MyApp.Address`. `Rupa.Schema` has what it cannot hold with — a struct has atom
  keys and every one of them always — and `mix rupa.gen.struct` writes the modules from the
  schema.

  ## Status

  0.1.0 is the first release: the whole vocabulary compiles on both backends, JSON goes in and
  out, so does JSON Schema, objects decode into structs, and every string format agrees with
  JSON Schema's official format corpus.
  """

  alias Rupa.Codec
  alias Rupa.Codegen
  alias Rupa.Error
  alias Rupa.Explain
  alias Rupa.Json
  alias Rupa.Schema
  alias Rupa.Stage

  @modes [:halt, :collect]

  @typedoc "A compiled codec: the closure tree, or the name of a generated module."
  @type codec :: Codec.t() | module()

  @doc """
  Validates and stages a schema, then builds a codec from it.

      iex> {:ok, codec} = Rupa.compile(%{id: Rupa.T.uuid()})
      iex> Rupa.valid?(codec, %{"id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8"})
      true

      iex> {:error, [error]} = Rupa.compile(%{id: Rupa.T.string(format: :ssn)})
      iex> error.code
      :unknown_format

  ## `as:` — a codec compiled into a module

  `as: MyApp.Codecs.User` generates and loads a module, and returns its name. That is the
  faster backend, and it is what a schema you know at boot deserves:

      def start(_type, _args) do
        {:ok, _} = Rupa.compile(MyApp.Schemas.user(), as: MyApp.Codecs.User)
        ...
      end

  The module is a handle, not an API: reach it through `decode/3`, never by calling it.

  Compiling the same name with the same schema is a lookup, not a recompile — the module
  carries the schema it was built from, and reuse compares it exactly (a hash gates the
  comparison, it does not stand in for it). Compiling it with a *different* schema returns
  `:already_compiled` rather than swapping the codec under code that is already using it;
  `force: true` replaces it, and is for dev and test.

  Compiles are serialised per name with `:global.trans/2`, so two processes racing on one name
  produce one module. That needs no process of its own, which is why Rupa has nothing to start
  and nothing in your supervision tree.

  ## Generated codecs and releases

  A generated module exists because something called this function, so it is not in your
  release's module list and a release upgrade does not carry it. Compile your codecs in your
  application's start callback and the new node builds them for itself.

  On a live upgrade, `force: true` uses `:code.soft_purge/1`: if a process is still running
  the old codec, the replacement is refused with `:codec_in_use` and nothing changes. Rupa
  never calls `:code.purge/1`, so it will not kill a process to load a codec.
  """
  @spec compile(term(), keyword()) :: {:ok, codec()} | {:error, [Error.t()]}
  def compile(schema, opts \\ [])

  def compile(schema, opts) do
    with {:ok, program} <- Stage.run(schema) do
      normalised = Schema.normalize(schema)

      case Keyword.fetch(opts, :as) do
        :error ->
          {:ok, Codec.new(normalised, program)}

        {:ok, name} when is_atom(name) and not is_nil(name) and not is_boolean(name) ->
          define(name, normalised, program, opts)

        {:ok, other} ->
          raise ArgumentError, "as: expects a module name, got #{inspect(other)}"
      end
    end
  end

  @doc """
  `compile/1`, raising `Rupa.SchemaError` instead of returning errors.

      iex> Rupa.compile!(%{}) |> Rupa.decode(%{})
      {:ok, %{}}
  """
  @spec compile!(term(), keyword()) :: codec()
  def compile!(schema, opts \\ []) do
    case compile(schema, opts) do
      {:ok, codec} -> codec
      {:error, errors} -> raise Rupa.SchemaError, errors: errors
    end
  end

  @doc """
  Decodes wire data against a codec.

  `on_error:` is `:halt` by default, which stops at the first error — the cheap case, and the
  one most callers want. `:collect` keeps going and reports every field that failed. Either
  way the failure is a list, so there is one shape to match on.

      iex> codec = Rupa.compile!(%{a: Rupa.T.integer(), b: Rupa.T.integer()})
      iex> {:error, errors} = Rupa.decode(codec, %{"a" => "x"}, on_error: :collect)
      iex> Enum.map(errors, &{&1.path, &1.code})
      [{[:a], :type}, {[:b], :required}]

      iex> codec = Rupa.compile!(%{a: Rupa.T.integer(), b: Rupa.T.integer()})
      iex> {:error, errors} = Rupa.decode(codec, %{"a" => "x"})
      iex> length(errors)
      1
  """
  @spec decode(codec(), term(), keyword()) :: {:ok, term()} | {:error, [Error.t()]}
  def decode(codec, data, opts \\ [])

  def decode(%Codec{decode: decode, defs: defs}, data, opts) do
    decode.(data, {mode!(opts), defs})
  end

  def decode(module, data, opts) when is_atom(module) do
    module.__rupa_decode__(data, mode!(opts))
  end

  @doc """
  `decode/3`, raising `Rupa.DecodeError` instead of returning errors.

      iex> codec = Rupa.compile!(%{name: Rupa.T.string()})
      iex> Rupa.decode!(codec, %{"name" => "Ada"})
      %{name: "Ada"}
  """
  @spec decode!(codec(), term(), keyword()) :: term()
  def decode!(codec, data, opts \\ []) do
    case decode(codec, data, opts) do
      {:ok, decoded} -> decoded
      {:error, errors} -> raise Rupa.DecodeError, errors: errors
    end
  end

  @doc """
  Encodes a decoded value back to wire data.

  The inverse of `decode/3`, and inverse is meant literally: what this produces, `decode/3`
  accepts, and it gives back what you started with. It checks types and formats — the things it
  has to look at anyway to turn a `DateTime` back into a string and an atom back into its wire
  value — and does not re-run constraints, which decoding already bought.

      iex> codec = Rupa.compile!(%{at: Rupa.T.datetime(), role: Rupa.T.enum([:admin])})
      iex> Rupa.encode(codec, %{at: ~U[2026-09-16 10:00:00Z], role: :admin})
      {:ok, %{"at" => "2026-09-16T10:00:00Z", "role" => "admin"}}

      iex> codec = Rupa.compile!(%{at: Rupa.T.datetime()})
      iex> {:error, [error]} = Rupa.encode(codec, %{at: "already a string"})
      iex> {error.path, error.code}
      {[:at], :format}
  """
  @spec encode(codec(), term(), keyword()) :: {:ok, term()} | {:error, [Error.t()]}
  def encode(codec, value, opts \\ [])

  def encode(%Codec{encode: encode, encode_defs: defs}, value, opts) do
    encode.(value, {mode!(opts), defs})
  end

  def encode(module, value, opts) when is_atom(module) do
    module.__rupa_encode__(value, mode!(opts))
  end

  @doc """
  `encode/3`, raising `Rupa.EncodeError` instead of returning errors.

      iex> codec = Rupa.compile!(%{n: Rupa.T.integer()})
      iex> Rupa.encode!(codec, %{n: 1})
      %{"n" => 1}
  """
  @spec encode!(codec(), term(), keyword()) :: term()
  def encode!(codec, value, opts \\ []) do
    case encode(codec, value, opts) do
      {:ok, wire} -> wire
      {:error, errors} -> raise Rupa.EncodeError, errors: errors
    end
  end

  @doc """
  Parses JSON text and decodes it against a codec.

  What the name promises and no more: `:json.decode/3` builds the term, `decode/3` checks and
  converts it. Object fields cannot be schema-directed while parsing — a value's key does not
  reach `:json`'s callbacks until after that value is built — so there is no one-pass version to
  ship here, and `Rupa.Json` says what it would take. `mix run bench/json.exs` is the number.

      iex> codec = Rupa.compile!(%{name: Rupa.T.string(), tags: Rupa.T.list(Rupa.T.string())})
      iex> Rupa.decode_json(codec, ~s({"name": "Ada", "tags": ["a"]}))
      {:ok, %{name: "Ada", tags: ["a"]}}

  Text that is not JSON is an error like any other, rather than a raise:

      iex> {:error, [error]} = Rupa.decode_json(Rupa.compile!(%{}), "{oops")
      iex> {error.code, Rupa.Error.message(error)}
      {:json, "invalid JSON: unexpected byte 0x6F"}
  """
  @spec decode_json(codec(), binary(), keyword()) :: {:ok, term()} | {:error, [Error.t()]}
  def decode_json(codec, text, opts \\ []) do
    with {:ok, parsed} <- Json.parse(text), do: decode(codec, parsed, opts)
  end

  @doc """
  `decode_json/3`, raising `Rupa.DecodeError` instead of returning errors.

      iex> Rupa.decode_json!(Rupa.compile!(%{n: Rupa.T.integer()}), ~s({"n": 1}))
      %{n: 1}
  """
  @spec decode_json!(codec(), binary(), keyword()) :: term()
  def decode_json!(codec, text, opts \\ []) do
    case decode_json(codec, text, opts) do
      {:ok, decoded} -> decoded
      {:error, errors} -> raise Rupa.DecodeError, errors: errors
    end
  end

  @doc """
  Encodes a decoded value straight to JSON iodata.

  `encode/3` followed by a JSON encoder builds a wire map and then walks it. This builds
  nothing: the staged program emits the bytes as it walks the value you already have. Wire keys,
  enum values and a tagged branch's `"type":"circle"` were rendered to binaries when the schema
  was staged, so what is left is escaping your strings.

  The result is iodata, which is what you hand a socket or a `Plug.Conn`.
  `IO.iodata_to_binary/1` flattens it if you want a binary.

      iex> codec = Rupa.compile!(%{at: Rupa.T.datetime(), n: Rupa.T.integer()})
      iex> codec |> Rupa.encode_json!(%{at: ~U[2026-09-16 10:00:00Z], n: 1}) |> to_string()
      ~s({"at":"2026-09-16T10:00:00Z","n":1})

  Fields come out in the schema's own order, which is one visible difference from going through
  `encode/3` — a map has its own idea of order and the schema's is the more useful one. What it
  checks is what `encode/3` checks, and the errors are the same errors:

      iex> codec = Rupa.compile!(%{n: Rupa.T.integer()})
      iex> {:error, [error]} = Rupa.encode_json(codec, %{n: "one"})
      iex> {error.path, error.code}
      {[:n], :type}

  Plus what JSON text itself cannot carry, which a term can: a string that is not UTF-8 is
  `:invalid_utf8`; a `map_of` key or kept extra with no string form (a tuple, say) is
  `:unsupported_key`, and a kept value with no JSON form `:unsupported_value`; and two keys that
  render to one object name — `1` beside `"1"`, `:a` beside `"a"` — are `:duplicate_key` rather
  than an object that carries the name twice. All with the path to the offending key.
  """
  @spec encode_json(codec(), term(), keyword()) :: {:ok, iodata()} | {:error, [Error.t()]}
  def encode_json(codec, value, opts \\ [])

  def encode_json(%Codec{json: json, json_defs: defs}, value, opts) do
    json.(value, {mode!(opts), defs})
  end

  def encode_json(module, value, opts) when is_atom(module) do
    module.__rupa_encode_json__(value, mode!(opts))
  end

  @doc """
  `encode_json/3`, raising `Rupa.EncodeError` instead of returning errors.

      iex> Rupa.compile!(%{n: Rupa.T.integer()}) |> Rupa.encode_json!(%{n: 1}) |> to_string()
      ~s({"n":1})
  """
  @spec encode_json!(codec(), term(), keyword()) :: iodata()
  def encode_json!(codec, value, opts \\ []) do
    case encode_json(codec, value, opts) do
      {:ok, iodata} -> iodata
      {:error, errors} -> raise Rupa.EncodeError, errors: errors
    end
  end

  @doc """
  Whether the data decodes, without you having to look at why.

      iex> codec = Rupa.compile!(%{name: Rupa.T.string()})
      iex> {Rupa.valid?(codec, %{"name" => "Ada"}), Rupa.valid?(codec, %{})}
      {true, false}
  """
  @spec valid?(codec(), term()) :: boolean()
  def valid?(codec, data), do: match?({:ok, _decoded}, decode(codec, data))

  @doc """
  Prints what staging turned the schema into — the thing a macro can never give you.

  Takes a codec or a schema.

      iex> Rupa.explain(%{tags: Rupa.T.list(Rupa.T.string(min: 1), max: 5)})
      ~s[object (1 field, unknown: strip)\\n  "tags" -> :tags list max=5 of\\n    string min=1]
  """
  @spec explain(codec() | term()) :: String.t()
  def explain(%Codec{program: program}), do: Explain.render(program)

  def explain(module) when is_atom(module) do
    if generated?(module) do
      Explain.render(module.__rupa__(:program))
    else
      staged(module)
    end
  end

  def explain(schema), do: staged(schema)

  defp staged(schema) do
    case Stage.run(schema) do
      {:ok, program} -> Explain.render(program)
      {:error, errors} -> raise Rupa.SchemaError, errors: errors
    end
  end

  # =============================================
  # Named codecs
  # =============================================

  # Serialised on the name, and on nothing else. `:global.trans/2` needs no process, so Rupa
  # stays a library with nothing to start and nothing in your supervision tree; the cost is a
  # round of negotiation on a connected cluster, against a compile that already costs more.
  defp define(name, schema, program, opts) do
    hash = :erlang.phash2(schema)

    :global.trans({{__MODULE__, name}, self()}, fn ->
      cond do
        # The hash is a cheap gate; the exact schema is what decides. Two schemas that collide on
        # phash2 (27 bits by default) must not share a codec, so `===` has the final say -- and it
        # only runs when the hash already matched, so the common lookup pays one integer compare.
        generated?(name) and name.__rupa__(:hash) == hash and name.__rupa__(:schema) === schema ->
          {:ok, name}

        generated?(name) ->
          replace(name, schema, program, opts)

        Code.ensure_loaded?(name) ->
          {:error, [Error.new([], :name_taken, %{name: name})]}

        true ->
          load(name, schema, program)
      end
    end)
  end

  defp replace(name, schema, program, opts) do
    cond do
      not Keyword.get(opts, :force, false) ->
        {:error, [Error.new([], :already_compiled, %{name: name})]}

      not :code.soft_purge(name) ->
        {:error, [Error.new([], :codec_in_use, %{name: name})]}

      true ->
        previous = Code.get_compiler_option(:ignore_module_conflict)
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          load(name, schema, program)
        after
          Code.put_compiler_option(:ignore_module_conflict, previous)
        end
    end
  end

  # Elixir's type checker reads the generated module like any other, and what it finds is
  # reported by the generated module's internal function names into whatever console is
  # attached -- in production, the application's boot log, where `defp d17/2 is never used` is
  # a sentence nobody can act on. So the compile happens inside `Code.with_diagnostics/1` and
  # each finding is said again in terms of the schema it came from. Nothing is dropped: Rupa's
  # own dead clauses have been real bugs three milestones running, and a warning the schema
  # earns is one its author wants.
  defp load(name, schema, program) do
    {ast, index} = Codegen.module(name, program, schema)
    {_modules, diagnostics} = Code.with_diagnostics(fn -> Code.compile_quoted(ast) end)

    warn_diagnostics(diagnostics, name, index)
    {:ok, name}
  end

  # Public only so it can be tested directly: no schema in the current vocabulary reliably makes
  # the type checker flag generated code (untagged-union branch selection moved to a runtime
  # helper for exactly that reason -- the checker cannot see a round-trip and so misjudged
  # disjoint unions). It stays as a safety net: a future node kind that emits genuinely dead code
  # would be re-said here in the schema's terms rather than as `defp d17/2 is never used` in a
  # boot log. One `IO.warn` for the compile, not one per finding -- a schema that earns any of
  # these usually earns several and the closing paragraph should be said once.
  @doc false
  @spec warn_diagnostics([%{message: String.t()}], module(), %{String.t() => atom()}) :: :ok
  def warn_diagnostics([], _name, _index), do: :ok

  def warn_diagnostics(diagnostics, name, index) do
    IO.warn(
      """
      #{inspect(name)}: the compiler found this in the codec Rupa generated from your schema.

      #{Enum.map_join(diagnostics, "\n\n", &finding(&1, index))}

      The function names above are Rupa's rather than yours, because that code was generated. \
      `Rupa.explain(#{inspect(name)})` prints the staged program those functions came from. \
      The usual cause is an untagged union whose earlier variant already accepts everything a \
      later one does, which leaves the later one unreachable.\
      """,
      []
    )
  end

  defp finding(%{message: message}, index) do
    "  * in #{Codegen.attribute(message, index)}:\n\n" <> indent(message)
  end

  defp indent(message) do
    message
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> "        " <> line
    end)
    |> String.trim_trailing()
  end

  defp generated?(name) do
    Code.ensure_loaded?(name) and function_exported?(name, :__rupa__, 1)
  end

  defp mode!(opts) do
    case Keyword.get(opts, :on_error, :halt) do
      mode when mode in @modes ->
        mode

      other ->
        raise ArgumentError, "on_error: expects :halt or :collect, got #{inspect(other)}"
    end
  end
end

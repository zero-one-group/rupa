defmodule Rupa.Codegen do
  @moduledoc """
  The module backend: `Rupa.IR` in, the AST of a module out.

  Same IR as `Rupa.Closure`, so a feature is written once and both backends get it. What
  changes is what the work costs. A closure reads its constants out of an environment and
  reaches the next node through an indirect call. Generated code has the constants as
  literals, calls the next node directly, and tests a scalar field's type and bounds inline —
  so the common case, a field that is present and valid, allocates nothing at all and the
  `{:ok, value}` wrapper never gets built.

  Three things follow from generating at runtime rather than at build time:

    * a compiled `pattern` regex is embedded as a literal, because the OTP that compiled it is
      the OTP about to run it — the version skew that would make that unsafe in a release
      cannot happen here
    * recursion needs no table: a ref is a direct call to the function generated for that
      definition, so the one lookup the closure backend does goes away
    * the module is not part of your release. `Rupa.compile/2` says what that means.

  The generated module is a handle, not an API. Everything reaches it through `Rupa.decode/3`,
  and `ctx` here is just the mode — `:halt` or `:collect`.
  """

  alias Rupa.IR
  alias Rupa.Json

  # The largest and smallest finite IEEE-754 double, mirrored from `Rupa.Closure`: a JSON integer
  # outside this range is a number the `value * 1.0` coercion cannot represent, so the generated
  # type test excludes it and it becomes a type error rather than an `ArithmeticError`.
  @float_max 1.7976931348623157e308
  @float_min -1.7976931348623157e308

  @typedoc "Which of the three walks generated a function."
  @type direction :: :decode | :encode | :encode_json

  @doc """
  Builds the module AST for a staged program, and the index of which walk wrote what.

  The schema is embedded so the module can say what it was built from, and hashed so a repeat
  compile under the same name is a lookup rather than a recompile. The index is how
  `Rupa.compile/2` turns a compiler diagnostic about `d17/2` back into a sentence: it names
  every function this module generated, so a message can be told from an ordinary word.

  `Rupa.compile/2` with `as:` is the way in; this only builds the AST, and compiling it is the
  caller's job:

      schema = %{name: Rupa.T.string()}
      {:ok, program} = Rupa.Stage.run(schema)
      {ast, index} = Rupa.Codegen.module(MyApp.Codecs.User, program, schema)
      index["d0"]
      #=> :decode
  """
  @spec module(module(), IR.program(), term()) :: {Macro.t(), %{String.t() => direction()}}
  def module(name, program, schema) do
    {decode, decode_funs, decode_index, _reached} = walk(program, "d", "ref", :decode, &node/2)

    {encode, encode_funs, encode_index, reached_e} =
      walk(program, "e", "eref", :encode, &enc_node/2)

    {json, json_funs, json_index, reached_j} =
      walk(program, "j", "jref", :encode_json, &json_node/2)

    {verify_funs, verify_index} = verify_walk(program, MapSet.union(reached_e, reached_j))

    ast =
      quote do
        defmodule unquote(name) do
          @moduledoc false

          def __rupa__(:hash), do: unquote(:erlang.phash2(schema))
          def __rupa__(:schema), do: unquote(Macro.escape(schema))
          def __rupa__(:program), do: unquote(Macro.escape(program))

          def __rupa_decode__(value, ctx), do: unquote(decode)(value, ctx)
          def __rupa_encode__(value, ctx), do: unquote(encode)(value, ctx)
          def __rupa_encode_json__(value, ctx), do: unquote(json)(value, ctx)

          unquote_splicing(decode_funs ++ encode_funs ++ json_funs ++ verify_funs)
        end
      end

    index =
      decode_index
      |> Map.merge(encode_index)
      |> Map.merge(json_index)
      |> Map.merge(verify_index)

    {ast, index}
  end

  @doc """
  What a compiler diagnostic about generated code is talking about, in words.

  Which name a message is about is not worth a grammar: the generated names are `d0`, `e7`,
  `jref_node` and nothing an ordinary sentence would contain, so the first identifier the index
  knows is the one being discussed. A message naming none of them is described in general
  rather than guessed at.

      iex> {:ok, program} = Rupa.Stage.run(%{name: Rupa.T.string()})
      iex> {_ast, index} = Rupa.Codegen.module(MyApp.Codecs.Named, program, %{})
      iex> Rupa.Codegen.attribute("this clause of defp e1/2 is never used", index)
      "the encoder it generated"

      iex> Rupa.Codegen.attribute("something about nothing in particular", %{})
      "the codec it generated"
  """
  @spec attribute(String.t(), %{String.t() => direction()}) :: String.t()
  def attribute(message, index) do
    ~r/[a-z][a-z0-9_]*/
    |> Regex.scan(message)
    |> Enum.find_value(fn [token] -> Map.get(index, token) end)
    |> reads()
  end

  defp reads(:decode), do: "the decoder it generated"
  defp reads(:encode), do: "the encoder it generated"
  defp reads(:encode_json), do: "the JSON encoder it generated"
  defp reads(nil), do: "the codec it generated"

  # One walk per direction. Each definition gets a named alias first, so a recursive ref is a
  # direct call to a function that exists by the time anything needs it.
  #
  # The index falls out of the counter for nothing, because every name a walk mints is this
  # prefix and a number below where it stopped. What it is *not* is a map from a function to a
  # node in the schema: that would mean threading a path through every clause of three
  # generators, which is a great deal of churn in the most delicate file here -- and it would
  # buy less than it sounds, since a definition only survives staging when it is recursive and
  # the type checker does not report inside a recursive group at all.
  defp walk(program, prefix, ref_prefix, direction, generate) do
    refs = Map.new(program.defs, fn {name, _ir} -> {name, :"#{ref_prefix}_#{name}"} end)
    state = Enum.reduce(program.defs, empty(prefix, refs), &define(&1, &2, generate))
    {root, state} = generate.(program.root, state)

    {root, Enum.reverse(state.funs), index(state, refs, direction), state.reached}
  end

  defp empty(prefix, refs) do
    %{counter: 0, funs: [], refs: refs, prefix: prefix, verify: %{}, reached: MapSet.new()}
  end

  defp define({name, ir}, state, generate) do
    {fun, state} = generate.(ir, state)
    alias_name = Map.fetch!(state.refs, name)

    add(state, quote(do: defp(unquote(alias_name)(value, ctx), do: unquote(fun)(value, ctx))))
  end

  # The decode walk a union verifier resolves its refs to. It reads the *symmetric* copy of each
  # definition (see `verifier/2`), so it is a fourth walk rather than the decode walk's aliases --
  # and it holds only the definitions a verifier actually reached, plus whatever those reach in
  # turn, because a private function nothing calls is a compiler warning in the generated module.
  # Most schemas have no untagged union under a recursive definition and generate nothing here.
  defp verify_walk(_program, reached) when map_size(reached.map) == 0, do: {[], %{}}

  defp verify_walk(program, reached) do
    symmetric = IR.Rewrite.symmetric_program(program).defs
    refs = Map.new(symmetric, fn {name, _ir} -> {name, :"vref_#{name}"} end)
    state = verify_defs(MapSet.to_list(reached), symmetric, empty("v", refs), reached)
    defined = Map.take(refs, MapSet.to_list(state.reached))

    {Enum.reverse(state.funs), index(state, defined, :decode)}
  end

  defp verify_defs([], _symmetric, state, done), do: %{state | reached: done}

  defp verify_defs([name | rest], symmetric, state, done) do
    state = define({name, Map.fetch!(symmetric, name)}, %{state | reached: MapSet.new()}, &node/2)
    new = MapSet.difference(state.reached, done)

    verify_defs(rest ++ MapSet.to_list(new), symmetric, state, MapSet.union(done, new))
  end

  defp index(state, refs, direction) do
    minted = for n <- 0..(state.counter - 1)//1, do: "#{state.prefix}#{n}"

    Enum.into(
      Map.values(refs),
      Map.new(minted, &{&1, direction}),
      &{Atom.to_string(&1), direction}
    )
  end

  # =============================================
  # Nodes
  # =============================================

  # Every ref the decode generator meets is recorded: inside a union verifier that is what says
  # which definitions `verify_walk/2` has to generate. The plain decode walk ignores the record.
  defp node(%IR.Ref{name: ref}, state) do
    {Map.fetch!(state.refs, ref), %{state | reached: MapSet.put(state.reached, ref)}}
  end

  defp node(%IR.Scalar{} = scalar, state) do
    {name, state} = fresh(state)
    body = scalar_body(scalar, value())

    {name, add(state, quote(do: defp(unquote(name)(value, _ctx), do: unquote(body))))}
  end

  defp node(%IR.Const{lookup: lookup, values: values}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) do
          case unquote(Macro.escape(lookup)) do
            %{^value => decoded} ->
              {:ok, decoded}

            _ ->
              unquote(err(:const, quote(do: %{value: value, allowed: unquote(escape(values))})))
          end
        end
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Nullable{of: inner}, state) do
    {inner_name, state} = node(inner, state)
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(nil, _ctx), do: {:ok, nil}
        defp unquote(name)(value, ctx), do: unquote(inner_name)(value, ctx)
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Array{of: inner, checks: checks}, state) do
    {inner_name, state} = node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    {check_unique, bounds} = Keyword.pop(checks, :unique, false)

    # min/max are length checks and decoding never drops an element, so they run on the input.
    # Uniqueness is of the *decoded* values -- two wire elements that differ only where decoding
    # discards collapse to one -- so it runs on `each`'s result.
    decoded = array_unique(check_unique, quote(do: unquote(each)(value, 0, ctx, [], [])))

    body =
      Enum.reduce(Enum.reverse(bounds), decoded, fn check, acc -> array_check(check, acc) end)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_list(value) and length(value) >= 0,
          do: unquote(body)

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :array, value: value})))

        defp unquote(each)([], _index, _ctx, acc, []), do: {:ok, :lists.reverse(acc)}
        defp unquote(each)([], _index, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}

        defp unquote(each)([item | rest], index, ctx, acc, errors) do
          case unquote(inner_name)(item, ctx) do
            {:ok, decoded} ->
              unquote(each)(rest, index + 1, ctx, [decoded | acc], errors)

            {:error, found} ->
              errors = Rupa.Codegen.stack(found, index, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, index + 1, ctx, acc, errors)
          end
        end
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Dict{of: inner}, state) do
    {inner_name, state} = node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_map(value) do
          unquote(each)(:lists.sort(:maps.to_list(value)), ctx, [], [])
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))

        defp unquote(each)([], _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
        defp unquote(each)([], _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}

        defp unquote(each)([{key, item} | rest], ctx, acc, errors) do
          case unquote(inner_name)(item, ctx) do
            {:ok, decoded} ->
              unquote(each)(rest, ctx, [{key, decoded} | acc], errors)

            {:error, found} ->
              errors = Rupa.Codegen.stack(found, key, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, ctx, acc, errors)
          end
        end
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Fixed{members: []}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)([], _ctx), do: {:ok, {}}

        defp unquote(name)(value, _ctx) when is_list(value) and length(value) >= 0 do
          unquote(err(:tuple_size, quote(do: %{expected: 0, actual: length(value)})))
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :array, value: value})))
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Fixed{members: members}, state) do
    {inner, state} = Enum.map_reduce(members, state, &node/2)
    {name, state} = fresh(state)
    {steps, state} = Enum.map_reduce(inner, state, fn _ir, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    size = length(members)
    entry = List.first(steps ++ [done])

    positions =
      [inner, steps, Enum.drop(steps, 1) ++ [done], 0..max(size - 1, 0)]
      |> Enum.zip()
      |> Enum.map(&member_fun/1)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_list(value) and length(value) == unquote(size) do
          unquote(entry)(value, ctx, [], [])
        end

        defp unquote(name)(value, _ctx) when is_list(value) and length(value) >= 0 do
          unquote(err(:tuple_size, quote(do: %{expected: unquote(size), actual: length(value)})))
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :array, value: value})))

        unquote_splicing(positions)

        defp unquote(done)([], _ctx, acc, []) do
          {:ok, acc |> :lists.reverse() |> List.to_tuple()}
        end

        defp unquote(done)([], _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Union{members: members}, state) do
    {inner, state} = Enum.map_reduce(members, state, &node/2)
    {name, state} = fresh(state)

    {name, add(state, union_fun(name, inner, length(members)))}
  end

  defp node(%IR.Tagged{} = tagged, state) do
    {inner, state} =
      Enum.map_reduce(tagged.branches, state, fn one, acc -> branch_node(tagged, one, acc) end)

    {name, state} = fresh(state)

    clauses =
      [tagged.branches, inner]
      |> Enum.zip()
      |> Enum.map(fn {one, fun} ->
        {:->, [], [[tag_pattern(tagged, one)], tag_body(tagged, one, fun)]}
      end)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_map(value) do
          unquote({:case, [], [quote(do: value), [do: clauses ++ tag_fallbacks(tagged)]]})
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))
      end

    {name, add(state, fun)}
  end

  defp node(%IR.Object{} = object, state), do: object_node(object, state, :any)

  # `known` is what the caller has already proved about the value. `:any` is the ordinary case
  # and pays for a type check; `:map` is a tagged union's branch, reached only through a head
  # match that has matched a map already -- generating its "not an object" clause there is dead
  # code, and Elixir's type checker says so in the middle of someone's boot log.
  defp object_node(%IR.Object{fields: [], unknown: unknown, into: into}, state, known) do
    {name, state} = fresh(state)
    clauses = object_head(name, empty_body(unknown, base(into)), known)

    {name, add(state, quote(do: (unquote_splicing(clauses))))}
  end

  defp object_node(%IR.Object{fields: fields, unknown: unknown, into: into}, state, known) do
    {name, state} = fresh(state)
    {inner, state} = Enum.map_reduce(fields, state, fn field, acc -> node(field.ir, acc) end)
    {steps, state} = Enum.map_reduce(fields, state, fn _field, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    entry = List.first(steps ++ [done])
    base = base(into)

    field_funs =
      [fields, inner, steps, Enum.drop(steps, 1) ++ [done]]
      |> Enum.zip()
      |> Enum.map(&field_fun/1)

    fun =
      quote do
        unquote_splicing(fast_clause(name, fields, inner, unknown, entry, into))

        unquote_splicing(object_head(name, quote(do: unquote(entry)(value, ctx, [], [])), known))

        unquote_splicing(field_funs)

        defp unquote(done)(value, ctx, acc, []), do: unquote(done_body(unknown, fields, base))
        defp unquote(done)(_value, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  # The base a struct's missing keys come from, resolved while the module is being built and
  # embedded as a map literal -- so `into:` costs one merge at run time and no lookup at all.
  defp base(nil), do: nil
  defp base(module), do: escape(module.__struct__())

  defp object_head(name, body, :map) do
    [quote(do: defp(unquote(name)(value, ctx), do: unquote(body)))]
  end

  defp object_head(name, body, :any) do
    [
      quote(do: defp(unquote(name)(value, ctx) when is_map(value), do: unquote(body))),
      quote do
        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))
      end
    ]
  end

  defp empty_body(:strip, nil), do: quote(do: {:ok, %{}})
  defp empty_body(:strip, base), do: quote(do: {:ok, unquote(base)})

  defp empty_body(policy, base) do
    seed = base || quote(do: %{})

    quote do
      Rupa.Codegen.unknown(
        unquote(policy),
        unquote(seed),
        value,
        unquote(escape(MapSet.new())),
        ctx
      )
    end
  end

  # =============================================
  # The fast clause
  # =============================================
  #
  # When every field is required and unknown keys are stripped, the whole object is one head
  # match: the keys in the pattern, the guard-safe checks in the guard, and the result as a map
  # literal. Nothing is consed and nothing is wrapped, which is what hand-written code does.
  # Anything that fails falls back to the chain below, which is slower and says why.

  defp fast_clause(name, fields, inner, :strip, chain, into) do
    if Enum.all?(fields, &(&1.presence == :required)) do
      [fast(name, fields, inner, chain, into)]
    else
      []
    end
  end

  defp fast_clause(_name, _fields, _inner, _unknown, _chain, _into), do: []

  defp fast(name, fields, inner, chain, into) do
    vars = Enum.map(0..(length(fields) - 1), &Macro.var(:"f#{&1}", nil))
    head = {:%{}, [], Enum.zip(Enum.map(fields, & &1.from), vars)}
    fallback = quote(do: unquote(chain)(value, ctx, [], []))

    parts = [fields, inner, vars, 0..(length(fields) - 1)] |> Enum.zip() |> Enum.map(&part/1)
    guard = Enum.reduce(Enum.flat_map(parts, & &1.guards), true, &both/2)

    body =
      parts
      |> Enum.reverse()
      |> Enum.reduce(quote(do: {:ok, unquote(result(parts, into))}), &wrap(&1, &2, fallback))

    clause(name, head, guard, body)
  end

  # Every field is required here, so the fast clause sets each one -- but a struct may name keys
  # the schema does not, and those want the module's own defaults. Merging at build time keeps
  # the result one map literal, which is the whole point of this clause.
  defp result(parts, nil), do: {:%{}, [], Enum.map(parts, &{&1.key, &1.value})}

  defp result(parts, module) do
    defaults = module.__struct__() |> Map.to_list() |> Enum.map(fn {k, v} -> {k, escape(v)} end)

    {:%{}, [], Keyword.merge(defaults, Enum.map(parts, &{&1.key, &1.value}))}
  end

  # `when true` is not a guard, it is a thing the type checker has to have an opinion about.
  defp clause(name, head, true, body) do
    quote do
      defp unquote(name)(unquote(head) = value, ctx), do: unquote(body)
    end
  end

  defp clause(name, head, guard, body) do
    quote do
      defp unquote(name)(unquote(head) = value, ctx) when unquote(guard) do
        unquote(body)
      end
    end
  end

  defp part({%IR.Field{ir: %IR.Scalar{format: nil} = scalar} = field, _inner, var, _index}) do
    {guards, body} = Enum.split_with(scalar.checks, &guard_safe?(scalar.kind, &1))

    # The checks run against the coerced value, not the raw wire one: a float field takes a JSON
    # integer, and its bounds have to see `var * 1.0` (the value it will store) or a 2^53+1 slips
    # past a bound the rounded value fails -- the same coercion `scalar_body`/`inline_test` make on
    # the other two decode routes. `type_test` still gates the raw `var`, and stands first in the
    # guard chain so the coercion is only reached once `var` is known to be a coercible number.
    checked = coerce(scalar.kind, var)

    %{
      key: field.key,
      value: coerce(scalar.kind, var),
      guards: [
        type_test(scalar.kind, var) | Enum.map(guards, &check_test(scalar.kind, &1, checked))
      ],
      body: Enum.map(body, &check_test(scalar.kind, &1, checked)),
      call: nil
    }
  end

  defp part({field, inner, var, index}) do
    decoded = Macro.var(:"r#{index}", nil)

    %{key: field.key, value: decoded, guards: [], body: [], call: {inner, var, decoded}}
  end

  defp wrap(%{call: nil, body: body}, acc, fallback) do
    Enum.reduce(body, acc, fn test, inner ->
      quote(do: if(unquote(test), do: unquote(inner), else: unquote(fallback)))
    end)
  end

  defp wrap(%{call: {fun, var, decoded}}, acc, fallback) do
    quote do
      case unquote(fun)(unquote(var), ctx) do
        {:ok, unquote(decoded)} -> unquote(acc)
        {:error, _found} -> unquote(fallback)
      end
    end
  end

  defp both(true, acc), do: acc
  defp both(test, true), do: test
  defp both(test, acc), do: quote(do: unquote(acc) and unquote(test))

  defp guard_safe?(_kind, {:min, minimum}), do: minimum in [0, 1]
  defp guard_safe?(_kind, {bound, _limit}) when bound in [:gte, :gt, :lte, :lt], do: true
  defp guard_safe?(:integer, {:multiple_of, step}), do: is_integer(step)
  defp guard_safe?(_kind, _check), do: false

  # =============================================
  # Unions
  # =============================================
  #
  # A tagged union is a head match on the tag, so dispatch is one map lookup and one literal
  # comparison however many branches there are, and the branch's own function is a direct call.
  # An untagged one has nothing to match on, so it is a chain of attempts -- which is the cost
  # `tag: :none` makes you opt into.

  # Attempts run in `:halt`, whatever the caller asked for: a variant that fails is one nobody
  # will see, and collecting its errors allocates a list per attempt for nothing. A variant that
  # succeeds decodes to the same value either way.
  defp union_fun(name, inner, tried) do
    exhausted = err(:no_variant, quote(do: %{value: value, tried: unquote(tried)}))

    body =
      Enum.reduce(Enum.reverse(inner), exhausted, fn fun, acc ->
        quote do
          case unquote(fun)(value, :halt) do
            {:ok, done} -> {:ok, done}
            {:error, _found} -> unquote(acc)
          end
        end
      end)

    quote(do: defp(unquote(name)(value, _ctx), do: unquote(body)))
  end

  # A decoder for a node, generated inside the encode or JSON walk but resolving its refs to the
  # symmetric decode aliases (`vref_<name>`, from `verify_walk/2`), so a union encoder can decode
  # what it wrote to check the branch round-trips -- and a renamed field inside a recursive
  # definition is read back through the name that was written, not through its input name, which
  # the decode walk's own aliases would do. The generated functions carry this walk's prefix; only
  # `refs` is swapped, and restored so the rest of the walk is unaffected.
  #
  # Memoised on the node it verifies: a schema that nests the same union shape in more than one
  # place -- both branches of an outer union, most sharply -- would otherwise regenerate its whole
  # verify decoder at each occurrence, and on a deeply nested union that compounds to a module the
  # compiler chokes on. Identical shapes share one verifier instead. The key is the node handed in,
  # which is already `from`/`to`-symmetric, so two unions that differ only in wire names share too.
  defp verifier(ir, state) do
    case Map.fetch(state.verify, ir) do
      {:ok, name} ->
        {name, state}

      :error ->
        own_refs = state.refs
        verify_refs = Map.new(own_refs, fn {name, _alias} -> {name, :"vref_#{name}"} end)
        {name, state} = node(ir, %{state | refs: verify_refs})
        {name, %{state | refs: own_refs, verify: Map.put(state.verify, ir, name)}}
    end
  end

  # The branch selection is handed to a runtime helper (`:union_encode` or `:union_json`) rather
  # than unrolled into generated clauses. Unrolled, the round-trip loop necessarily calls a later
  # branch's encoder with a value the earlier branch already accepted -- so on a disjoint union the
  # type checker narrows the value and calls the later branch unreachable, which it is not. Keeping
  # the loop in one generically-typed helper leaves nothing per-schema for it to misjudge. This
  # mirrors the closure backend, whose `union_encode/6` does the same.
  defp union_select_fun(name, inner, verify, helper, tried) do
    branches = Enum.map(inner, &capture/1)

    quote do
      defp unquote(name)(value, _ctx) do
        Rupa.Codegen.unquote(helper)(
          value,
          [unquote_splicing(branches)],
          unquote(capture(verify)),
          unquote(tried)
        )
      end
    end
  end

  # `&name/2` for a generated function, as an AST.
  defp capture(name), do: {:&, [], [{:/, [], [{name, [], nil}, 2]}]}

  # The dispatch below matches the tag out of a map, so an internally tagged branch is only ever
  # handed one. Adjacent tagging hands the branch whatever was under the content key, which is
  # anything at all.
  defp branch_node(%IR.Tagged{content: nil}, %IR.Branch{ir: %IR.Object{} = object}, state) do
    object_node(object, state, :map)
  end

  defp branch_node(_tagged, %IR.Branch{ir: ir}, state), do: node(ir, state)

  defp tag_pattern(tagged, branch) do
    quote(do: %{unquote(tagged.tag_wire) => unquote(branch.wire)})
  end

  # A branch with no fields of its own that strips what it does not know cannot fail: its whole
  # decoder is `{:ok, %{}}`. Generating the clause that would handle its failure is dead code,
  # and the type checker reports dead code in the generated module by its internal name, in the
  # middle of whatever console the compile happens in. So: no clause.
  defp tag_body(
         %IR.Tagged{content: nil} = tagged,
         %IR.Branch{ir: %IR.Object{fields: [], unknown: :strip}} = branch,
         fun
       ) do
    quote do
      {:ok, decoded} = unquote(fun)(unquote(tag_input(tagged, branch)), ctx)
      {:ok, {unquote(branch.tag), decoded}}
    end
  end

  # Internally tagged, the branch decodes the map it is already in -- without the tag key when
  # the branch does not strip unknown keys, which is the only copy this path makes.
  defp tag_body(%IR.Tagged{content: nil} = tagged, branch, fun) do
    quote do
      case unquote(fun)(unquote(tag_input(tagged, branch)), ctx) do
        {:ok, decoded} -> {:ok, {unquote(branch.tag), decoded}}
        {:error, _found} = error -> error
      end
    end
  end

  # Adjacently tagged, the branch's value has its own key, so it can be any schema at all and
  # its errors carry that key.
  defp tag_body(tagged, branch, fun) do
    quote do
      case value do
        %{unquote(tagged.content_wire) => held} ->
          case unquote(fun)(held, ctx) do
            {:ok, decoded} ->
              {:ok, {unquote(branch.tag), decoded}}

            {:error, found} ->
              {:error, Rupa.Codegen.under(found, unquote(tagged.content))}
          end

        _ ->
          unquote(err_at(tagged.content, :required, quote(do: %{})))
      end
    end
  end

  defp tag_input(_tagged, %IR.Branch{drop_tag: false}), do: quote(do: value)

  defp tag_input(tagged, _branch) do
    quote(do: :maps.remove(unquote(tagged.tag_wire), value))
  end

  defp tag_fallbacks(tagged) do
    allowed = escape(Enum.map(tagged.branches, & &1.wire))

    unknown =
      err_at(tagged.tag, :unknown_tag, quote(do: %{value: found, allowed: unquote(allowed)}))

    [
      {:->, [], [[quote(do: %{unquote(tagged.tag_wire) => found})], unknown]},
      {:->, [], [[quote(do: _value)], err_at(tagged.tag, :required, quote(do: %{}))]}
    ]
  end

  defp enc_tag_clause(name, tagged, branch, fun) do
    quote do
      defp unquote(name)({unquote(branch.tag), held}, ctx) do
        case unquote(fun)(held, ctx) do
          {:ok, wire} -> {:ok, unquote(enc_wired(tagged, branch))}
          {:error, found} -> unquote(enc_under(tagged))
        end
      end
    end
  end

  defp enc_wired(%IR.Tagged{content: nil} = tagged, branch) do
    quote(do: :maps.put(unquote(tagged.tag_wire), unquote(branch.wire), wire))
  end

  defp enc_wired(tagged, branch) do
    quote do
      %{unquote(tagged.tag_wire) => unquote(branch.wire), unquote(tagged.content_wire) => wire}
    end
  end

  defp enc_under(%IR.Tagged{content: nil}), do: quote(do: {:error, found})

  defp enc_under(tagged) do
    quote(do: {:error, Rupa.Codegen.under(found, unquote(tagged.content))})
  end

  # =============================================
  # Chains
  # =============================================

  defp member_fun({inner, step, next, index}) do
    quote do
      defp unquote(step)([item | rest], ctx, acc, errors) do
        case unquote(inner)(item, ctx) do
          {:ok, decoded} ->
            unquote(next)(rest, ctx, [decoded | acc], errors)

          {:error, found} ->
            errors = Rupa.Codegen.stack(found, unquote(index), errors)

            if ctx == :halt,
              do: {:error, :lists.reverse(errors)},
              else: unquote(next)(rest, ctx, acc, errors)
        end
      end
    end
  end

  defp field_fun({field, inner, step, next}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        case value do
          %{unquote(field.from) => found} -> unquote(present(field, inner, next))
          _ -> unquote(absent(field, next))
        end
      end
    end
  end

  # A scalar with no format is tested in place: no call, no `{:ok, _}`, nothing allocated when
  # the field is there and valid. Only the failing case pays for the node function, which
  # re-runs the checks one at a time to say which one it was.
  defp present(field, inner, next) do
    case field.ir do
      %IR.Scalar{format: nil} = scalar ->
        quote do
          if unquote(inline_test(scalar, quote(do: found))) do
            unquote(next)(
              value,
              ctx,
              [{unquote(field.key), unquote(coerce(scalar.kind, quote(do: found)))} | acc],
              errors
            )
          else
            unquote(failed(field, inner, next))
          end
        end

      _other ->
        failed(field, inner, next)
    end
  end

  defp failed(field, inner, next) do
    quote do
      case unquote(inner)(found, ctx) do
        {:ok, decoded} ->
          unquote(next)(value, ctx, [{unquote(field.key), decoded} | acc], errors)

        {:error, found_errors} ->
          errors = Rupa.Codegen.stack(found_errors, unquote(field.key), errors)

          if ctx == :halt,
            do: {:error, :lists.reverse(errors)},
            else: unquote(next)(value, ctx, acc, errors)
      end
    end
  end

  defp absent(%IR.Field{default: {:value, default}} = field, next) do
    quote do
      unquote(next)(value, ctx, [{unquote(field.key), unquote(escape(default))} | acc], errors)
    end
  end

  defp absent(%IR.Field{presence: :optional}, next) do
    quote(do: unquote(next)(value, ctx, acc, errors))
  end

  defp absent(field, next) do
    quote do
      errors = [
        %Rupa.Error{path: [unquote(field.key)], code: :required, meta: %{}} | errors
      ]

      if ctx == :halt,
        do: {:error, :lists.reverse(errors)},
        else: unquote(next)(value, ctx, acc, errors)
    end
  end

  # =============================================
  # Scalars
  # =============================================

  # `:float` coerces a JSON integer to a float *before* the constraints run, so a bound is checked
  # against the value the caller gets back -- the same order the closure backend uses. The type
  # test has already excluded an integer too large to coerce, so `value * 1.0` here cannot raise.
  defp scalar_body(%IR.Scalar{kind: kind, checks: checks, format: format}, value) do
    target = check_target(kind, value)

    ok =
      if format do
        format_ok(format, target)
      else
        quote(do: {:ok, unquote(target)})
      end

    checked =
      checks
      |> Enum.reverse()
      |> Enum.reduce(ok, fn check, acc ->
        guard(check_test(kind, check, target), acc, code(check), meta(check))
      end)

    quote do
      if unquote(type_test(kind, value)) do
        unquote(bind_target(kind, target, value, checked))
      else
        unquote(err(:type, quote(do: %{expected: unquote(kind), value: unquote(value)})))
      end
    end
  end

  # A float checks and returns the coerced value, bound once inside the type-tested branch; every
  # other kind uses the value as it arrived.
  defp check_target(:float, _value), do: Macro.unique_var(:coerced, __MODULE__)
  defp check_target(_kind, value), do: value

  defp bind_target(:float, target, value, checked) do
    quote do
      unquote(target) = unquote(value) * 1.0
      unquote(checked)
    end
  end

  defp bind_target(_kind, _target, _value, checked), do: checked

  defp inline_test(%IR.Scalar{kind: :float, checks: checks}, value) do
    coerced = quote(do: unquote(value) * 1.0)

    Enum.reduce(checks, type_test(:float, value), fn check, acc ->
      quote(do: unquote(acc) and unquote(check_test(:float, check, coerced)))
    end)
  end

  defp inline_test(%IR.Scalar{kind: kind, checks: checks}, value) do
    Enum.reduce(checks, type_test(kind, value), fn check, acc ->
      quote(do: unquote(acc) and unquote(check_test(kind, check, value)))
    end)
  end

  defp type_test(:string, value), do: quote(do: is_binary(unquote(value)))
  defp type_test(:integer, value), do: quote(do: is_integer(unquote(value)))

  # A float field takes a JSON integer too, but only one small enough to coerce: a bignum past
  # the double range would raise in `value * 1.0`, so it fails the type test and errors cleanly.
  defp type_test(:float, value) do
    quote do
      is_float(unquote(value)) or
        (is_integer(unquote(value)) and unquote(value) >= unquote(@float_min) and
           unquote(value) <= unquote(@float_max))
    end
  end

  defp type_test(:boolean, value), do: quote(do: is_boolean(unquote(value)))
  defp type_test(:null, value), do: quote(do: unquote(value) == nil)

  defp coerce(:float, value), do: quote(do: unquote(value) * 1.0)
  defp coerce(_kind, value), do: value

  defp format_ok(format, value) do
    quote do
      case Rupa.Format.decode(unquote(format), unquote(value)) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> unquote(err(:format, quote(do: %{format: unquote(format)})))
      end
    end
  end

  defp check_test(_kind, {:min, 0}, _value), do: true
  defp check_test(_kind, {:min, 1}, value), do: quote(do: unquote(value) != "")

  defp check_test(:string, {:min, min}, value) do
    quote do
      byte_size(unquote(value)) >= unquote(min) and String.length(unquote(value)) >= unquote(min)
    end
  end

  defp check_test(:string, {:max, max}, value) do
    quote do
      byte_size(unquote(value)) <= unquote(max) or String.length(unquote(value)) <= unquote(max)
    end
  end

  defp check_test(:string, {:len, len}, value) do
    quote do
      byte_size(unquote(value)) >= unquote(len) and String.length(unquote(value)) == unquote(len)
    end
  end

  defp check_test(:string, {:pattern, source}, value) do
    quote(do: Regex.match?(unquote(escape(Regex.compile!(source))), unquote(value)))
  end

  defp check_test(_kind, {bound, limit}, value) when bound in [:gte, :gt, :lte, :lt] do
    {comparison(bound), [], [value, limit]}
  end

  # `rem/2` needs both sides integral, and the only kind that guarantees that is `:integer` --
  # a `:float` field takes a JSON integer too. The caller has already tested the type, so this
  # does not repeat it.
  defp check_test(:integer, {:multiple_of, step}, value) when is_integer(step) do
    quote(do: rem(unquote(value), unquote(step)) == 0)
  end

  # A float `multiple_of:` is an exact decimal check in `Rupa.Number`, shared with the closure
  # backend so both accept `0.3` against `0.1`.
  defp check_test(_kind, {:multiple_of, step}, value) do
    quote(do: Rupa.Number.multiple?(unquote(value), unquote(step)))
  end

  defp comparison(:gte), do: :>=
  defp comparison(:gt), do: :>
  defp comparison(:lte), do: :<=
  defp comparison(:lt), do: :<

  defp code({key, _limit}), do: key

  defp meta({:min, min}), do: quote(do: %{min: unquote(min), unit: "characters"})
  defp meta({:max, max}), do: quote(do: %{max: unquote(max), unit: "characters"})
  defp meta({:len, len}), do: quote(do: %{len: unquote(len)})
  defp meta({:pattern, source}), do: quote(do: %{pattern: unquote(source)})
  defp meta({key, limit}), do: quote(do: %{unquote(key) => unquote(limit)})

  defp guard(true, ok, _code, _meta), do: ok

  defp guard(test, ok, code, meta) do
    quote(do: if(unquote(test), do: unquote(ok), else: unquote(err(code, meta))))
  end

  # Uniqueness wraps the decoded result rather than the input, so it sees the values decoding
  # actually produced. min/max still gate the input length below.
  defp array_unique(false, decoded), do: decoded

  defp array_unique(true, decoded) do
    quote do
      case unquote(decoded) do
        {:ok, list} = ok ->
          if length(Enum.uniq(list)) == length(list),
            do: ok,
            else: unquote(err(:unique, quote(do: %{})))

        error ->
          error
      end
    end
  end

  defp array_check({:min, min}, acc) do
    test = quote(do: length(value) >= unquote(min))
    guard(test, acc, :min, quote(do: %{min: unquote(min), unit: "items"}))
  end

  defp array_check({:max, max}, acc) do
    test = quote(do: length(value) <= unquote(max))
    guard(test, acc, :max, quote(do: %{max: unquote(max), unit: "items"}))
  end

  # =============================================
  # Encoding
  # =============================================
  #
  # The mirror image: atom keys in, wire keys out, and types and formats checked because they
  # have to be looked at anyway. There is no fast clause here yet — encode is not on the
  # roadmap's benched path, and one chain is the smaller thing to review.

  defp enc_node(%IR.Ref{name: ref}, state), do: {Map.fetch!(state.refs, ref), state}

  defp enc_node(%IR.Scalar{kind: :string, format: nil}, state) do
    guarded(state, quote(do: is_binary(value)), :string, quote(do: {:ok, value}))
  end

  defp enc_node(%IR.Scalar{kind: :string, format: format}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) do
          case Rupa.Format.encode(unquote(format), value) do
            {:ok, wire} -> {:ok, wire}
            :error -> unquote(err(:format, quote(do: %{format: unquote(format)})))
          end
        end
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Scalar{kind: :integer}, state) do
    guarded(state, quote(do: is_integer(value)), :integer, quote(do: {:ok, value}))
  end

  defp enc_node(%IR.Scalar{kind: :float}, state) do
    guarded(state, quote(do: is_number(value)), :float, quote(do: {:ok, value}))
  end

  defp enc_node(%IR.Scalar{kind: :boolean}, state) do
    guarded(state, quote(do: is_boolean(value)), :boolean, quote(do: {:ok, value}))
  end

  defp enc_node(%IR.Scalar{kind: :null}, state) do
    guarded(state, quote(do: value == nil), :null, quote(do: {:ok, nil}))
  end

  defp enc_node(%IR.Const{reverse: reverse, values: values}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) do
          case unquote(escape(reverse)) do
            %{^value => wire} ->
              {:ok, wire}

            _ ->
              unquote(err(:const, quote(do: %{value: value, allowed: unquote(escape(values))})))
          end
        end
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Nullable{of: inner}, state) do
    {inner_name, state} = enc_node(inner, state)
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(nil, _ctx), do: {:ok, nil}
        defp unquote(name)(value, ctx), do: unquote(inner_name)(value, ctx)
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Array{of: inner}, state) do
    {inner_name, state} = enc_node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_list(value) and length(value) >= 0 do
          unquote(each)(value, 0, ctx, [], [])
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :array, value: value})))

        defp unquote(each)([], _index, _ctx, acc, []), do: {:ok, :lists.reverse(acc)}
        defp unquote(each)([], _index, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}

        defp unquote(each)([item | rest], index, ctx, acc, errors) do
          case unquote(inner_name)(item, ctx) do
            {:ok, wire} ->
              unquote(each)(rest, index + 1, ctx, [wire | acc], errors)

            {:error, found} ->
              errors = Rupa.Codegen.stack(found, index, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, index + 1, ctx, acc, errors)
          end
        end
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Dict{of: inner}, state) do
    {inner_name, state} = enc_node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_map(value) do
          unquote(each)(:lists.sort(:maps.to_list(value)), ctx, [], [])
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))

        defp unquote(each)([], _ctx, acc, []), do: {:ok, :maps.from_list(acc)}
        defp unquote(each)([], _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}

        defp unquote(each)([{key, item} | rest], ctx, acc, errors) do
          case unquote(inner_name)(item, ctx) do
            {:ok, wire} ->
              unquote(each)(rest, ctx, [{key, wire} | acc], errors)

            {:error, found} ->
              errors = Rupa.Codegen.stack(found, key, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, ctx, acc, errors)
          end
        end
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Fixed{members: []}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)({}, _ctx), do: {:ok, []}

        defp unquote(name)(value, _ctx) when is_tuple(value) do
          unquote(err(:tuple_size, quote(do: %{expected: 0, actual: tuple_size(value)})))
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :tuple, value: value})))
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Fixed{members: member_irs}, state) do
    {inner, state} = Enum.map_reduce(member_irs, state, &enc_node/2)
    {name, state} = fresh(state)
    {steps, state} = Enum.map_reduce(inner, state, fn _ir, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    size = length(member_irs)
    entry = List.first(steps ++ [done])

    positions =
      [inner, steps, Enum.drop(steps, 1) ++ [done], 0..max(size - 1, 0)]
      |> Enum.zip()
      |> Enum.map(&enc_member_fun/1)

    fun =
      quote do
        defp unquote(name)(value, ctx)
             when is_tuple(value) and tuple_size(value) == unquote(size) do
          unquote(entry)(:erlang.tuple_to_list(value), ctx, [], [])
        end

        defp unquote(name)(value, _ctx) when is_tuple(value) do
          unquote(
            err(:tuple_size, quote(do: %{expected: unquote(size), actual: tuple_size(value)}))
          )
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :tuple, value: value})))

        unquote_splicing(positions)

        defp unquote(done)([], _ctx, acc, []), do: {:ok, :lists.reverse(acc)}
        defp unquote(done)([], _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  # An untagged union's branches overlap on the wire, so "the first encoder that succeeds" can
  # write the wrong branch -- an encoder checks types and formats, not the constraints that told
  # the branches apart. So each branch's output is decoded back through the whole union, and the
  # first branch whose wire decodes to the value again is used. `verify` is a decoder for the
  # union, generated here but resolving its refs to the decode aliases the decode walk defined,
  # so a recursive member verifies too.
  defp enc_node(%IR.Union{members: members} = union, state) do
    {inner, state} = Enum.map_reduce(members, state, &enc_node/2)
    {verify, state} = verifier(IR.Rewrite.symmetric(union), state)
    {name, state} = fresh(state)

    {name, add(state, union_select_fun(name, inner, verify, :union_encode, length(members)))}
  end

  defp enc_node(%IR.Tagged{} = tagged, state) do
    {inner, state} =
      Enum.map_reduce(tagged.branches, state, fn one, acc -> enc_node(one.ir, acc) end)

    {name, state} = fresh(state)
    allowed = Enum.map(tagged.branches, & &1.tag)

    clauses =
      [tagged.branches, inner]
      |> Enum.zip()
      |> Enum.map(fn {one, fun} -> enc_tag_clause(name, tagged, one, fun) end)

    fun =
      quote do
        unquote_splicing(clauses)

        defp unquote(name)(value, _ctx) do
          unquote(
            err(:unknown_tag, quote(do: %{value: value, allowed: unquote(escape(allowed))}))
          )
        end
      end

    {name, add(state, fun)}
  end

  defp enc_node(%IR.Object{fields: [], unknown: :keep} = object, state) do
    {name, state} = fresh(state)

    body =
      quote(do: {:ok, Rupa.Codegen.kept(%{}, value, unquote(escape(MapSet.new())))})

    {name, add(state, quote(do: (unquote_splicing(enc_head(name, object, false, body)))))}
  end

  defp enc_node(%IR.Object{fields: []} = object, state) do
    {name, state} = fresh(state)
    clauses = enc_head(name, object, false, quote(do: {:ok, %{}}))

    {name, add(state, quote(do: (unquote_splicing(clauses))))}
  end

  defp enc_node(%IR.Object{fields: fields, unknown: unknown} = object, state) do
    {name, state} = fresh(state)
    modes = Enum.map(fields, &field_mode(&1, object.into))

    {inner, state} =
      Enum.map_reduce(Enum.zip(fields, modes), state, fn {field, mode}, acc ->
        enc_node(written(field, mode), acc)
      end)

    {steps, state} = Enum.map_reduce(fields, state, fn _field, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    entry = List.first(steps ++ [done])

    field_funs =
      [fields, inner, steps, Enum.drop(steps, 1) ++ [done], modes]
      |> Enum.zip()
      |> Enum.map(&enc_field_fun/1)

    head = enc_head(name, object, true, quote(do: unquote(entry)(value, ctx, [], [])))

    fun =
      quote do
        unquote_splicing(head)

        unquote_splicing(field_funs)

        defp unquote(done)(value, _ctx, acc, []), do: unquote(kept_body(unknown, fields))
        defp unquote(done)(_value, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  # An `into:` object encodes a struct and nothing else. Saying so in the head is what makes the
  # field functions below able to read their key without a fallback: a struct has every key, so
  # a "this key is missing" clause under this guard would be code that cannot run, and Elixir's
  # type checker would say so about a function nobody named.
  defp enc_head(name, %IR.Object{into: nil}, uses_ctx?, body) do
    [
      quote do
        defp unquote(name)(value, unquote(ctx_var(uses_ctx?))) when is_map(value) do
          unquote(body)
        end
      end,
      quote do
        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))
      end
    ]
  end

  defp enc_head(name, %IR.Object{into: module}, uses_ctx?, body) do
    [
      quote do
        defp unquote(name)(value, unquote(ctx_var(uses_ctx?)))
             when is_struct(value, unquote(module)) do
          unquote(body)
        end
      end,
      quote do
        defp unquote(name)(value, _ctx),
          do: unquote(err(:struct, quote(do: %{expected: unquote(module), value: value})))
      end
    ]
  end

  # `ctx` when the clause reads the mode, `_ctx` when it does not: binding it unread would be an
  # unused variable in the generated module. The JSON walk's `done` clause reads it only under
  # `unknown: :keep`, to write the extras under the caller's error mode.
  defp ctx_var(true), do: Macro.var(:ctx, __MODULE__)
  defp ctx_var(false), do: Macro.var(:_ctx, __MODULE__)

  # Inside a struct there is no absent, so encoding has to recognise it: what decoding leaves
  # behind for a key that was not on the wire is the module's own `defstruct` default, and
  # writing that value back as absent is what keeps the round trip closing. Only an optional
  # field with no `default:` of its own has such a value. Reading it off the module rather than
  # assuming `nil` is what makes a hand-written struct with a default of its own round-trip too.
  defp field_mode(_field, nil), do: :plain

  defp field_mode(%IR.Field{presence: :optional, default: :none, key: key}, module) do
    {:absent, Map.fetch!(module.__struct__(), key)}
  end

  defp field_mode(%IR.Field{}, _module), do: :struct

  # Which node actually does the writing. When the absent value is `nil`, an optional field's
  # `nullable` has nothing left to say on the way out: the `nil` it exists to pass through is
  # the one the field function already writes as absent, so generating it would leave a `nil`
  # clause nothing can reach -- and Elixir's type checker says so, by the generated function's
  # name, in whatever console the compile happens in. Decoding still needs it, because a wire
  # `null` has to be allowed in.
  defp written(%IR.Field{ir: %IR.Nullable{of: inner}}, {:absent, nil}), do: inner
  defp written(%IR.Field{ir: ir}, _mode), do: ir

  defp guarded(state, test, kind, ok) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) when unquote(test), do: unquote(ok)

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: unquote(kind), value: value})))
      end

    {name, add(state, fun)}
  end

  defp enc_member_fun({inner, step, next, index}) do
    quote do
      defp unquote(step)([item | rest], ctx, acc, errors) do
        case unquote(inner)(item, ctx) do
          {:ok, wire} ->
            unquote(next)(rest, ctx, [wire | acc], errors)

          {:error, found} ->
            errors = Rupa.Codegen.stack(found, unquote(index), errors)

            if ctx == :halt,
              do: {:error, :lists.reverse(errors)},
              else: unquote(next)(rest, ctx, acc, errors)
        end
      end
    end
  end

  defp enc_field_fun({field, inner, step, next, :plain}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        case value do
          %{unquote(field.key) => found} ->
            unquote(enc_found(field, inner, next))

          _ ->
            unquote(unset(field, next))
        end
      end
    end
  end

  # `:erlang.map_get/2` rather than a match: the object's head already proved this is a struct
  # of the module the schema names, so there is no missing-key clause to generate -- and a value
  # that somehow lacks the key raises the same `KeyError` the closure tree raises, rather than
  # the `MatchError` a pattern here would.
  defp enc_field_fun({field, inner, step, next, :struct}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        found = :erlang.map_get(unquote(field.key), value)
        unquote(enc_found(field, inner, next))
      end
    end
  end

  # `found === <default>`, not a pattern match on the default: an escaped `%{}` or a partial
  # struct would match as a *pattern* far more than the one value that stands for absent, so a
  # field whose defstruct default is a map would be dropped whenever it held any map at all. The
  # closure tree pins the value (`^absent`), which is exact equality, and `===` is the guard that
  # matches it.
  defp enc_field_fun({field, inner, step, next, {:absent, absent}}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        found = :erlang.map_get(unquote(field.key), value)

        if found === unquote(escape(absent)) do
          unquote(next)(value, ctx, acc, errors)
        else
          unquote(enc_found(field, inner, next))
        end
      end
    end
  end

  defp enc_found(field, inner, next) do
    quote do
      case unquote(inner)(found, ctx) do
        {:ok, wire} ->
          unquote(next)(value, ctx, [{unquote(field.to), wire} | acc], errors)

        {:error, found_errors} ->
          errors = Rupa.Codegen.stack(found_errors, unquote(field.key), errors)

          if ctx == :halt,
            do: {:error, :lists.reverse(errors)},
            else: unquote(next)(value, ctx, acc, errors)
      end
    end
  end

  defp unset(%IR.Field{presence: :optional}, next) do
    quote(do: unquote(next)(value, ctx, acc, errors))
  end

  defp unset(field, next) do
    quote do
      errors = [%Rupa.Error{path: [unquote(field.key)], code: :required, meta: %{}} | errors]

      if ctx == :halt,
        do: {:error, :lists.reverse(errors)},
        else: unquote(next)(value, ctx, acc, errors)
    end
  end

  defp kept_body(:keep, fields) do
    known = escape(IR.Field.claimed(fields))

    quote(do: {:ok, Rupa.Codegen.kept(:maps.from_list(acc), value, unquote(known))})
  end

  defp kept_body(_policy, _fields), do: quote(do: {:ok, :maps.from_list(acc)})

  # =============================================
  # JSON
  # =============================================
  #
  # The encoder once more, emitting iodata instead of a wire term. Generating rather than
  # closing over pays twice here: a field's `"key":`, an enum's wire value and a tagged branch's
  # whole `,"type":"circle"` are rendered while the module is being built, so they end up in the
  # beam file as literals and cost nothing at all to reach.

  defp json_node(%IR.Ref{name: ref}, state), do: {Map.fetch!(state.refs, ref), state}

  defp json_node(%IR.Scalar{kind: :string, format: nil}, state) do
    guarded(
      state,
      quote(do: is_binary(value)),
      :string,
      quote(do: Rupa.Json.encode_string(value))
    )
  end

  defp json_node(%IR.Scalar{kind: :string, format: format}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) do
          case Rupa.Format.encode(unquote(format), value) do
            {:ok, wire} -> Rupa.Json.encode_string(wire)
            :error -> unquote(err(:format, quote(do: %{format: unquote(format)})))
          end
        end
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Scalar{kind: :integer}, state) do
    guarded(
      state,
      quote(do: is_integer(value)),
      :integer,
      quote(do: {:ok, :json.encode_integer(value)})
    )
  end

  # `encode/3` takes any number where the schema says float, and a JSON encoder would then write
  # an integer. Writing one here too is what keeps the two routes byte-identical.
  defp json_node(%IR.Scalar{kind: :float}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, _ctx) when is_float(value) do
          {:ok, :json.encode_float(value)}
        end

        defp unquote(name)(value, _ctx) when is_integer(value) do
          {:ok, :json.encode_integer(value)}
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :float, value: value})))
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Scalar{kind: :boolean}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(true, _ctx), do: {:ok, "true"}
        defp unquote(name)(false, _ctx), do: {:ok, "false"}

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :boolean, value: value})))
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Scalar{kind: :null}, state) do
    guarded(state, quote(do: value == nil), :null, quote(do: {:ok, "null"}))
  end

  defp json_node(%IR.Const{reverse: reverse, values: values}, state) do
    {name, state} = fresh(state)
    rendered = Map.new(reverse, fn {decoded, wire} -> {decoded, Json.literal(wire)} end)

    fun =
      quote do
        defp unquote(name)(value, _ctx) do
          case unquote(escape(rendered)) do
            %{^value => wire} ->
              {:ok, wire}

            _ ->
              unquote(err(:const, quote(do: %{value: value, allowed: unquote(escape(values))})))
          end
        end
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Nullable{of: inner}, state) do
    {inner_name, state} = json_node(inner, state)
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(nil, _ctx), do: {:ok, "null"}
        defp unquote(name)(value, ctx), do: unquote(inner_name)(value, ctx)
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Array{of: inner}, state) do
    {inner_name, state} = json_node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_list(value) and length(value) >= 0 do
          unquote(each)(value, 0, ctx, [], [])
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :array, value: value})))

        defp unquote(each)([], _index, _ctx, acc, []) do
          {:ok, Rupa.Json.array(:lists.reverse(acc))}
        end

        defp unquote(each)([], _index, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}

        defp unquote(each)([item | rest], index, ctx, acc, errors) do
          case unquote(inner_name)(item, ctx) do
            {:ok, wire} ->
              unquote(each)(rest, index + 1, ctx, [[?, | wire] | acc], errors)

            {:error, found} ->
              errors = Rupa.Codegen.stack(found, index, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, index + 1, ctx, acc, errors)
          end
        end
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Dict{of: inner}, state) do
    {inner_name, state} = json_node(inner, state)
    {name, state} = fresh(state)
    {each, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)(value, ctx) when is_map(value) do
          unquote(each)(:lists.sort(:maps.to_list(value)), ctx, [], [], %{})
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :object, value: value})))

        defp unquote(each)([], _ctx, acc, [], _seen) do
          {:ok, Rupa.Json.object(:lists.reverse(acc))}
        end

        defp unquote(each)([], _ctx, _acc, errors, _seen), do: {:error, :lists.reverse(errors)}

        # `seen` is the names written so far, for `Rupa.Json.entry_key/2`'s duplicate check.
        defp unquote(each)([{key, item} | rest], ctx, acc, errors, seen) do
          with {:ok, wire} <- unquote(inner_name)(item, ctx),
               {:ok, wire_key, seen} <- Rupa.Json.entry_key(key, seen) do
            unquote(each)(rest, ctx, [[?,, wire_key, ?: | wire] | acc], errors, seen)
          else
            {:error, found} ->
              errors = Rupa.Codegen.stack(found, key, errors)

              if ctx == :halt,
                do: {:error, :lists.reverse(errors)},
                else: unquote(each)(rest, ctx, acc, errors, seen)
          end
        end
      end

    {name, add(state, fun)}
  end

  # An empty tuple has no step to chain, so the general shape below would generate a `done`
  # clause for errors that nothing can reach, and the type checker would rightly say so.
  defp json_node(%IR.Fixed{members: []}, state) do
    {name, state} = fresh(state)

    fun =
      quote do
        defp unquote(name)({}, _ctx), do: {:ok, "[]"}

        defp unquote(name)(value, _ctx) when is_tuple(value) do
          unquote(err(:tuple_size, quote(do: %{expected: 0, actual: tuple_size(value)})))
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :tuple, value: value})))
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Fixed{members: member_irs}, state) do
    {inner, state} = Enum.map_reduce(member_irs, state, &json_node/2)
    {name, state} = fresh(state)
    {steps, state} = Enum.map_reduce(inner, state, fn _ir, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    size = length(member_irs)
    entry = List.first(steps ++ [done])

    positions =
      [inner, steps, Enum.drop(steps, 1) ++ [done], 0..max(size - 1, 0)]
      |> Enum.zip()
      |> Enum.map(&json_member_fun/1)

    fun =
      quote do
        defp unquote(name)(value, ctx)
             when is_tuple(value) and tuple_size(value) == unquote(size) do
          unquote(entry)(:erlang.tuple_to_list(value), ctx, [], [])
        end

        defp unquote(name)(value, _ctx) when is_tuple(value) do
          unquote(
            err(:tuple_size, quote(do: %{expected: unquote(size), actual: tuple_size(value)}))
          )
        end

        defp unquote(name)(value, _ctx),
          do: unquote(err(:type, quote(do: %{expected: :tuple, value: value})))

        unquote_splicing(positions)

        defp unquote(done)([], _ctx, acc, []), do: {:ok, Rupa.Json.array(:lists.reverse(acc))}
        defp unquote(done)([], _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  # Same branch problem and same fix as the term encoder: emit each branch, decode the bytes back
  # through the union, and keep the first whose JSON decodes to the value again.
  defp json_node(%IR.Union{members: members} = union, state) do
    {inner, state} = Enum.map_reduce(members, state, &json_node/2)
    {verify, state} = verifier(IR.Rewrite.symmetric(union), state)
    {name, state} = fresh(state)

    {name, add(state, union_select_fun(name, inner, verify, :union_json, length(members)))}
  end

  defp json_node(%IR.Tagged{} = tagged, state) do
    {inner, state} =
      Enum.map_reduce(tagged.branches, state, fn one, acc ->
        json_branch_node(tagged, one, acc)
      end)

    {name, state} = fresh(state)
    allowed = Enum.map(tagged.branches, & &1.tag)

    clauses =
      [tagged.branches, inner]
      |> Enum.zip()
      |> Enum.map(fn {one, fun} -> json_tag_clause(name, tagged, one, fun) end)

    fun =
      quote do
        unquote_splicing(clauses)

        defp unquote(name)(value, _ctx) do
          unquote(
            err(:unknown_tag, quote(do: %{value: value, allowed: unquote(escape(allowed))}))
          )
        end
      end

    {name, add(state, fun)}
  end

  defp json_node(%IR.Object{} = object, state), do: json_object(object, state, :plain)

  # An internally tagged branch is an object by the time the schema validates, and it is the one
  # caller that wants the field chain started with something already in the accumulator. So it
  # gets the seeded head and nothing else: generating both would leave one of them unreachable,
  # which the compiler would rightly complain about.
  defp json_branch_node(%IR.Tagged{content: nil}, %IR.Branch{ir: %IR.Object{} = object}, state) do
    json_object(object, state, :seeded)
  end

  defp json_branch_node(_tagged, %IR.Branch{ir: ir}, state), do: json_node(ir, state)

  # An object with no fields has no step to chain either, and the same reasoning applies: with
  # nothing to fail, the `done` clause that reports failures is unreachable.
  defp json_object(%IR.Object{fields: []} = object, state, shape) do
    {name, state} = fresh(state)
    clauses = json_empty(name, object, json_done_body(object.unknown, []), shape)

    {name, add(state, quote(do: (unquote_splicing(clauses))))}
  end

  defp json_object(%IR.Object{fields: fields, unknown: unknown} = object, state, shape) do
    {name, state} = fresh(state)
    modes = Enum.map(fields, &field_mode(&1, object.into))

    {inner, state} =
      Enum.map_reduce(Enum.zip(fields, modes), state, fn {field, mode}, acc ->
        json_node(written(field, mode), acc)
      end)

    {steps, state} = Enum.map_reduce(fields, state, fn _field, acc -> fresh(acc) end)
    {done, state} = fresh(state)
    entry = List.first(steps ++ [done])

    field_funs =
      [fields, inner, steps, Enum.drop(steps, 1) ++ [done], modes]
      |> Enum.zip()
      |> Enum.map(&json_field_fun/1)

    fun =
      quote do
        unquote_splicing(json_head(name, object, entry, shape))

        unquote_splicing(field_funs)

        defp unquote(done)(value, unquote(ctx_var(unknown == :keep)), acc, []),
          do: unquote(json_done_body(unknown, fields))

        defp unquote(done)(_value, _ctx, _acc, errors), do: {:error, :lists.reverse(errors)}
      end

    {name, add(state, fun)}
  end

  defp json_empty(name, object, body, :plain) do
    [
      quote do
        defp unquote(name)(value, unquote(ctx_var(object.unknown == :keep)))
             when unquote(json_guard(object)) do
          acc = []
          Rupa.Json.wrap(unquote(body))
        end
      end,
      json_reject(name, object, [quote(do: value), quote(do: _ctx)])
    ]
  end

  defp json_empty(name, object, body, :seeded) do
    [
      quote do
        defp unquote(name)(value, unquote(ctx_var(object.unknown == :keep)), acc)
             when unquote(json_guard(object)) do
          Rupa.Json.wrap(unquote(body))
        end
      end,
      json_reject(name, object, [quote(do: value), quote(do: _ctx), quote(do: _acc)])
    ]
  end

  defp json_head(name, object, entry, :plain) do
    [
      quote do
        defp unquote(name)(value, ctx) when unquote(json_guard(object)) do
          Rupa.Json.wrap(unquote(entry)(value, ctx, [], []))
        end
      end,
      json_reject(name, object, [quote(do: value), quote(do: _ctx)])
    ]
  end

  defp json_head(name, object, entry, :seeded) do
    [
      quote do
        defp unquote(name)(value, ctx, acc) when unquote(json_guard(object)) do
          Rupa.Json.wrap(unquote(entry)(value, ctx, acc, []))
        end
      end,
      json_reject(name, object, [quote(do: value), quote(do: _ctx), quote(do: _acc)])
    ]
  end

  defp json_guard(%IR.Object{into: nil}), do: quote(do: is_map(value))

  defp json_guard(%IR.Object{into: module}) do
    quote(do: is_struct(value, unquote(module)))
  end

  defp json_reject(name, %IR.Object{into: nil}, args) do
    quote do
      defp unquote(name)(unquote_splicing(args)),
        do: unquote(err(:type, quote(do: %{expected: :object, value: value})))
    end
  end

  defp json_reject(name, %IR.Object{into: module}, args) do
    quote do
      defp unquote(name)(unquote_splicing(args)),
        do: unquote(err(:struct, quote(do: %{expected: unquote(module), value: value})))
    end
  end

  defp json_field_fun({field, inner, step, next, :plain}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        case value do
          %{unquote(field.key) => found} ->
            unquote(json_found(field, inner, next))

          _ ->
            unquote(unset(field, next))
        end
      end
    end
  end

  defp json_field_fun({field, inner, step, next, :struct}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        found = :erlang.map_get(unquote(field.key), value)
        unquote(json_found(field, inner, next))
      end
    end
  end

  # `found === <default>` for the same reason as `enc_field_fun/1`: the escaped default is a value
  # to compare against, not a pattern to match, or a map default would swallow every map.
  defp json_field_fun({field, inner, step, next, {:absent, absent}}) do
    quote do
      defp unquote(step)(value, ctx, acc, errors) do
        found = :erlang.map_get(unquote(field.key), value)

        if found === unquote(escape(absent)) do
          unquote(next)(value, ctx, acc, errors)
        else
          unquote(json_found(field, inner, next))
        end
      end
    end
  end

  defp json_found(field, inner, next) do
    key = Json.key(field.to)

    quote do
      case unquote(inner)(found, ctx) do
        {:ok, wire} ->
          unquote(next)(value, ctx, [[?,, unquote(key) | wire] | acc], errors)

        {:error, found_errors} ->
          errors = Rupa.Codegen.stack(found_errors, unquote(field.key), errors)

          if ctx == :halt,
            do: {:error, :lists.reverse(errors)},
            else: unquote(next)(value, ctx, acc, errors)
      end
    end
  end

  defp json_member_fun({inner, step, next, index}) do
    quote do
      defp unquote(step)([item | rest], ctx, acc, errors) do
        case unquote(inner)(item, ctx) do
          {:ok, wire} ->
            unquote(next)(rest, ctx, [[?, | wire] | acc], errors)

          {:error, found} ->
            errors = Rupa.Codegen.stack(found, unquote(index), errors)

            if ctx == :halt,
              do: {:error, :lists.reverse(errors)},
              else: unquote(next)(rest, ctx, acc, errors)
        end
      end
    end
  end

  defp json_done_body(:keep, fields) do
    claims = escape({IR.Field.claimed(fields), MapSet.new(fields, & &1.to)})

    quote(do: Rupa.Json.extra(:keep, value, unquote(claims), acc, ctx))
  end

  defp json_done_body(_policy, _fields), do: quote(do: {:ok, acc})

  defp json_tag_clause(name, %IR.Tagged{content: nil} = tagged, branch, fun) do
    entry = Json.constant(tagged.tag_wire, branch.wire)

    quote do
      defp unquote(name)({unquote(branch.tag), inner}, ctx) do
        unquote(fun)(inner, ctx, [unquote(entry)])
      end
    end
  end

  defp json_tag_clause(name, tagged, branch, fun) do
    entry = Json.constant(tagged.tag_wire, branch.wire)
    content_key = Json.key(tagged.content_wire)

    quote do
      defp unquote(name)({unquote(branch.tag), inner}, ctx) do
        case unquote(fun)(inner, ctx) do
          {:ok, wire} ->
            {:ok, Rupa.Json.object([unquote(entry), [?,, unquote(content_key) | wire]])}

          {:error, found} ->
            {:error, Rupa.Codegen.under(found, unquote(tagged.content))}
        end
      end
    end
  end

  # =============================================
  # Runtime helpers the generated code calls
  # =============================================

  @doc false
  @spec stack([Rupa.Error.t()], term(), [Rupa.Error.t()]) :: [Rupa.Error.t()]
  def stack(found, segment, errors) do
    Enum.reduce(found, errors, fn error, acc ->
      [%{error | path: [segment | error.path]} | acc]
    end)
  end

  @doc false
  @spec under([Rupa.Error.t()], term()) :: [Rupa.Error.t()]
  def under(errors, segment) do
    Enum.map(errors, fn error -> %{error | path: [segment | error.path]} end)
  end

  @doc false
  @spec kept(map(), map(), MapSet.t()) :: map()
  def kept(acc, value, known), do: Map.merge(acc, Map.new(IR.Field.extras(value, known)))

  @doc false
  @spec unknown(:error | :keep, map(), map(), MapSet.t(), :halt | :collect) ::
          {:ok, map()} | {:error, [Rupa.Error.t()]}
  def unknown(:keep, acc, value, known, _ctx) do
    {:ok, Map.merge(acc, Map.new(IR.Field.extras(value, known)))}
  end

  def unknown(:error, acc, value, known, ctx) do
    extra = value |> IR.Field.extras(known) |> Enum.map(&elem(&1, 0)) |> :lists.sort()

    case {extra, ctx} do
      {[], _mode} -> {:ok, acc}
      {[first | _rest], :halt} -> {:error, [Rupa.Error.new([], :unknown_key, %{key: first})]}
      {keys, :collect} -> {:error, Enum.map(keys, &Rupa.Error.new([], :unknown_key, %{key: &1}))}
    end
  end

  # An untagged union's branch selection, kept out of generated code so the type checker has no
  # per-schema clauses to misjudge. Each branch encodes the value in turn; `verify` (the union's
  # own decoder) decodes the wire back, and the first branch whose wire decodes to the value again
  # is the one that round-trips. A value no branch round-trips is `:no_variant`.
  @doc false
  @spec union_encode(
          term(),
          [(term(), :halt -> term())],
          (term(), :halt -> term()),
          non_neg_integer()
        ) ::
          {:ok, term()} | {:error, [Rupa.Error.t()]}
  def union_encode(value, [], _verify, tried) do
    {:error, [Rupa.Error.new([], :no_variant, %{value: value, tried: tried})]}
  end

  def union_encode(value, [encode | rest], verify, tried) do
    with {:ok, wire} <- encode.(value, :halt),
         {:ok, ^value} <- verify.(wire, :halt) do
      {:ok, wire}
    else
      _other -> union_encode(value, rest, verify, tried)
    end
  end

  # The JSON counterpart: a branch emits iodata, which is parsed and decoded back through the union
  # to confirm the choice round-trips before it is kept.
  @doc false
  @spec union_json(
          term(),
          [(term(), :halt -> term())],
          (term(), :halt -> term()),
          non_neg_integer()
        ) ::
          {:ok, iodata()} | {:error, [Rupa.Error.t()]}
  def union_json(value, [], _verify, tried) do
    {:error, [Rupa.Error.new([], :no_variant, %{value: value, tried: tried})]}
  end

  def union_json(value, [emit | rest], verify, tried) do
    with {:ok, iodata} <- emit.(value, :halt),
         {:ok, parsed} <- Rupa.Json.parse(IO.iodata_to_binary(iodata)),
         {:ok, ^value} <- verify.(parsed, :halt) do
      {:ok, iodata}
    else
      _other -> union_json(value, rest, verify, tried)
    end
  end

  # =============================================
  # Plumbing
  # =============================================

  defp fresh(state) do
    {:"#{state.prefix}#{state.counter}", %{state | counter: state.counter + 1}}
  end

  defp add(state, fun), do: %{state | funs: [fun | state.funs]}

  defp value, do: quote(do: value)

  defp escape(term), do: Macro.escape(term)

  defp err(code, meta) do
    quote(do: {:error, [%Rupa.Error{path: [], code: unquote(code), meta: unquote(meta)}]})
  end

  defp err_at(segment, code, meta) do
    quote do
      {:error, [%Rupa.Error{path: [unquote(segment)], code: unquote(code), meta: unquote(meta)}]}
    end
  end

  defp done_body(unknown, fields, nil), do: unknown_body(unknown, fields)

  defp done_body(:strip, _fields, base) do
    quote(do: {:ok, :maps.merge(unquote(base), :maps.from_list(acc))})
  end

  # `unknown: :keep` cannot hold with `into:`, so what is left here is `:error`, which either
  # passes the accumulator through or reports the keys the schema does not name.
  defp done_body(policy, fields, base) do
    known = known_for(policy, fields)

    quote do
      decoded = :maps.from_list(acc)

      case Rupa.Codegen.unknown(unquote(policy), decoded, value, unquote(known), ctx) do
        {:ok, kept} -> {:ok, :maps.merge(unquote(base), kept)}
        {:error, errors} -> {:error, errors}
      end
    end
  end

  defp unknown_body(:strip, _fields), do: quote(do: {:ok, :maps.from_list(acc)})

  defp unknown_body(policy, fields) do
    known = known_for(policy, fields)

    quote do
      Rupa.Codegen.unknown(unquote(policy), :maps.from_list(acc), value, unquote(known), ctx)
    end
  end

  # `unknown: :error` checks incoming keys against the ones fields read (`from`); `:keep` merges
  # by all three claimed names, so a passthrough extra never shadows a field.
  defp known_for(:error, fields), do: escape(IR.Field.inputs(fields))
  defp known_for(_policy, fields), do: escape(IR.Field.claimed(fields))
end

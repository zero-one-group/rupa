defmodule Rupa.CodegenTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rupa.T

  doctest Rupa.Codegen

  @schema %{id: T.uuid(), age: T.optional(T.integer(gte: 0))}
  @other %{name: T.string(min: 1)}

  defp data, do: %{"id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8"}

  describe "compile/2 with as:" do
    test "returns the name, and the module decodes" do
      assert {:ok, Named.Basic} = Rupa.compile(@schema, as: Named.Basic)
      assert Rupa.decode(Named.Basic, data()) == {:ok, %{id: data()["id"]}}
      assert Rupa.decode!(Named.Basic, data()) == %{id: data()["id"]}
      assert Rupa.valid?(Named.Basic, data())
      refute Rupa.valid?(Named.Basic, %{})
    end

    test "compile!/2 raises on a schema that will not stage" do
      assert_raise Rupa.SchemaError, fn ->
        Rupa.compile!(T.string(format: :ssn), as: Named.Never)
      end
    end

    test "the module says what it was built from" do
      {:ok, name} = Rupa.compile(@schema, as: Named.Reflects)

      assert name.__rupa__(:schema) == Rupa.Schema.normalize(@schema)
      assert name.__rupa__(:hash) == :erlang.phash2(Rupa.Schema.normalize(@schema))
      assert %Rupa.IR.Object{} = name.__rupa__(:program).root
    end

    test "explain/1 takes the name, and reads the same as the schema" do
      {:ok, _name} = Rupa.compile(@schema, as: Named.Explains)

      assert Rupa.explain(Named.Explains) == Rupa.explain(@schema)
    end
  end

  describe "the same name twice" do
    test "is a lookup when the schema is the same, not a recompile" do
      assert {:ok, Named.Idempotent} = Rupa.compile(@schema, as: Named.Idempotent)
      assert {:ok, Named.Idempotent} = Rupa.compile(@schema, as: Named.Idempotent)

      # A second compile would have left the first version behind as old code.
      refute :erlang.check_old_code(Named.Idempotent)
    end

    test "raises rather than silently swapping the schema underneath you" do
      {:ok, _name} = Rupa.compile(@schema, as: Named.Guarded)

      assert {:error, [error]} = Rupa.compile(@other, as: Named.Guarded)
      assert {error.code, error.meta} == {:already_compiled, %{name: Named.Guarded}}
      assert Rupa.Error.message(error) =~ "pass force: true"
    end

    test "replaces it when you say force: true" do
      {:ok, _name} = Rupa.compile(@schema, as: Named.Forced)
      assert {:ok, Named.Forced} = Rupa.compile(@other, as: Named.Forced, force: true)

      assert Rupa.decode(Named.Forced, %{"name" => "Ada"}) == {:ok, %{name: "Ada"}}
      assert :erlang.check_old_code(Named.Forced)
    end

    test "a schema that only collides on phash2 does not reuse the codec" do
      # These two normalise to schemas that share a phash2 (27-bit) on the BEAM, so a cache keyed
      # on the hash alone would hand the second the first's codec. Identity is the exact schema;
      # the hash only gates the comparison.
      a = T.integer(gte: 5045)
      b = T.integer(gte: 18_786)

      assert :erlang.phash2(Rupa.Schema.normalize(a)) ==
               :erlang.phash2(Rupa.Schema.normalize(b)),
             "expected a phash2 collision; if this fails, choose a new colliding pair here"

      assert {:ok, Named.Collide} = Rupa.compile(a, as: Named.Collide)
      assert {:error, [%{code: :already_compiled}]} = Rupa.compile(b, as: Named.Collide)

      # force gets past the collision and actually swaps b's constraint in: 5045 is below
      # gte: 18786 and is now rejected, where the buggy hash branch would have kept accepting it.
      assert {:ok, Named.Collide} = Rupa.compile(b, as: Named.Collide, force: true)
      assert {:error, _errors} = Rupa.decode(Named.Collide, 5045)
      assert {:ok, 18_786} = Rupa.decode(Named.Collide, 18_786)
    end
  end

  describe "a name that is not ours" do
    test "is left alone" do
      assert {:error, [error]} = Rupa.compile(@schema, as: Enum)
      assert {error.code, error.meta} == {:name_taken, %{name: Enum}}
      assert Rupa.Error.message(error) =~ "not one Rupa generated"
    end

    test "and one that is not a name at all is an ArgumentError that says so" do
      for bad <- ["MyApp.Codec", nil, true, 1] do
        assert_raise ArgumentError, ~r/as: expects a module name, got/, fn ->
          Rupa.compile(@schema, as: bad)
        end
      end
    end
  end

  describe "a codec a process is still running" do
    test "is not replaced, because purging it would kill that process" do
      name = Named.Lingering
      parent = self()

      source =
        quote do
          defmodule unquote(name) do
            def __rupa__(:hash), do: 0

            def loop(parent) do
              send(parent, :inside)
              receive do: (:stop -> :ok)
            end
          end
        end

      Code.compile_quoted(source)
      pid = spawn(fn -> apply(name, :loop, [parent]) end)

      # Sent from inside `loop/1`, so the process is provably in this version's code.
      assert_receive :inside

      previous = Code.get_compiler_option(:ignore_module_conflict)
      Code.put_compiler_option(:ignore_module_conflict, true)
      Code.compile_quoted(source)
      Code.put_compiler_option(:ignore_module_conflict, previous)

      assert {:error, [error]} = Rupa.compile(@schema, as: name, force: true)
      assert {error.code, error.meta} == {:codec_in_use, %{name: name}}
      assert Rupa.Error.message(error) =~ "still running its code"

      send(pid, :stop)
    end
  end

  describe "what the generated module does that the closure tree cannot" do
    test "resolves a recursive ref as a direct call, with no table" do
      {:ok, _name} = Rupa.compile(%{v: T.integer(), c: T.list(T.ref(:root))}, as: Named.Tree)

      assert Rupa.decode(Named.Tree, %{"v" => 1, "c" => [%{"v" => 2, "c" => []}]}) ==
               {:ok, %{v: 1, c: [%{v: 2, c: []}]}}

      assert {:error, [%{path: [:c, 0, :v], code: :required}]} =
               Rupa.decode(Named.Tree, %{"v" => 1, "c" => [%{"c" => []}]})
    end

    test "renames in the head match, so the fast clause survives it" do
      schema = T.object(%{first_name: T.string(min: 1)}, rename_all: :camelCase, keys: :string)
      {:ok, _name} = Rupa.compile(schema, as: Named.Renamed)

      assert Rupa.decode(Named.Renamed, %{"firstName" => "Ada"}) ==
               {:ok, %{"first_name" => "Ada"}}

      assert Rupa.encode(Named.Renamed, %{"first_name" => "Ada"}) ==
               {:ok, %{"firstName" => "Ada"}}

      assert {:error, [%{path: ["first_name"], code: :min}]} =
               Rupa.decode(Named.Renamed, %{"firstName" => ""})
    end

    test "dispatches a tagged union in the head, so the branch is a direct call" do
      shapes = T.tagged(:type, %{"circle" => %{r: T.float()}, "rect" => %{w: T.float()}})
      {:ok, _name} = Rupa.compile(shapes, as: Named.Shapes)

      assert Rupa.decode(Named.Shapes, %{"type" => "circle", "r" => 1.0}) ==
               {:ok, {:circle, %{r: 1.0}}}

      assert Rupa.encode(Named.Shapes, {:rect, %{w: 2.0}}) ==
               {:ok, %{"type" => "rect", "w" => 2.0}}

      assert {:error, [%{path: [:type], code: :unknown_tag}]} =
               Rupa.decode(Named.Shapes, %{"type" => "tri"})
    end

    test "embeds a compiled pattern as a literal" do
      {:ok, _name} = Rupa.compile(%{code: T.string(pattern: "^[A-Z]{2}$")}, as: Named.Pattern)

      assert Rupa.decode(Named.Pattern, %{"code" => "ID"}) == {:ok, %{code: "ID"}}
      assert {:error, [%{code: :pattern}]} = Rupa.decode(Named.Pattern, %{"code" => "id"})
    end
  end

  # M5's extra gate. Every atom a decoded map is keyed by is interned from the schema while the
  # module is generated, so the generated code has no way to make one from wire data. This reads
  # the AST rather than the source, which is the thing that actually gets compiled.
  describe "no atom is ever made from wire data" do
    test "the generated module names no function that interns one, tag atoms included" do
      schema =
        T.object(
          %{
            first_name: T.string(),
            id: T.string(from: "identifier"),
            tags: T.list(T.string()),
            counts: T.map_of(T.integer()),
            role: T.enum([:admin, :member], default: :member),
            nested: T.object(%{post_code: T.string()}, keys: :string, unknown: :keep),
            checked: T.object(%{a: T.string()}, unknown: :error),
            shape: T.tagged(:type, %{"circle" => %{r: T.float()}}),
            event: T.tagged(:kind, %{"n" => T.integer()}, content: :value),
            either: T.union([T.integer(), T.string()], tag: :none)
          },
          rename_all: :camelCase
        )

      {:ok, program} = Rupa.Stage.run(schema)
      {ast, _index} = Rupa.Codegen.module(Named.NoAtoms, program, schema)
      source = Macro.to_string(ast)

      for interner <- [
            "String.to_atom",
            "String.to_existing_atom",
            "binary_to_atom",
            "binary_to_existing_atom",
            "list_to_atom"
          ] do
        refute source =~ interner
      end
    end
  end

  # =============================================
  # Whose console the warnings land in
  # =============================================
  #
  # A named codec compiles at run time, so the type checker reads it then and reports what it
  # finds by the generated module's own function names -- in production, into the application's
  # boot log. `Rupa.compile/2` catches those and says them again in terms of the schema.

  describe "the index Codegen.module/3 returns" do
    test "names every function the module defines, and which walk wrote it" do
      schema = T.object(%{tree: T.ref(:node)}, defs: %{node: %{kids: T.list(T.ref(:node))}})

      {:ok, program} = Rupa.Stage.run(schema)
      {ast, index} = Rupa.Codegen.module(Named.Indexed, program, schema)

      defined =
        ast
        |> Macro.to_string()
        |> then(&Regex.scan(~r/defp (\w+)\(/, &1))
        |> MapSet.new(fn [_all, fun] -> fun end)

      assert MapSet.equal?(defined, MapSet.new(Map.keys(index)))
      assert index["d0"] == :decode
      assert index["e0"] == :encode
      assert index["j0"] == :encode_json

      # The aliases a recursive ref calls through are generated too, so a message naming one is
      # a message the translation has to recognise.
      assert index["ref_node"] == :decode
      assert index["eref_node"] == :encode
      assert index["jref_node"] == :encode_json
    end
  end

  describe "attribute/2" do
    test "names the walk a message is about, and says so plainly when it names none" do
      # A recursive def, so the index has the `ref_`/`eref_`/`jref_` aliases in it too.
      schema = T.object(%{tree: T.ref(:node)}, defs: %{node: %{kids: T.list(T.ref(:node))}})
      {:ok, program} = Rupa.Stage.run(schema)
      {_ast, index} = Rupa.Codegen.module(Named.Attributed, program, schema)

      assert Rupa.Codegen.attribute("this clause of defp d0/2 is never used", index) ==
               "the decoder it generated"

      assert Rupa.Codegen.attribute("the result of e0(value, :halt)", index) ==
               "the encoder it generated"

      assert Rupa.Codegen.attribute("about jref_node/2", index) ==
               "the JSON encoder it generated"

      # A message naming nothing Rupa minted is described in general rather than guessed at --
      # and `value`, `clause` and `never` are all ordinary words the index does not know.
      assert Rupa.Codegen.attribute("the following clause will never match", index) ==
               "the codec it generated"
    end
  end

  describe "the diagnostics a generated codec earns" do
    # A compiler finding about generated code is re-said in the schema's terms. No schema in the
    # current vocabulary reliably produces one -- untagged-union branch selection is a runtime
    # helper now, precisely because the checker cannot see a round-trip and so misjudged disjoint
    # unions -- so the re-saying is driven directly here with a compiler-shaped diagnostic. It stays
    # in the library as a safety net for a future node kind that emits genuinely dead code.
    test "are re-said in terms of the schema, grouped into one warning" do
      diagnostics = [
        %{message: "the following clause will never match:\n\n    e7(value, :halt)"},
        %{message: "the following clause will never match:\n\n    j7(value, :halt)"}
      ]

      index = %{"e7" => :encode, "j7" => :encode_json}

      warned =
        capture_io(:stderr, fn ->
          assert Rupa.warn_diagnostics(diagnostics, Named.Earned, index) == :ok
        end)

      assert warned =~ "Named.Earned: the compiler found this in the codec Rupa generated"
      assert warned =~ "in the encoder it generated:"
      assert warned =~ "in the JSON encoder it generated:"
      assert warned =~ "e7(value, :halt)"
      assert warned =~ "Rupa.explain(Named.Earned)"
      assert warned =~ "untagged union whose earlier variant already accepts"

      # One warning, not one per finding: several `warning:` lines would be several copies of the
      # closing paragraph, which is how a boot log becomes something nobody reads.
      assert warned |> String.split("warning:") |> length() == 2
    end

    test "say nothing when there are no findings" do
      assert capture_io(:stderr, fn ->
               assert Rupa.warn_diagnostics([], Named.Quiet, %{}) == :ok
             end) == ""
    end

    # The reason the re-saying is driven synthetically above: an untagged union no longer earns a
    # compiler finding, because branch selection is a runtime helper. A disjoint union used to be
    # false-flagged as having an unreachable variant on Elixir >= 1.19; it must stay silent.
    test "an untagged union compiles without a spurious unreachable-variant warning" do
      schemas = [
        %{either: T.union([T.integer(), T.string()], tag: :none)},
        T.union([%{n: T.integer(gt: 0)}, %{n: T.integer(lte: 0), data: T.string()}], tag: :none)
      ]

      for {schema, i} <- Enum.with_index(schemas) do
        name = Module.concat(Named.Quiet.Union, "N#{i}")

        assert capture_io(:stderr, fn ->
                 assert {:ok, _} = Rupa.compile(schema, as: name, force: true)
               end) == ""
      end
    end
  end
end

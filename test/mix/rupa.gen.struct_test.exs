defmodule Mix.Tasks.Rupa.Gen.StructTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Rupa.T

  # The schemas the task is pointed at. A zero-arity function in the project is what it takes,
  # so these stand in for `MyApp.Schemas.user/0`.
  defmodule Schemas do
    @moduledoc false

    def user do
      T.object(
        %{
          id: T.uuid(),
          first_name: T.string(min: 1),
          role: T.enum([:admin, :member], default: :member),
          joined_at: T.datetime(),
          tags: T.list(T.string()),
          nickname: T.optional(T.nullable(T.string())),
          address:
            T.object(%{city: T.string(), geo: T.tuple([T.float(), T.float()])}, into: Gen.Address)
        },
        rename_all: :camelCase,
        into: Gen.User
      )
    end

    def flat, do: T.object(%{city: T.string()}, into: Gen.Address)

    # What `Rupa.JsonSchema.decode/1` produces from a fetched document, plus the `keys: :atom`
    # that makes it a struct: property names nobody chose, which need not be bare identifiers.
    def fetched do
      T.object(
        %{"first-name" => T.string(), "2fa" => T.optional(T.boolean()), "role" => T.string()},
        into: Gen.Fetched,
        keys: :atom
      )
    end

    # One of every node the type writer has a clause for, plus the same module reached twice
    # with the same fields, which is the case the collector folds rather than refuses.
    def everything do
      T.object(
        %{
          count: T.integer(),
          ratio: T.float(),
          flag: T.boolean(),
          nothing: T.null(),
          on: T.date(),
          at: T.time(),
          took: T.duration(),
          plain: T.object(%{a: T.string()}),
          lookup: T.map_of(T.integer()),
          pair: T.tuple([T.string(), T.integer()]),
          either: T.union([T.integer(), T.string()], tag: :none),
          shape: T.tagged(:type, %{"circle" => %{r: T.float()}}),
          version: T.literal(2),
          size: T.enum([:small, :large]),
          truth: T.enum([true, false]),
          weight: T.enum([1.5, 2.5]),
          label: T.enum(["a", "b"]),
          here: T.object(%{city: T.string()}, into: Gen.Twice),
          there: T.object(%{city: T.string()}, into: Gen.Twice),
          kids: T.list(T.ref(:root)),
          plains: T.list(T.ref(:leaf))
        },
        into: Gen.Everything,
        defs: %{leaf: T.object(%{n: T.integer(), more: T.list(T.ref(:leaf))})}
      )
    end

    def clash do
      T.object(%{
        a: T.object(%{city: T.string()}, into: Gen.Address),
        b: T.object(%{town: T.string()}, into: Gen.Address)
      })
    end

    def broken, do: T.object(%{a: T.string(format: :ssn)})
    def mapless, do: T.string()
  end

  # `mix test` has already run `compile`, so the task's own call to it is a no-op and the working
  # directory it writes into is free to be a throwaway.
  defp generate(argv) do
    tmp = Path.join(System.tmp_dir!(), "rupa-gen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {tmp, run(tmp, argv)}
  end

  # `Mix.shell()` colours its output when it is talking to a terminal and not when it is piped,
  # so what the assertions below would be matching depends on where the suite was run. This is
  # the same text either way.
  defp run(tmp, argv) do
    captured = capture_io(fn -> File.cd!(tmp, fn -> Mix.Tasks.Rupa.Gen.Struct.run(argv) end) end)

    String.replace(captured, ~r/\e\[[0-9;]*m/, "")
  end

  defp read(tmp, path), do: File.read!(Path.join(tmp, path))

  describe "what it writes" do
    test "one file per into:, at the path the module name conventionally has" do
      {tmp, output} = generate(["#{inspect(Schemas)}.user"])

      assert output =~ "* creating lib/gen/user.ex"
      assert output =~ "* creating lib/gen/address.ex"
      assert File.exists?(Path.join(tmp, "lib/gen/user.ex"))
      assert File.exists?(Path.join(tmp, "lib/gen/address.ex"))
    end

    test "a defstruct and a @type, and nothing that mentions Rupa" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.user"])
      source = read(tmp, "lib/gen/address.ex")

      assert source == """
             defmodule Gen.Address do
               @moduledoc \"\"\"
               Written by `mix rupa.gen.struct` from `#{inspect(Schemas)}.user/0`.

               Yours to edit. Re-running the task shows what a change to the schema would write.
               \"\"\"

               @type t :: %__MODULE__{city: String.t(), geo: {float(), float()}}

               defstruct [:city, :geo]
             end
             """

      # Nothing below the moduledoc names Rupa: the module is plain Elixir, and deleting the
      # dependency would leave it compiling.
      [_doc, code] = String.split(source, "\"\"\"\n\n", parts: 2)

      refute code =~ "Rupa"
      refute code =~ "use "
      refute code =~ "import "
    end

    test "a default: in the schema becomes the defstruct default" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.user"])

      assert read(tmp, "lib/gen/user.ex") =~ "defstruct ["
      assert read(tmp, "lib/gen/user.ex") =~ "role: :member]"
    end

    test "the types read off the IR, formats and nesting included" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.user"])
      source = read(tmp, "lib/gen/user.ex")

      assert source =~ "address: %Gen.Address{}"
      assert source =~ "joined_at: DateTime.t()"
      assert source =~ "tags: [String.t()]"
      assert source =~ "role: :admin | :member"
      # Optional and no default: absent comes back as the module's own nil, so the type says so.
      assert source =~ "nickname: String.t() | nil"
      # Renamed on the wire, not in the struct: `keys:` decides the key, `rename_all:` does not.
      assert source =~ "first_name: String.t()"
    end

    test "a type for every node the vocabulary has" do
      {tmp, output} = generate(["#{inspect(Schemas)}.everything"])
      source = read(tmp, "lib/gen/everything.ex")

      # One module, not two: the same into: reached twice with the same fields is folded.
      assert output =~ "lib/gen/twice.ex"
      assert read(tmp, "lib/gen/twice.ex") =~ "defstruct [:city]"
      assert source =~ "here: %Gen.Twice{}"
      assert source =~ "there: %Gen.Twice{}"

      for expected <- [
            "count: integer()",
            "ratio: float()",
            "flag: boolean()",
            "nothing: nil",
            "on: Date.t()",
            "at: Time.t()",
            "took: Duration.t()",
            "plain: map()",
            "lookup: %{optional(String.t()) => integer()}",
            "pair: {String.t(), integer()}",
            "either: integer() | String.t()",
            "shape: {:circle, map()}",
            "version: integer()",
            "size: :small | :large",
            "truth: boolean()",
            "weight: float()",
            "label: String.t()",
            # A recursive ref is a struct when what it names is one, and `term()` when it is not:
            # this is the one place a type would have to be written by hand.
            "kids: [%Gen.Everything{}]",
            "plains: [term()]"
          ] do
        assert source =~ expected
      end
    end

    test "a key that is not a bare identifier is quoted in both places it appears" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.fetched"])
      source = read(tmp, "lib/gen/fetched.ex")

      assert source =~ ~s|"first-name": String.t()|
      assert source =~ ~s|"2fa": boolean() \| nil|
      assert source =~ ~s|defstruct [:"2fa", :"first-name", :role]|

      # The real assertion is that it parses at all: interpolating the atom raw would put
      # `first-name: String.t()` in the typespec, which is a syntax error.
      assert IO.iodata_to_binary([Code.format_string!(source), ?\n]) == source
    end

    # The roadmap's extra gate for M9.
    test "the file is formatted as-is and compiles with no warnings and no Rupa" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.user"])

      for name <- ~w(lib/gen/address.ex lib/gen/user.ex) do
        source = read(tmp, name)
        assert IO.iodata_to_binary([Code.format_string!(source), ?\n]) == source
      end

      warnings =
        capture_io(:stderr, fn ->
          Code.put_compiler_option(:ignore_module_conflict, true)

          try do
            Code.compile_file(Path.join(tmp, "lib/gen/address.ex"))
            Code.compile_file(Path.join(tmp, "lib/gen/user.ex"))
          after
            Code.put_compiler_option(:ignore_module_conflict, false)
          end
        end)

      assert warnings == ""
    end

    # The point of the whole thing: what it writes is what `Rupa.compile/2` will take.
    test "the modules it writes satisfy the check that refused them" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.user"])

      Code.put_compiler_option(:ignore_module_conflict, true)

      try do
        Code.compile_file(Path.join(tmp, "lib/gen/address.ex"))
        Code.compile_file(Path.join(tmp, "lib/gen/user.ex"))
      after
        Code.put_compiler_option(:ignore_module_conflict, false)
      end

      assert {:ok, codec} = Rupa.compile(Schemas.user())

      wire = %{
        "id" => "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        "firstName" => "Ada",
        "joinedAt" => "2026-09-17T10:00:00Z",
        "tags" => ["x"],
        "address" => %{"city" => "Jakarta", "geo" => [1.0, 2.0]}
      }

      # Named rather than matched: these modules do not exist until the task has run, so a
      # `%Gen.User{}` pattern here would be a compile error in this file.
      assert {:ok, decoded} = Rupa.decode(codec, wire)
      assert decoded.__struct__ == Gen.User
      assert decoded.address.__struct__ == Gen.Address
      assert {decoded.role, decoded.nickname, decoded.first_name} == {:member, nil, "Ada"}
      assert Rupa.decode(codec, Rupa.encode!(codec, decoded)) == {:ok, decoded}
    end
  end

  describe "the flags" do
    test "an existing file is left alone until --force" do
      {tmp, _output} = generate(["#{inspect(Schemas)}.flat"])
      path = Path.join(tmp, "lib/gen/address.ex")
      File.write!(path, "edited by hand\n")

      again = run(tmp, ["#{inspect(Schemas)}.flat"])

      assert again =~ "* skipping lib/gen/address.ex (exists; pass --force to overwrite)"
      assert File.read!(path) == "edited by hand\n"

      forced = run(tmp, ["#{inspect(Schemas)}.flat", "--force"])

      assert forced =~ "* replacing lib/gen/address.ex"
      assert File.read!(path) =~ "defstruct [:city]"
    end

    test "--dry-run prints and writes nothing" do
      {tmp, output} = generate(["#{inspect(Schemas)}.flat", "--dry-run"])

      assert output =~ "* would write lib/gen/address.ex"
      assert output =~ "defstruct [:city]"
      refute File.exists?(Path.join(tmp, "lib"))
    end
  end

  describe "what it refuses" do
    test "an argument that is not a module and a function" do
      assert_raise Mix.Error, ~r/expected a module and a function/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run(["user"])
      end

      assert_raise Mix.Error, ~r/names a module/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run(["#{inspect(Schemas)}"])
      end

      assert_raise Mix.Error, ~r/exactly one argument/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run([])
      end
    end

    test "a function that is not there" do
      assert_raise Mix.Error, ~r/is not defined/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run(["#{inspect(Schemas)}.absent"])
      end
    end

    test "a schema that does not validate, with the errors in the message" do
      assert_raise Mix.Error, ~r/not one of Rupa's built-in formats/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run(["#{inspect(Schemas)}.broken"])
      end
    end

    test "two objects claiming one module with different fields" do
      assert_raise Mix.Error, ~r/two objects with different fields/, fn ->
        Mix.Tasks.Rupa.Gen.Struct.run(["#{inspect(Schemas)}.clash"])
      end
    end

    test "a schema with no into: anywhere writes nothing, and says nothing" do
      {tmp, output} = generate(["#{inspect(Schemas)}.mapless"])

      assert output == ""
      refute File.exists?(Path.join(tmp, "lib"))
    end
  end
end

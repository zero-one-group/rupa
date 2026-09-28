defmodule RupaTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  doctest Rupa

  describe "compile/1" do
    test "returns a codec, and the schema it was built from, canonicalised" do
      assert {:ok, codec} = Rupa.compile(%{name: T.string()})
      assert codec.schema == {:object, %{name: {:string, []}}, []}
      assert %Rupa.IR.Object{} = codec.program.root
    end

    test "hands back the schema's own errors rather than a codec" do
      assert {:error, [%{code: :unknown_format}]} = Rupa.compile(T.string(format: :ssn))
    end

    test "a codec carries every direction, and is never half-built" do
      module = Rupa.Codec

      assert module |> struct([]) |> Map.keys() |> Enum.sort() ==
               [
                 :__struct__,
                 :decode,
                 :defs,
                 :encode,
                 :encode_defs,
                 :json,
                 :json_defs,
                 :program,
                 :schema
               ]

      assert_raise ArgumentError, ~r/keys must also be given/, fn -> struct!(module, []) end
    end
  end

  describe "compile!/1" do
    test "raises with every problem the schema has" do
      error =
        assert_raise Rupa.SchemaError, fn ->
          Rupa.compile!(%{a: T.string(format: :ssn), b: T.enum([])})
        end

      message = Exception.message(error)
      assert message =~ "at /a: :ssn is not one of Rupa's built-in formats"
      assert message =~ "at /b: an enum needs at least one value"
    end
  end

  describe "decode!/3" do
    test "returns the value" do
      assert Rupa.decode!(Rupa.compile!(%{a: T.integer()}), %{"a" => 1}) == %{a: 1}
    end

    test "raises, saying where and what" do
      codec = Rupa.compile!(%{a: %{b: T.integer(gte: 0)}})

      error =
        assert_raise Rupa.DecodeError, fn ->
          Rupa.decode!(codec, %{"a" => %{"b" => -1}})
        end

      assert Exception.message(error) == """
             data does not match the schema:
               /a/b must be at least 0\
             """
    end

    test "says the value when the failure is the whole thing" do
      error =
        assert_raise Rupa.DecodeError, fn ->
          Rupa.decode!(Rupa.compile!(T.integer()), "nope")
        end

      assert Exception.message(error) =~ ~s(the value expected an integer, got "nope")
    end
  end

  describe "valid?/2" do
    test "is the yes/no, with nothing to unwrap" do
      codec = Rupa.compile!(%{a: T.integer()})
      assert Rupa.valid?(codec, %{"a" => 1})
      refute Rupa.valid?(codec, %{"a" => "1"})
    end
  end

  describe "the three states, end to end" do
    setup do
      %{
        codec:
          Rupa.compile!(%{
            required: T.string(),
            absent_ok: T.optional(T.string()),
            null_ok: T.nullable(T.string()),
            defaulted: T.string(default: "fallback")
          })
      }
    end

    test "each one behaves the way the schema said it would", %{codec: codec} do
      assert {:ok, decoded} = Rupa.decode(codec, %{"required" => "here", "null_ok" => nil})

      assert decoded == %{required: "here", null_ok: nil, defaulted: "fallback"}
      refute Map.has_key?(decoded, :absent_ok)
    end

    test "and a missing required key is the one that fails", %{codec: codec} do
      assert {:error, [%{path: [:required], code: :required}]} =
               Rupa.decode(codec, %{"null_ok" => nil})
    end
  end
end

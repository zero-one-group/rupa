defmodule Rupa.TTest do
  use ExUnit.Case, async: true

  alias Rupa.T

  doctest Rupa.T

  describe "the constructor table" do
    test "scalars are {kind, opts}" do
      assert T.string() == {:string, []}
      assert T.string(min: 1) == {:string, [min: 1]}
      assert T.string(max: 5) == {:string, [max: 5]}
      assert T.string(len: 2) == {:string, [len: 2]}
      assert T.string(pattern: "^[A-Z]{2}$") == {:string, [pattern: "^[A-Z]{2}$"]}
      assert T.string(format: :email) == {:string, [format: :email]}
      assert T.integer() == {:integer, []}
      assert T.integer(gte: 0, lte: 150) == {:integer, [gte: 0, lte: 150]}
      assert T.integer(gt: 0, lt: 10) == {:integer, [gt: 0, lt: 10]}
      assert T.integer(multiple_of: 2) == {:integer, [multiple_of: 2]}
      assert T.float() == {:float, []}
      assert T.float(gt: 0.0) == {:float, [gt: 0.0]}
      assert T.boolean() == {:boolean, []}
      assert T.null() == {:null, []}
    end

    test "everything else is {kind, payload, opts}" do
      assert T.literal("v2") == {:literal, "v2", []}
      assert T.enum([:a, :b]) == {:enum, [:a, :b], []}
      assert T.object(%{a: T.string()}) == {:object, %{a: {:string, []}}, []}
      assert T.list(T.string(), max: 5) == {:list, {:string, []}, [max: 5]}
      assert T.map_of(T.integer()) == {:map_of, {:integer, []}, []}
      assert T.tuple([T.float(), T.float()]) == {:tuple, [{:float, []}, {:float, []}], []}
      assert T.optional(T.string()) == {:optional, {:string, []}, []}
      assert T.nullable(T.string()) == {:nullable, {:string, []}, []}
      assert T.ref(:root) == {:ref, :root, []}

      assert T.union([T.integer(), T.string()], tag: :none) ==
               {:union, [{:integer, []}, {:string, []}], [tag: :none]}

      assert T.tagged(:type, %{"c" => %{r: T.float()}}) ==
               {:tagged, %{"c" => {:object, %{r: {:float, []}}, []}}, [tag: :type]}

      assert T.tagged(:type, %{"c" => T.string()}, content: :value) ==
               {:tagged, %{"c" => {:string, []}}, [content: :value, tag: :type]}
    end

    test "the format shorthands are strings carrying format:" do
      assert T.datetime() == {:string, [format: :date_time]}
      assert T.date() == {:string, [format: :date]}
      assert T.time() == {:string, [format: :time]}
      assert T.duration() == {:string, [format: :duration]}
      assert T.uuid() == {:string, [format: :uuid]}
      assert T.email() == {:string, [format: :email]}
      assert T.uri() == {:string, [format: :uri]}
      assert T.ipv4() == {:string, [format: :ipv4]}
      assert T.ipv6() == {:string, [format: :ipv6]}
      assert T.hostname() == {:string, [format: :hostname]}
      assert T.uuid(min: 36) == {:string, [format: :uuid, min: 36]}
    end

    test "default:, from: and to: are taken by every kind" do
      assert T.string(default: "x", from: "a", to: "b") ==
               {:string, [default: "x", from: "a", to: "b"]}

      assert T.list(T.string(), default: []) == {:list, {:string, []}, [default: []]}
    end
  end

  describe "canonical form" do
    test "options come back sorted, so spelling order does not change the term" do
      assert T.string(max: 5, min: 1) == T.string(min: 1, max: 5)
      assert T.string(max: 5, min: 1) == {:string, [max: 5, min: 1]}
    end

    test "a bare map is an object, at any depth" do
      assert T.list(%{a: %{b: T.string()}}) ==
               {:list, {:object, %{a: {:object, %{b: {:string, []}}, []}}, []}, []}
    end

    test "defs: are normalised too" do
      assert T.object(%{}, defs: %{tree: %{value: T.integer()}}) ==
               {:object, %{}, [defs: %{tree: {:object, %{value: {:integer, []}}, []}}]}
    end

    test "junk is handed back untouched, for validate/1 to report" do
      assert T.list(:nope) == {:list, :nope, []}
      assert T.string(:nope) == {:string, :nope}
      assert T.uuid(:nope) == {:string, :nope}
    end
  end

  describe "pick/2 and omit/2" do
    setup do
      %{user: %{id: T.uuid(), name: T.string(), email: T.email()}}
    end

    test "keep and drop named fields", %{user: user} do
      assert T.pick(user, [:id, :name]) ==
               {:object, %{id: T.uuid(), name: T.string()}, []}

      assert T.omit(user, [:email]) == {:object, %{id: T.uuid(), name: T.string()}, []}
    end

    test "object options survive", %{user: user} do
      object = T.object(user, unknown: :error)
      assert {:object, _fields, [unknown: :error]} = T.pick(object, [:id])
    end

    test "naming a field the object does not have raises", %{user: user} do
      assert_raise ArgumentError, ~r/pick\/2 names \[:nope\]/, fn -> T.pick(user, [:nope]) end
      assert_raise ArgumentError, ~r/omit\/2 names \[:nope\]/, fn -> T.omit(user, [:nope]) end
    end
  end

  describe "partial/1" do
    test "wraps every field in optional, one level deep" do
      assert T.partial(%{name: T.string(), address: %{city: T.string()}}) ==
               {:object,
                %{
                  name: {:optional, {:string, []}, []},
                  address: {:optional, {:object, %{city: {:string, []}}, []}, []}
                }, []}
    end

    test "leaves a field alone when it was never required" do
      assert T.partial(%{a: T.integer(default: 0), b: T.optional(T.string())}) ==
               {:object, %{a: {:integer, [default: 0]}, b: {:optional, {:string, []}, []}}, []}
    end

    test "carries from: and to: out to the wrapper, where they still mean something" do
      assert T.partial(%{a: T.string(min: 1, from: "A", to: "B")}) ==
               {:object, %{a: {:optional, {:string, [min: 1]}, [from: "A", to: "B"]}}, []}

      assert T.partial(%{a: T.list(T.string(), from: "A")}) ==
               {:object, %{a: {:optional, {:list, {:string, []}, []}, [from: "A"]}}, []}
    end

    test "wraps a malformed field rather than guessing" do
      assert T.partial(%{a: :junk}) == {:object, %{a: {:optional, :junk, []}}, []}
    end
  end

  describe "merge/2" do
    test "the right-hand side wins on fields and on options" do
      left = T.object(%{a: T.string()}, unknown: :strip)
      right = T.object(%{a: T.integer(), b: T.boolean()}, unknown: :error)

      assert T.merge(left, right) ==
               {:object, %{a: {:integer, []}, b: {:boolean, []}}, [unknown: :error]}
    end

    test "defs are merged, not replaced" do
      left = T.object(%{}, defs: %{a: T.string()})
      right = T.object(%{}, defs: %{b: T.integer()})

      assert T.merge(left, right) ==
               {:object, %{}, [defs: %{a: {:string, []}, b: {:integer, []}}]}

      assert T.merge(left, T.object(%{}, defs: %{a: T.string()})) ==
               {:object, %{}, [defs: %{a: {:string, []}}]}
    end

    test "defs are carried over when only one side has them" do
      defs = T.object(%{}, defs: %{a: T.string()})
      assert {:object, %{}, [defs: %{a: _}]} = T.merge(defs, %{})
      assert {:object, %{}, [defs: %{a: _}]} = T.merge(%{}, defs)
    end

    test "two defs of the same name with different schemas raise" do
      left = T.object(%{}, defs: %{a: T.string()})
      right = T.object(%{}, defs: %{a: T.integer()})

      assert_raise ArgumentError, ~r/two defs named :a/, fn -> T.merge(left, right) end
    end
  end

  describe "the composition helpers on something that is not an object" do
    test "raise, naming themselves" do
      assert_raise ArgumentError, ~r/pick\/2 expects an object/, fn ->
        T.pick(T.string(), [:a])
      end

      assert_raise ArgumentError, ~r/partial\/1 expects an object/, fn ->
        T.partial(T.string())
      end

      assert_raise ArgumentError, ~r/merge\/2 expects an object/, fn ->
        T.merge(%{}, T.string())
      end
    end

    test "raise when the options are not a keyword list" do
      assert_raise ArgumentError, ~r/options are not a keyword list/, fn ->
        T.omit({:object, %{a: T.string()}, [:bogus]}, [:a])
      end
    end
  end
end

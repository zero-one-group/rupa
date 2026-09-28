defmodule Rupa.IR do
  @moduledoc """
  The intermediate representation: what the staging pass turns a schema into.

  A schema says what you meant. The IR says what the decoder will do, in the order it will do
  it, with everything the schema only implied made explicit:

    * refs are resolved — a ref that is not on a cycle is replaced by the definition itself,
      so the decoder never looks anything up; only genuinely recursive refs stay as nodes, and
      those live in a table beside the tree
    * an object's fields become an ordered list, each with the wire key it arrives under, the
      one it leaves under, the key it takes in the decoded map, whether it is required, and
      what it defaults to — so `rename_all:`, `from:`, `to:` and `keys:` are all spent here
    * `into:` stays a bare module name on the object, checked against that module's
      `defstruct` while staging, so a backend builds the struct without asking anything
    * a scalar's constraints become an ordered list of checks
    * `enum` and `literal` become one lookup table from wire value to decoded value
    * a tagged union becomes a table from tag string to branch, with the decoded tag atom
      interned here and never from wire data

  Nothing here is a runtime artifact: a `pattern` is still its source string, not a compiled
  regex, because the module backend has to embed these nodes in generated code. Compiling the
  regex is the backend's job.

  Both backends consume this, which is the point: a feature is written once. `Rupa.explain/1`
  prints it, so what you read is what runs, whichever backend you are on.
  """

  alias Rupa.IR

  @type t ::
          IR.Scalar.t()
          | IR.Const.t()
          | IR.Object.t()
          | IR.Array.t()
          | IR.Fixed.t()
          | IR.Dict.t()
          | IR.Nullable.t()
          | IR.Union.t()
          | IR.Tagged.t()
          | IR.Ref.t()

  @typedoc "A staged schema: the root node, plus the definitions that recursion needs."
  @type program :: %{root: t(), defs: %{atom() => t()}}
end

defmodule Rupa.IR.Scalar do
  @moduledoc false

  @type check ::
          {:min, non_neg_integer()}
          | {:max, non_neg_integer()}
          | {:len, non_neg_integer()}
          | {:pattern, String.t()}
          | {:gte, number()}
          | {:gt, number()}
          | {:lte, number()}
          | {:lt, number()}
          | {:multiple_of, number()}

  @type t :: %__MODULE__{
          kind: :string | :integer | :float | :boolean | :null,
          checks: [check()],
          format: atom() | nil
        }

  @enforce_keys [:kind]
  defstruct [:kind, :format, checks: []]
end

defmodule Rupa.IR.Const do
  @moduledoc false

  @type t :: %__MODULE__{
          lookup: %{term() => term()},
          reverse: %{term() => term()},
          values: [term()]
        }

  @enforce_keys [:lookup, :reverse, :values]
  defstruct [:lookup, :reverse, :values]
end

defmodule Rupa.IR.Field do
  @moduledoc false

  @type t :: %__MODULE__{
          key: atom() | String.t(),
          from: String.t(),
          to: String.t(),
          ir: Rupa.IR.t(),
          presence: :required | :optional,
          default: :none | {:value, term()}
        }

  @enforce_keys [:key, :from, :to, :ir]
  defstruct [:key, :from, :to, :ir, presence: :required, default: :none]

  # `unknown: :keep` carries the keys no field claimed. A field claims three names -- the wire
  # key it reads, the wire key it writes, and the key it takes in the decoded map -- and once a
  # decoded key can be a string, any of the three can collide with a key the schema does not
  # know. A collision means one of them silently wins, so all three are off limits in both
  # directions rather than only the one that direction happens to read.
  @doc false
  @spec claimed([t()]) :: MapSet.t()
  def claimed(fields), do: MapSet.new(Enum.flat_map(fields, &[&1.key, &1.from, &1.to]))

  # The wire keys fields actually read. `unknown: :error` checks incoming keys against these and
  # nothing else: a field's decoded key or its `to` are not names the wire is allowed to carry, so
  # `claimed/1` (which folds all three in, to keep a passthrough extra from shadowing a field)
  # would wave through a key the schema never reads.
  @doc false
  @spec inputs([t()]) :: MapSet.t()
  def inputs(fields), do: MapSet.new(fields, & &1.from)

  # The entries of a map that no field claims, in both directions -- what `unknown: :keep`
  # carries and `unknown: :error` refuses. A struct is a map too, and a plain object handed one
  # reads its fields like any map's; its `:__struct__` is the BEAM's tag rather than data, so it
  # is neither an extra to keep nor a key to refuse. Iterated with `:maps.to_list/1`, because a
  # struct has no `Enumerable` and a comprehension over it would raise.
  @doc false
  @spec extras(map(), MapSet.t()) :: [{term(), term()}]
  def extras(%{__struct__: _module} = value, known) do
    for {key, held} <- :maps.to_list(value),
        key != :__struct__,
        not MapSet.member?(known, key),
        do: {key, held}
  end

  def extras(value, known) do
    for {key, held} <- :maps.to_list(value), not MapSet.member?(known, key), do: {key, held}
  end
end

defmodule Rupa.IR.Object do
  @moduledoc false

  @type t :: %__MODULE__{
          fields: [Rupa.IR.Field.t()],
          unknown: :strip | :error | :keep,
          into: module() | nil
        }

  defstruct fields: [], unknown: :strip, into: nil
end

defmodule Rupa.IR.Array do
  @moduledoc false

  @type check ::
          {:min, non_neg_integer()} | {:max, non_neg_integer()} | {:unique, boolean()}

  @type t :: %__MODULE__{of: Rupa.IR.t(), checks: [check()]}

  @enforce_keys [:of]
  defstruct [:of, checks: []]
end

defmodule Rupa.IR.Fixed do
  @moduledoc false

  @type t :: %__MODULE__{members: [Rupa.IR.t()]}

  defstruct members: []
end

defmodule Rupa.IR.Dict do
  @moduledoc false

  @type t :: %__MODULE__{of: Rupa.IR.t()}

  @enforce_keys [:of]
  defstruct [:of]
end

defmodule Rupa.IR.Nullable do
  @moduledoc false

  @type t :: %__MODULE__{of: Rupa.IR.t()}

  @enforce_keys [:of]
  defstruct [:of]
end

defmodule Rupa.IR.Union do
  @moduledoc false

  @type t :: %__MODULE__{members: [Rupa.IR.t()]}

  defstruct members: []
end

defmodule Rupa.IR.Branch do
  @moduledoc false

  @type t :: %__MODULE__{
          wire: String.t(),
          tag: atom(),
          ir: Rupa.IR.t(),
          drop_tag: boolean()
        }

  @enforce_keys [:wire, :tag, :ir]
  defstruct [:wire, :tag, :ir, drop_tag: false]
end

defmodule Rupa.IR.Tagged do
  @moduledoc false

  @type t :: %__MODULE__{
          tag: atom(),
          tag_wire: String.t(),
          content: atom() | nil,
          content_wire: String.t() | nil,
          branches: [Rupa.IR.Branch.t()]
        }

  @enforce_keys [:tag, :tag_wire]
  defstruct [:tag, :tag_wire, :content, :content_wire, branches: []]
end

defmodule Rupa.IR.Ref do
  @moduledoc false

  @type t :: %__MODULE__{name: atom()}

  @enforce_keys [:name]
  defstruct [:name]
end

defmodule Rupa.IR.Rewrite do
  @moduledoc false

  # IR-to-IR rewrites shared across the passes. Defined after the struct modules above so its
  # struct patterns resolve; kept out of `Rupa.IR` itself, which the same file compiles first.

  alias Rupa.IR

  @doc """
  A copy of a node with every object field's `from`/`to` collapsed to one wire name (`to`).

  `from:`/`to:` are the one way `Rupa.encode/3` stops being `Rupa.decode/3`'s inverse, which is
  exactly what a migration wants -- and exactly what breaks any check built on that inverse. Two
  such checks exist: a default is normalised by putting it through the field wire-and-back
  (`Rupa.Stage`), and an untagged union picks its branch by decoding what it encoded
  (`Rupa.Closure`/`Rupa.Codegen`). Both run against this symmetric copy, so a renamed field's
  output is not read back through its differently-named input, while the real encoders still write
  the real `to` names. It is the identity on a node with no renamed field (`from == to` already).

  A `%IR.Ref{}` is left as it is: it names a definition, and the definition is rewritten where it
  lives. A check that can reach one therefore runs against `symmetric_program/1`, never against a
  rewritten root over the original table -- that is how a renamed field inside a recursive
  definition would be read back through its input name after all.
  """
  @spec symmetric(IR.t()) :: IR.t()
  def symmetric(ir), do: rename(ir, fn field -> %{field | from: field.to} end)

  @doc "`symmetric/1` over a whole program: the root and every definition."
  @spec symmetric_program(IR.program()) :: IR.program()
  def symmetric_program(%{root: root, defs: defs}) do
    %{root: symmetric(root), defs: Map.new(defs, fn {name, ir} -> {name, symmetric(ir)} end)}
  end

  @doc """
  The mirror of `symmetric/1`: every field writes the name it reads (`from`).

  A JSON Schema document describes the wire a decoder reads, so its property names are the `from`
  names -- and a `default` written into it has to spell its keys the same way, or the document
  contradicts itself. `Rupa.JsonSchema` encodes defaults through this copy for that reason.
  """
  @spec inbound(IR.t()) :: IR.t()
  def inbound(ir), do: rename(ir, fn field -> %{field | to: field.from} end)

  @doc "`inbound/1` over a whole program: the root and every definition."
  @spec inbound_program(IR.program()) :: IR.program()
  def inbound_program(%{root: root, defs: defs}) do
    %{root: inbound(root), defs: Map.new(defs, fn {name, ir} -> {name, inbound(ir)} end)}
  end

  defp rename(%IR.Object{fields: fields} = object, fun),
    do: %{object | fields: Enum.map(fields, &fun.(%{&1 | ir: rename(&1.ir, fun)}))}

  defp rename(%IR.Array{of: inner} = array, fun), do: %{array | of: rename(inner, fun)}
  defp rename(%IR.Dict{of: inner} = dict, fun), do: %{dict | of: rename(inner, fun)}
  defp rename(%IR.Nullable{of: inner} = nullable, fun), do: %{nullable | of: rename(inner, fun)}

  defp rename(%IR.Fixed{members: members} = fixed, fun),
    do: %{fixed | members: Enum.map(members, &rename(&1, fun))}

  defp rename(%IR.Union{members: members} = union, fun),
    do: %{union | members: Enum.map(members, &rename(&1, fun))}

  defp rename(%IR.Tagged{branches: branches} = tagged, fun),
    do: %{tagged | branches: Enum.map(branches, &%{&1 | ir: rename(&1.ir, fun)})}

  defp rename(leaf, _fun), do: leaf
end

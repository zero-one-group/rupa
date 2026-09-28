defmodule Rupa.Explain do
  @moduledoc """
  Renders a staged program as text, for `Rupa.explain/1`.

  It reads the IR, not the schema and not a backend, so what it prints is what runs whichever
  backend you compiled to — and it shows the things the schema only implied: the wire keys, the
  order the fields and variants are tried in, which refs were inlined and which survived as
  recursion.
  """

  alias Rupa.IR

  @doc """
  The whole program: the root, then each definition that recursion kept.

  `Rupa.explain/1` is the way in; this takes the staged program rather than a schema or a
  codec.

      iex> {:ok, program} = Rupa.Stage.run(%{name: Rupa.T.string(min: 1)})
      iex> Rupa.Explain.render(program)
      ~s[object (1 field, unknown: strip)\\n  "name" -> :name string min=1]
  """
  @spec render(IR.program()) :: String.t()
  def render(%{root: root, defs: defs}) do
    [lines(root, 0) | Enum.map(Enum.sort(Map.to_list(defs)), &definition/1)]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  One node, in one line, with no children.

      iex> Rupa.Explain.summary(%Rupa.IR.Scalar{kind: :string, format: :uuid})
      "string format=uuid"
  """
  @spec summary(IR.t()) :: String.t()
  def summary(%IR.Object{fields: fields, unknown: unknown, into: into}) do
    "object (#{count(length(fields), "field")}, unknown: #{unknown}#{into(into)})"
  end

  def summary(%IR.Scalar{kind: kind, checks: checks, format: format}) do
    Enum.join([to_string(kind) | Enum.map(checks, &check/1) ++ formatted(format)], " ")
  end

  def summary(%IR.Const{values: values}) do
    "const #{Enum.map_join(values, " | ", &inspect/1)}"
  end

  def summary(%IR.Array{checks: checks}) do
    Enum.join(["list" | Enum.map(checks, &check/1)] ++ ["of"], " ")
  end

  def summary(%IR.Fixed{members: members}), do: "tuple (#{count(length(members), "member")}) of"

  def summary(%IR.Union{members: members}) do
    "union (#{count(length(members), "variant")}, untagged) of"
  end

  def summary(%IR.Tagged{branches: branches} = tagged) do
    Enum.join(
      ["tagged", "tag=#{inspect(tagged.tag)}"] ++
        content(tagged.content) ++ ["(#{count(length(branches), "branch")}) of"],
      " "
    )
  end

  def summary(%IR.Dict{}), do: "map of"
  def summary(%IR.Nullable{}), do: "nullable"
  def summary(%IR.Ref{name: name}), do: "ref #{inspect(name)} (recursive)"

  defp definition({name, ir}), do: ["", "defs #{inspect(name)}" | lines(ir, 1)]

  defp lines(%IR.Object{fields: fields} = object, depth) do
    width = fields |> Enum.map(&String.length(label(&1))) |> longest()
    [pad(depth) <> summary(object) | Enum.flat_map(fields, &field(&1, depth + 1, width))]
  end

  defp lines(%IR.Nullable{of: inner} = node, depth) do
    nested(node, inner, depth)
  end

  defp lines(%IR.Array{of: inner} = node, depth), do: nested(node, inner, depth)
  defp lines(%IR.Dict{of: inner} = node, depth), do: nested(node, inner, depth)

  defp lines(%IR.Fixed{members: members} = node, depth) do
    [pad(depth) <> summary(node) | Enum.flat_map(members, &lines(&1, depth + 1))]
  end

  defp lines(%IR.Union{members: members} = node, depth) do
    [pad(depth) <> summary(node) | Enum.flat_map(members, &lines(&1, depth + 1))]
  end

  defp lines(%IR.Tagged{branches: branches} = node, depth) do
    width = branches |> Enum.map(&String.length(branch_label(&1))) |> longest()

    [pad(depth) <> summary(node) | Enum.flat_map(branches, &branch(&1, depth + 1, width))]
  end

  defp lines(leaf, depth), do: [pad(depth) <> summary(leaf)]

  defp nested(node, inner, depth) do
    [pad(depth) <> summary(node) | lines(inner, depth + 1)]
  end

  defp field(%IR.Field{ir: ir} = field, depth, width) do
    head = pad(depth) <> String.pad_trailing(label(field), width) <> presence(field)

    case lines(ir, 0) do
      [only] -> [head <> " " <> String.trim_leading(only)]
      [first | rest] -> [head <> " " <> String.trim_leading(first) | shift(rest, depth)]
    end
  end

  defp branch(%IR.Branch{ir: ir} = branch, depth, width) do
    head = pad(depth) <> String.pad_trailing(branch_label(branch), width)

    case lines(ir, 0) do
      [only] -> [head <> " " <> String.trim_leading(only)]
      [first | rest] -> [head <> " " <> String.trim_leading(first) | shift(rest, depth)]
    end
  end

  defp branch_label(%IR.Branch{wire: wire, tag: tag}), do: "#{inspect(wire)} -> #{inspect(tag)}"

  defp content(nil), do: []
  defp content(name), do: ["content=#{inspect(name)}"]

  defp into(nil), do: ""
  defp into(module), do: ", into: #{inspect(module)}"

  defp shift(lines, depth), do: Enum.map(lines, fn line -> pad(depth) <> line end)

  # `from -> key` when a field reads and writes the same wire key, which is almost always, and
  # `from -> key -> to` when it does not.
  defp label(%IR.Field{key: key, from: same, to: same}), do: "#{inspect(same)} -> #{inspect(key)}"

  defp label(%IR.Field{key: key, from: from, to: to}) do
    "#{inspect(from)} -> #{inspect(key)} -> #{inspect(to)}"
  end

  defp presence(%IR.Field{default: {:value, default}}),
    do: " optional default=#{inspect(default)}"

  defp presence(%IR.Field{presence: :optional}), do: " optional"
  defp presence(%IR.Field{}), do: ""

  defp formatted(nil), do: []
  defp formatted(format), do: ["format=#{format}"]

  defp check({key, value}), do: "#{key}=#{inspect(value)}"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{plural(noun)}"

  defp plural("branch"), do: "branches"
  defp plural(noun), do: noun <> "s"

  defp longest([]), do: 0
  defp longest(widths), do: Enum.max(widths)

  defp pad(depth), do: String.duplicate("  ", depth)
end

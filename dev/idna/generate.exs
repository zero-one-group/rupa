# dev/idna/generate.exs — writes lib/rupa/format/idna/table.ex from the Unicode Character Database.
#
#     elixir dev/idna/generate.exs              # fetches UCD 17.0.0 into dev/idna/ucd/ first
#     elixir dev/idna/generate.exs --ucd DIR    # reads the same files from DIR instead
#
# `T.hostname()` accepts an A-label (`xn--...`) only if the Unicode label it decodes to is one
# IDNA2008 allows. That is a per-code-point property with no closed form: RFC 5892 derives it
# from six properties in the UCD. This script is that derivation, run once per Unicode version,
# so the library ships a table rather than the database.
#
# What it writes is data. The rules that read it are in `Rupa.Format.IDNA`. Every table holds
# only code points IDNA2008 allows (PVALID, CONTEXTJ, CONTEXTO), because a label with any other
# code point in it is refused before a second property is looked up.
#
# The files are fetched once into dev/idna/ucd/, which is gitignored. To move to a newer Unicode,
# change @version and re-run; `mix test` then says whether the format corpus still agrees.

defmodule IDNAGen do
  @version "17.0.0"
  @base "https://www.unicode.org/Public/#{@version}/ucd/"
  @files ~w(UnicodeData.txt PropList.txt DerivedCoreProperties.txt HangulSyllableType.txt
            Scripts.txt DerivedNormalizationProps.txt extracted/DerivedJoiningType.txt)

  @target Path.expand("../../lib/rupa/format/idna/table.ex", __DIR__)

  # RFC 5892 section 2.6. Every other code point's property is derived; these are fixed.
  @exceptions %{
    0x00DF => :pvalid,
    0x03C2 => :pvalid,
    0x06FD => :pvalid,
    0x06FE => :pvalid,
    0x0F0B => :pvalid,
    0x3007 => :pvalid,
    0x00B7 => :contexto,
    0x0375 => :contexto,
    0x05F3 => :contexto,
    0x05F4 => :contexto,
    0x30FB => :contexto,
    0x0640 => :disallowed,
    0x07FA => :disallowed,
    0x302E => :disallowed,
    0x302F => :disallowed,
    0x3031 => :disallowed,
    0x3032 => :disallowed,
    0x3033 => :disallowed,
    0x3034 => :disallowed,
    0x3035 => :disallowed,
    0x303B => :disallowed
  }

  @arabic_digits Enum.to_list(0x0660..0x0669) ++ Enum.to_list(0x06F0..0x06F9)

  # RFC 5892 section 2.1: the categories a letter or digit is drawn from.
  @letter_digits ~w(Ll Lu Lo Nd Lm Mn Mc)

  # RFC 5892 section 2.4: Combining Diacritical Marks for Symbols, Musical Symbols, and Ancient
  # Greek Musical Notation.
  @ignorable_blocks [0x20D0..0x20FF, 0x1D100..0x1D1FF, 0x1D200..0x1D24F]

  @scripts %{
    "Greek" => :greek,
    "Hebrew" => :hebrew,
    "Hiragana" => :hiragana,
    "Katakana" => :katakana,
    "Han" => :han
  }

  @joining %{"L" => :l, "D" => :d, "R" => :r, "T" => :t}

  def main(argv) do
    dir =
      case OptionParser.parse(argv, strict: [ucd: :string]) do
        {[ucd: dir], [], []} -> dir
        {[], [], []} -> fetch(Path.expand("ucd", __DIR__))
      end

    ucd = read(dir)
    classes = Map.new(0..0x10FFFF, fn cp -> {cp, class(cp, ucd)} end)
    allowed = for {cp, class} <- classes, class not in [:disallowed, :unassigned], do: cp
    allowed? = MapSet.new(allowed)

    check_context!(classes)

    pvalid = for cp <- allowed, classes[cp] == :pvalid, do: cp
    marks = for cp <- allowed, String.starts_with?(ucd.category[cp], "M"), do: cp
    combining = for cp <- allowed, ucd.combining[cp] != 0, do: {cp, ucd.combining[cp]}
    joining = for cp <- allowed, type = ucd.joining[cp], do: {cp, type}
    scripts = for cp <- allowed, script = ucd.script[cp], do: {cp, script}
    compositions = compositions(allowed, allowed?, ucd)

    source = module(pvalid, marks, combining, compositions, joining, scripts)
    File.mkdir_p!(Path.dirname(@target))
    File.write!(@target, [Code.format_string!(source), "\n"])

    IO.puts("""
    wrote #{Path.relative_to_cwd(@target)} from UCD #{@version}
      #{length(allowed)} code points allowed, #{length(pvalid)} of them PVALID, \
    #{length(compositions)} of them composed
    """)
  end

  # ===========================================================================
  # Reading the UCD
  # ===========================================================================

  defp fetch(dir) do
    for file <- @files, path = Path.join(dir, file), not File.exists?(path) do
      {:ok, _} = Application.ensure_all_started([:inets, :ssl])
      File.mkdir_p!(Path.dirname(path))
      IO.puts("fetching #{@base}#{file}")
      ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

      {:ok, {{_, 200, _}, _headers, body}} =
        :httpc.request(:get, {~c"#{@base}#{file}", []}, [ssl: ssl], body_format: :binary)

      File.write!(path, body)
    end

    dir
  end

  defp read(dir) do
    data = unicode_data(Path.join(dir, "UnicodeData.txt"))
    props = properties(Path.join(dir, "PropList.txt"))
    core = properties(Path.join(dir, "DerivedCoreProperties.txt"))
    normal = properties(Path.join(dir, "DerivedNormalizationProps.txt"))
    hangul = properties(Path.join(dir, "HangulSyllableType.txt"))

    %{
      category: Map.new(data, fn {cp, category, _, _} -> {cp, category} end),
      combining: Map.new(data, fn {cp, _, combining, _} -> {cp, combining} end),
      decomposition: for({cp, _, _, [_ | _] = parts} <- data, into: %{}, do: {cp, parts}),
      whitespace: set(props, "White_Space"),
      noncharacter: set(props, "Noncharacter_Code_Point"),
      join_control: set(props, "Join_Control"),
      default_ignorable: set(core, "Default_Ignorable_Code_Point"),
      unstable: set(normal, "Changes_When_NFKC_Casefolded"),
      excluded: set(normal, "Full_Composition_Exclusion"),
      old_hangul: Enum.reduce(~w(L V T), MapSet.new(), &MapSet.union(&2, set(hangul, &1))),
      script: tagged(Path.join(dir, "Scripts.txt"), @scripts),
      joining: tagged(Path.join(dir, "extracted/DerivedJoiningType.txt"), @joining)
    }
  end

  # UnicodeData.txt lists most code points one per line, and the big blocks as a First/Last pair.
  # A decomposition is kept only when it is canonical: a compatibility one starts with a `<tag>`.
  defp unicode_data(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.split(&1, ";"))
    |> Enum.chunk_while(
      nil,
      fn [code, name, category, combining, _bidi, decomposition | _], pending ->
        entry =
          {String.to_integer(code, 16), category, String.to_integer(combining),
           canonical(decomposition)}

        cond do
          String.ends_with?(name, "First>") -> {:cont, entry}
          String.ends_with?(name, "Last>") -> {:cont, span(pending, entry), nil}
          true -> {:cont, [entry], nil}
        end
      end,
      fn _ -> {:cont, nil} end
    )
    |> Enum.concat()
  end

  defp canonical("<" <> _compatibility), do: []
  defp canonical(parts), do: parts |> String.split() |> Enum.map(&String.to_integer(&1, 16))

  defp span({first, category, combining, _}, {last, _, _, _}) do
    for cp <- first..last, do: {cp, category, combining, []}
  end

  # The other files share one shape: `XXXX` or `XXXX..YYYY`, a semicolon, a value, a comment.
  defp properties(path) do
    for line <- File.stream!(path),
        [data | _] = String.split(line, "#", parts: 2),
        [range, value | _] <- [String.split(data, ";") |> Enum.map(&String.trim/1)],
        range != "",
        cp <- range(range),
        do: {value, cp}
  end

  defp range(text) do
    case String.split(text, "..") do
      [one] -> [String.to_integer(one, 16)]
      [first, last] -> String.to_integer(first, 16)..String.to_integer(last, 16)
    end
  end

  defp set(pairs, name), do: for({^name, cp} <- pairs, into: MapSet.new(), do: cp)

  defp tagged(path, names) do
    for {value, cp} <- properties(path), tag = names[value], into: %{}, do: {cp, tag}
  end

  # ===========================================================================
  # RFC 5892 section 3, in its own order
  # ===========================================================================

  defp class(cp, ucd) do
    category = ucd.category[cp]

    cond do
      Map.has_key?(@exceptions, cp) -> @exceptions[cp]
      cp in @arabic_digits -> :contexto
      category == nil and not MapSet.member?(ucd.noncharacter, cp) -> :unassigned
      cp == ?- or cp in ?0..?9 or cp in ?a..?z -> :pvalid
      MapSet.member?(ucd.join_control, cp) -> :contextj
      MapSet.member?(ucd.unstable, cp) -> :disallowed
      ignorable?(cp, ucd) -> :disallowed
      Enum.any?(@ignorable_blocks, &(cp in &1)) -> :disallowed
      MapSet.member?(ucd.old_hangul, cp) -> :disallowed
      category in @letter_digits -> :pvalid
      true -> :disallowed
    end
  end

  defp ignorable?(cp, ucd) do
    MapSet.member?(ucd.default_ignorable, cp) or MapSet.member?(ucd.whitespace, cp) or
      MapSet.member?(ucd.noncharacter, cp)
  end

  # `Rupa.Format.IDNA` names the contextual code points itself, one rule each, so the derivation
  # has to agree with it rather than be trusted to.
  defp check_context!(classes) do
    contextj = for {cp, :contextj} <- classes, do: cp
    contexto = for {cp, :contexto} <- classes, do: cp
    expected = Enum.sort([0x00B7, 0x0375, 0x05F3, 0x05F4, 0x30FB | @arabic_digits])

    Enum.sort(contextj) == [0x200C, 0x200D] or raise "CONTEXTJ is #{inspect(contextj)}"
    Enum.sort(contexto) == expected or raise "CONTEXTO is #{inspect(contexto)}"
  end

  # ===========================================================================
  # Normalization, restricted to what a label can hold
  # ===========================================================================

  # A U-label has to be in NFC, and checking that needs the canonical decompositions of the code
  # points a label can hold. Every one of them turns out to be a primary composite of two allowed
  # code points — a singleton or an excluded composite changes under NFC, so IDNA2008 already
  # disallows it — and this asserts that rather than assuming it, because it is what lets
  # `Rupa.Format.IDNA` compose with this table alone.
  #
  # Hangul syllables are left out on purpose. Their jamo are disallowed, so no label can hold a
  # jamo for a syllable to compose with, and every syllable in a label is already in NFC.
  defp compositions(allowed, allowed?, ucd) do
    composites =
      for cp <- allowed, cp not in 0xAC00..0xD7A3, parts = ucd.decomposition[cp] do
        [first, second] = parts
        true = MapSet.member?(allowed?, first) and MapSet.member?(allowed?, second)
        false = MapSet.member?(ucd.excluded, cp)
        {cp, first, second}
      end

    Enum.sort(composites)
  end

  # ===========================================================================
  # Writing the module
  # ===========================================================================

  defp module(pvalid, marks, combining, compositions, joining, scripts) do
    """
    defmodule Rupa.Format.IDNA.Table do
      @moduledoc false

      # Generated by dev/idna/generate.exs from the Unicode Character Database #{@version}.
      # Do not edit: change the script and re-run it.
      #
      # Every table holds only code points IDNA2008 allows. Looking a disallowed code point up in
      # any of them answers "not listed", which is the right answer for the only caller:
      # `Rupa.Format.IDNA` refuses such a label before it asks anything else.

      @pvalid #{set_literal(pvalid)}

      @marks #{set_literal(marks)}

      @combining #{tagged_literal(combining, &Integer.to_string/1)}

      @joining #{tagged_literal(joining, &inspect/1)}

      @scripts #{tagged_literal(scripts, &inspect/1)}

      # {composite, first, second}, in composite order.
      @compositions #{literal(compositions, fn {cp, a, b} -> "{#{hex(cp)}, #{hex(a)}, #{hex(b)}}" end)}

      @composed Map.new(Tuple.to_list(@compositions), fn {cp, a, b} -> {{a, b}, cp} end)

      @decomposed Map.new(Tuple.to_list(@compositions), fn {cp, a, b} -> {cp, {a, b}} end)

      @doc "RFC 5892's PVALID: allowed anywhere in a label."
      @spec pvalid?(char()) :: boolean()
      def pvalid?(cp), do: find(@pvalid, cp) != nil

      @doc "General_Category M: a label may not begin with one."
      @spec mark?(char()) :: boolean()
      def mark?(cp), do: find(@marks, cp) != nil

      @doc "Canonical_Combining_Class: 0 for a starter, 9 for a virama."
      @spec combining(char()) :: non_neg_integer()
      def combining(cp), do: tag(find(@combining, cp), 0)

      @doc "The primary composite of two code points, if there is one."
      @spec compose(char(), char()) :: char() | nil
      def compose(first, second), do: Map.get(@composed, {first, second})

      @doc "The two code points a primary composite decomposes to, if it is one."
      @spec decompose(char()) :: {char(), char()} | nil
      def decompose(cp), do: Map.get(@decomposed, cp)

      @doc "Joining_Type, where it is one of the four the ZWNJ rule reads."
      @spec joining(char()) :: :l | :d | :r | :t | nil
      def joining(cp), do: tag(find(@joining, cp), nil)

      @doc "Script, where it is one of the five a contextual rule reads."
      @spec script(char()) :: :greek | :hebrew | :hiragana | :katakana | :han | nil
      def script(cp), do: tag(find(@scripts, cp), nil)

      defp tag({_first, _last, tag}, _default), do: tag
      defp tag(nil, default), do: default

      defp find(table, cp), do: find(table, cp, 0, tuple_size(table) - 1)

      defp find(_table, _cp, low, high) when low > high, do: nil

      defp find(table, cp, low, high) do
        middle = div(low + high, 2)
        range = elem(table, middle)

        cond do
          cp < elem(range, 0) -> find(table, cp, low, middle - 1)
          cp > elem(range, 1) -> find(table, cp, middle + 1, high)
          true -> range
        end
      end
    end
    """
  end

  defp set_literal(cps) do
    cps
    |> Enum.map(&{&1, true})
    |> ranges()
    |> literal(fn {first, last, _} -> "{#{hex(first)}, #{hex(last)}}" end)
  end

  defp tagged_literal(pairs, render) do
    pairs
    |> ranges()
    |> literal(fn {first, last, tag} -> "{#{hex(first)}, #{hex(last)}, #{render.(tag)}}" end)
  end

  defp literal(ranges, render), do: "{" <> Enum.map_join(ranges, ", ", render) <> "}"

  # Consecutive code points with the same tag collapse into one range; a gap never does.
  defp ranges(pairs) do
    pairs
    |> Enum.sort()
    |> Enum.reduce([], fn
      {cp, tag}, [{first, last, tag} | rest] when cp == last + 1 -> [{first, cp, tag} | rest]
      {cp, tag}, acc -> [{cp, cp, tag} | acc]
    end)
    |> Enum.reverse()
  end

  defp hex(cp), do: "0x" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
end

IDNAGen.main(System.argv())

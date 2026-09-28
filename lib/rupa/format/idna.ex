defmodule Rupa.Format.IDNA do
  @moduledoc false

  # An A-label is `xn--` followed by the Punycode (RFC 3492) of a Unicode label, and
  # `T.hostname()` takes one only if that Unicode label is one IDNA2008 allows: RFC 5891 section
  # 5.4's checks, with RFC 5892's code point properties and contextual rules. The one check left
  # out is the Bidi rule (RFC 5893): nothing in the format corpus tests it, and it would need a
  # Bidi_Class table beside the others.
  #
  # `Rupa.Format` only calls this on a label that already passed its LDH check, so the input is
  # ASCII letters, digits and hyphens, at most 63 of them.

  alias Rupa.Format.IDNA.Table

  @base 36
  @tmin 1
  @tmax 26
  @skew 38
  @damp 700
  @initial_bias 72
  @initial_n 128

  @zwnj 0x200C
  @zwj 0x200D

  @doc "Whether `label` is an A-label."
  @spec a_label?(String.t()) :: boolean()
  def a_label?(label) do
    with "xn--" <> encoded when encoded != "" <- String.downcase(label, :ascii),
         {:ok, points} <- decode(encoded),
         true <- Enum.any?(points, &(&1 >= @initial_n)),
         true <- encode(points) == encoded do
      u_label?(points)
    else
      _other -> false
    end
  end

  # ===========================================
  # The U-label
  # ===========================================

  # Every code point first, because the tables behind the other checks only list the code points
  # IDNA2008 allows: asking one about anything else would answer "not listed", which is only the
  # right answer once the label is known to hold nothing else.
  defp u_label?(points) do
    Enum.all?(points, &allowed?/1) and nfc?(points) and hyphens?(points) and
      not Table.mark?(hd(points)) and context?(List.to_tuple(points))
  end

  defp allowed?(cp), do: Table.pvalid?(cp) or context_point?(cp)

  defp context_point?(cp) do
    cp in [@zwnj, @zwj, 0x00B7, 0x0375, 0x05F3, 0x05F4, 0x30FB] or arabic_indic?(cp) or
      extended_arabic_indic?(cp)
  end

  defp arabic_indic?(cp), do: cp in 0x0660..0x0669
  defp extended_arabic_indic?(cp), do: cp in 0x06F0..0x06F9

  # RFC 5891 section 4.2.3.1: no hyphen at either end, and none in both the third and fourth
  # positions, which is the shape reserved for prefixes like `xn--`.
  defp hyphens?([?- | _rest]), do: false
  defp hyphens?([_first, _second, ?-, ?- | _rest]), do: false
  defp hyphens?(points), do: List.last(points) != ?-

  defp context?(label) do
    Enum.all?(0..(tuple_size(label) - 1), fn at -> rule(label, at, elem(label, at)) end)
  end

  # RFC 5892 appendix A, one clause per rule. Anything else is PVALID and has no rule.
  defp rule(label, at, @zwnj), do: virama_before?(label, at) or joins?(label, at)
  defp rule(label, at, @zwj), do: virama_before?(label, at)
  defp rule(label, at, 0x00B7), do: point(label, at - 1) == ?l and point(label, at + 1) == ?l
  defp rule(label, at, 0x0375), do: script(point(label, at + 1)) == :greek

  defp rule(label, at, cp) when cp in [0x05F3, 0x05F4],
    do: script(point(label, at - 1)) == :hebrew

  defp rule(label, _at, 0x30FB) do
    label |> Tuple.to_list() |> Enum.any?(&(script(&1) in [:hiragana, :katakana, :han]))
  end

  defp rule(label, _at, cp) when cp in 0x0660..0x0669,
    do: not Enum.any?(Tuple.to_list(label), &extended_arabic_indic?/1)

  defp rule(label, _at, cp) when cp in 0x06F0..0x06F9,
    do: not Enum.any?(Tuple.to_list(label), &arabic_indic?/1)

  defp rule(_label, _at, _cp), do: true

  defp virama_before?(label, at) do
    case point(label, at - 1) do
      nil -> false
      cp -> Table.combining(cp) == 9
    end
  end

  # `(Joining_Type:{L,D})(Joining_Type:T)*\u200C(Joining_Type:T)*(Joining_Type:{R,D})`: walk out
  # from the joiner in both directions, past the transparent ones.
  defp joins?(label, at) do
    joining(label, at - 1, -1) in [:l, :d] and joining(label, at + 1, 1) in [:r, :d]
  end

  defp joining(label, at, step) do
    case point(label, at) do
      nil ->
        nil

      cp ->
        case Table.joining(cp) do
          :t -> joining(label, at + step, step)
          type -> type
        end
    end
  end

  defp point(label, at) when at >= 0 and at < tuple_size(label), do: elem(label, at)
  defp point(_label, _at), do: nil

  defp script(nil), do: nil
  defp script(cp), do: Table.script(cp)

  # ===========================================
  # NFC, over the code points a label can hold
  # ===========================================

  # `:unicode.characters_to_nfc_list/1` would do, except that OTP composes only onto the first
  # code point of a grapheme cluster. A Tamil vowel sign written precomposed, as in கொ (U+0B95
  # U+0BCA), comes back decomposed, so a valid label would be refused. The table holds what
  # composing needs for every code point a label can hold, and this is UAX #15 over it:
  # decompose, put each run of combining marks in order, compose, and compare.
  defp nfc?(points),
    do: points |> Enum.flat_map(&decompose/1) |> reorder([], []) |> compose() == points

  defp decompose(cp) do
    case Table.decompose(cp) do
      nil -> [cp]
      {first, second} -> decompose(first) ++ decompose(second)
    end
  end

  # A run of non-starters is sorted by combining class, stably, and a starter ends the run.
  defp reorder([cp | rest], run, done) do
    case Table.combining(cp) do
      0 -> reorder(rest, [], [cp | sorted(run, done)])
      class -> reorder(rest, [{class, cp} | run], done)
    end
  end

  defp reorder([], run, done), do: Enum.reverse(sorted(run, done))

  defp sorted(run, done) do
    run
    |> Enum.reverse()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(done, fn {_class, cp}, done -> [cp | done] end)
  end

  defp compose(points), do: compose(points, nil, [], [])

  # `starter` is the last starter seen, `kept` what followed it and did not compose into it (all
  # non-starters, most recent first), and `done` everything before the starter, reversed. A code
  # point composes into the starter unless something kept between them blocks it: a combining
  # class at least as high as its own.
  defp compose([cp | rest], starter, kept, done) do
    class = Table.combining(cp)

    case starter != nil and not blocked?(kept, class) and Table.compose(starter, cp) do
      composite when is_integer(composite) -> compose(rest, composite, kept, done)
      _none when class == 0 -> compose(rest, cp, [], flush(starter, kept, done))
      _none -> compose(rest, starter, [cp | kept], done)
    end
  end

  defp compose([], starter, kept, done), do: Enum.reverse(flush(starter, kept, done))

  defp blocked?([], _class), do: false
  defp blocked?([last | _kept], class), do: Table.combining(last) >= class

  defp flush(nil, kept, done), do: kept ++ done
  defp flush(starter, kept, done), do: kept ++ [starter | done]

  # ===========================================
  # Punycode, RFC 3492 section 6
  # ===========================================

  # Everything before the last hyphen is copied through; everything after it is a run of
  # variable-length integers, each saying where to insert the next code point.
  defp decode(encoded) do
    {basic, deltas} =
      case :binary.matches(encoded, "-") do
        [] ->
          {[], encoded}

        matches ->
          {at, 1} = List.last(matches)
          deltas = binary_part(encoded, at + 1, byte_size(encoded) - at - 1)
          {String.to_charlist(binary_part(encoded, 0, at)), deltas}
      end

    insert(deltas, basic, length(basic), @initial_n, 0, @initial_bias)
  end

  defp insert("", output, _length, _n, _i, _bias), do: {:ok, output}

  defp insert(deltas, output, length, n, i, bias) do
    with {:ok, next, rest} <- integer(deltas, i, 1, @base, bias),
         n = n + div(next, length + 1),
         true <- n <= 0x10FFFF do
      at = rem(next, length + 1)
      bias = adapt(next - i, length + 1, i == 0)
      insert(rest, List.insert_at(output, at, n), length + 1, n, at + 1, bias)
    else
      _other -> :error
    end
  end

  # The digits are what is left of an LDH label after its last hyphen, lowercased, so every
  # byte here is one of the 36.
  defp integer(<<char, rest::binary>>, i, weight, k, bias) do
    digit = digit(char)
    i = i + digit * weight
    t = threshold(k, bias)

    if digit < t,
      do: {:ok, i, rest},
      else: integer(rest, i, weight * (@base - t), k + @base, bias)
  end

  defp integer("", _i, _weight, _k, _bias), do: :error

  defp digit(char) when char in ?a..?z, do: char - ?a
  defp digit(char) when char in ?0..?9, do: char - ?0 + 26

  defp threshold(k, bias) when k <= bias, do: @tmin
  defp threshold(k, bias) when k >= bias + @tmax, do: @tmax
  defp threshold(k, bias), do: k - bias

  defp adapt(delta, points, first?) do
    delta = if first?, do: div(delta, @damp), else: div(delta, 2)
    scale(delta + div(delta, points), 0)
  end

  defp scale(delta, k) when delta > div((@base - @tmin) * @tmax, 2),
    do: scale(div(delta, @base - @tmin), k + @base)

  defp scale(delta, k), do: k + div((@base - @tmin + 1) * delta, delta + @skew)

  # The other direction, which exists for one reason: RFC 5891 has an A-label round-trip, so an
  # encoding that decodes to the right code points by a route the encoder would never take — a
  # hyphen with nothing before it, say — is not an A-label.
  defp encode(points) do
    basic = for cp <- points, cp < @initial_n, do: cp
    prefix = if basic == [], do: [], else: basic ++ [?-]
    b = length(basic)

    points
    |> encode(@initial_n, 0, @initial_bias, b, b, prefix)
    |> IO.iodata_to_binary()
  end

  defp encode(points, _n, _delta, _bias, h, _b, output) when h == length(points), do: output

  defp encode(points, n, delta, bias, h, b, output) do
    m = points |> Enum.filter(&(&1 >= n)) |> Enum.min()
    delta = delta + (m - n) * (h + 1)

    {delta, bias, h, output} =
      Enum.reduce(points, {delta, bias, h, output}, fn
        cp, {delta, bias, h, output} when cp < m ->
          {delta + 1, bias, h, output}

        cp, {delta, bias, h, output} when cp == m ->
          output = [output | digits(delta, @base, bias)]
          {0, adapt(delta, h + 1, h == b), h + 1, output}

        _cp, state ->
          state
      end)

    encode(points, m + 1, delta + 1, bias, h, b, output)
  end

  defp digits(q, k, bias) do
    t = threshold(k, bias)

    if q < t,
      do: [character(q)],
      else: [
        character(t + rem(q - t, @base - t)) | digits(div(q - t, @base - t), k + @base, bias)
      ]
  end

  defp character(digit) when digit < 26, do: ?a + digit
  defp character(digit), do: ?0 + digit - 26
end

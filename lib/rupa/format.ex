defmodule Rupa.Format do
  @moduledoc """
  The built-in formats, and nothing else.

  A format is a fixed pair Rupa owns: a decoder from the wire string, and the encoder that
  inverts it. There is no way to add one, which is what keeps a schema pure data and keeps every
  format expressible as JSON Schema.

  Each one means what JSON Schema's format of the same name means, and the official format
  corpus is the test of that: `test/rupa/format_suite_test.exs` runs every string case in it
  and allows no disagreement. In practice:

    * `:date_time`, `:date` and `:time` are RFC 3339's `date-time`, `full-date` and
      `full-time`: four-digit years, two-digit fields, `.` for a fraction, `T` and `Z` in
      either case, and an offset on every time. A time decodes to UTC, as a date-time does, and
      a leap second (`23:59:60`, in UTC) decodes to the second before it, because `Calendar`
      has no second 60.
    * `:duration` is RFC 3339 appendix A's grammar: whole numbers, weeks only on their own, and
      a year, month and day (or hour, minute and second) nested so that none is skipped between
      two that are written. `P1Y2D` is not a duration; `P1Y0M2D` is.
    * `:email` is RFC 5321's `Mailbox`: a dot-atom or a quoted string, then `@`, then a
      hostname or an address literal (`[127.0.0.1]`, `[IPv6:::1]`). ASCII only.
    * `:hostname` is RFC 1123's, and an `xn--` label in it must be an IDNA2008 A-label:
      Punycode for a Unicode label in NFC, every code point of which RFC 5892 allows, its
      contextual rules included. The Bidi rule (RFC 5893) is the one check not applied.
    * `:uri` needs a scheme and well-formed percent-encoding; `:ipv4` and `:ipv6` are the
      dotted quad and RFC 4291's text form, with no zone id.

  Four of them change the value: `:date_time`, `:date`, `:time` and `:duration` decode to
  `DateTime`, `Date`, `Time` and `Duration`. The other six validate and hand the string back.

  `encode/2` is the inverse, and inverse is meant literally: whatever `encode/2` produces,
  `decode/2` accepts and returns what you started with. That is why it refuses what the wire
  cannot say rather than writing something close: a negative duration, a fraction of a second in
  one, a week beside another unit, a year outside `0000`–`9999`. A `DateTime` in another zone
  is written in UTC, which is where decoding it will put it.
  """

  alias Rupa.Format.IDNA

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # RFC 3339 appendix A, whose units nest: `dur-year = 1*DIGIT "Y" [dur-month]`, and so on down,
  # which is why a year and a day cannot appear without the month between them.
  @dur_time "T(?:\\d+H(?:\\d+M(?:\\d+S)?)?|\\d+M(?:\\d+S)?|\\d+S)"
  @dur_date "(?:\\d+Y(?:\\d+M(?:\\d+D)?)?|\\d+M(?:\\d+D)?|\\d+D)"
  @duration ~r/\AP(?:#{@dur_date}(?:#{@dur_time})?|#{@dur_time}|\d+W)\z/

  @percent ~r/%(?![0-9A-Fa-f]{2})/

  @formats [
    :date_time,
    :date,
    :time,
    :duration,
    :uuid,
    :email,
    :uri,
    :ipv4,
    :ipv6,
    :hostname
  ]

  defguardp digits?(a, b) when a in ?0..?9 and b in ?0..?9
  defguardp alphanumeric?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9
  defguardp hex?(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # RFC 5322's `atext`, the characters a dot-atom is made of.
  defguardp atext?(c) when alphanumeric?(c) or c in ~c"!#$%&'*+-/=?^_`{|}~"

  @doc """
  Decodes a string in the named format.

  Returns `:error` rather than a reason: the caller knows the format and the path, which is
  the whole message.

      iex> Rupa.Format.decode(:date, "2026-09-16")
      {:ok, ~D[2026-09-16]}

      iex> Rupa.Format.decode(:time, "08:30:00+07:00")
      {:ok, ~T[01:30:00]}

      iex> Rupa.Format.decode(:uuid, "not-a-uuid")
      :error
  """
  @spec decode(atom(), String.t()) :: {:ok, term()} | :error
  def decode(format, value)

  def decode(:date_time, <<date::binary-size(10), t, time::binary>>) when t in [?T, ?t] do
    with {:ok, date} <- full_date(date),
         {:ok, {hour, minute, second, microsecond, offset}} <- full_time(time) do
      local = %DateTime{
        year: date.year,
        month: date.month,
        day: date.day,
        hour: hour,
        minute: minute,
        second: min(second, 59),
        microsecond: microsecond,
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      }

      utc(local, offset, second == 60)
    end
  end

  def decode(:date_time, _value), do: :error
  def decode(:date, value), do: full_date(value)

  def decode(:time, value) do
    with {:ok, {hour, minute, second, microsecond, offset}} <- full_time(value),
         utc = Integer.mod(hour * 3600 + minute * 60 + min(second, 59) - offset, 86_400),
         true <- second < 60 or div(utc, 60) == 23 * 60 + 59 do
      {:ok, Time.from_seconds_after_midnight(utc, microsecond)}
    else
      _other -> :error
    end
  end

  def decode(:duration, value), do: duration(value)
  def decode(:uuid, value), do: matching(@uuid, value)
  def decode(:email, value), do: email(value)
  def decode(:uri, value), do: uri(value)
  def decode(:ipv4, value), do: ipv4(value)
  def decode(:ipv6, value), do: ipv6(value)
  def decode(:hostname, value), do: hostname(value)

  @doc """
  Encodes a decoded value back to its wire string.

  Returns `:error` for a value the format cannot represent — including the wrong type, since
  encoding is where a `DateTime` field finds out it was handed a string.

      iex> Rupa.Format.encode(:date, ~D[2026-09-16])
      {:ok, "2026-09-16"}

      iex> Rupa.Format.encode(:time, ~T[01:30:00])
      {:ok, "01:30:00Z"}

      iex> Rupa.Format.encode(:date, "2026-09-16")
      :error
  """
  @spec encode(atom(), term()) :: {:ok, String.t()} | :error
  def encode(format, value)

  # `is_struct/2` rather than a struct pattern: it needs the module at run time, not at compile
  # time, which keeps this file compiling on an Elixir older than `Duration`.
  def encode(:date_time, value) when is_struct(value, DateTime) do
    case DateTime.shift_zone(value, "Etc/UTC") do
      {:ok, utc} when utc.year in 0..9999 -> {:ok, DateTime.to_iso8601(utc)}
      _other -> :error
    end
  end

  def encode(:date, value) when is_struct(value, Date) and value.year in 0..9999,
    do: {:ok, Date.to_iso8601(value)}

  def encode(:time, value) when is_struct(value, Time), do: {:ok, Time.to_iso8601(value) <> "Z"}
  def encode(:duration, value) when is_struct(value, Duration), do: duration_iso(value)

  def encode(format, _value) when format in [:date_time, :date, :time, :duration], do: :error
  def encode(_format, value) when not is_binary(value), do: :error
  def encode(format, value), do: decode(format, value)

  @doc """
  Every format, in the order the documentation lists them.

      iex> length(Rupa.Format.names())
      10
  """
  @spec names() :: [atom()]
  def names, do: @formats

  defp matching(regex, value) do
    if Regex.match?(regex, value), do: {:ok, value}, else: :error
  end

  # =============================================
  # RFC 3339
  # =============================================

  # `full-date`: exactly four digits of year, so neither a sign nor a fifth digit.
  defp full_date(<<y1, y2, y3, y4, ?-, m1, m2, ?-, d1, d2>>)
       when digits?(y1, y2) and digits?(y3, y4) and digits?(m1, m2) and digits?(d1, d2) do
    {year, month, day} = {number(y1, y2) * 100 + number(y3, y4), number(m1, m2), number(d1, d2)}

    if Calendar.ISO.valid_date?(year, month, day),
      do: {:ok, %Date{year: year, month: month, day: day}},
      else: :error
  end

  defp full_date(_value), do: :error

  # The common case, a UTC date-time that is not a leap second, is already what it decodes to.
  # Anything else moves by its offset, and has to land in a year the wire can write back and, if
  # it is a leap second, on 23:59 in UTC.
  defp utc(local, 0, false), do: {:ok, local}

  defp utc(local, offset, leap?) do
    %{year: year, month: month, day: day, hour: hour, minute: minute, second: second} = local

    seconds =
      :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})

    with true <- seconds >= offset,
         {{year, month, day}, {hour, minute, second}} <-
           :calendar.gregorian_seconds_to_datetime(seconds - offset),
         true <- year <= 9999 and (not leap? or {hour, minute} == {23, 59}) do
      {:ok,
       %{local | year: year, month: month, day: day, hour: hour, minute: minute, second: second}}
    else
      _other -> :error
    end
  end

  # `full-time`, into its fields and the offset in seconds. The second may be 60 here; whether
  # it is a leap second depends on the offset, so the caller decides.
  defp full_time(<<h1, h2, ?:, m1, m2, ?:, s1, s2, rest::binary>>)
       when digits?(h1, h2) and digits?(m1, m2) and digits?(s1, s2) do
    {hour, minute, second} = {number(h1, h2), number(m1, m2), number(s1, s2)}

    with true <- hour <= 23 and minute <= 59 and second <= 60,
         {:ok, microsecond, rest} <- fraction(rest),
         {:ok, offset} <- offset(rest) do
      {:ok, {hour, minute, second, microsecond, offset}}
    else
      _other -> :error
    end
  end

  defp full_time(_value), do: :error

  defp fraction(<<?., rest::binary>>), do: fraction(rest, 0, 0)
  defp fraction(rest), do: {:ok, {0, 0}, rest}

  # Digits past the sixth are read and dropped: `Time` holds microseconds.
  defp fraction(<<digit, rest::binary>>, value, count) when digit in ?0..?9 and count < 6,
    do: fraction(rest, value * 10 + digit - ?0, count + 1)

  defp fraction(<<digit, rest::binary>>, value, 6) when digit in ?0..?9,
    do: fraction(rest, value, 6)

  defp fraction(_rest, _value, 0), do: :error

  defp fraction(rest, value, count),
    do: {:ok, {value * Integer.pow(10, 6 - count), count}, rest}

  defp offset(<<z>>) when z in [?Z, ?z], do: {:ok, 0}

  defp offset(<<sign, h1, h2, ?:, m1, m2>>)
       when sign in [?+, ?-] and digits?(h1, h2) and digits?(m1, m2) do
    {hours, minutes} = {number(h1, h2), number(m1, m2)}

    cond do
      hours > 23 or minutes > 59 -> :error
      sign == ?+ -> {:ok, hours * 3600 + minutes * 60}
      true -> {:ok, -(hours * 3600 + minutes * 60)}
    end
  end

  defp offset(_rest), do: :error

  defp number(tens, ones), do: (tens - ?0) * 10 + ones - ?0

  # The regex is the grammar; the arithmetic is `Duration.from_iso8601/1`, which parses integer
  # fields exactly rather than through a float (so a value past 2^53 keeps its digits), and
  # returns an error rather than raising on the huge inputs a hand-rolled parse would choke on.
  defp duration(value) do
    with true <- Regex.match?(@duration, value),
         {:ok, duration} <- Duration.from_iso8601(value) do
      {:ok, duration}
    else
      _other -> :error
    end
  end

  defp duration_iso(duration) do
    date = [{duration.year, "Y"}, {duration.month, "M"}, {duration.day, "D"}]
    clock = [{duration.hour, "H"}, {duration.minute, "M"}, {duration.second, "S"}]
    {micro, _precision} = duration.microsecond

    cond do
      negative?(duration) or micro != 0 -> :error
      duration.week == 0 -> {:ok, iso("P" <> span(date) <> marked(span(clock)))}
      Enum.all?(date ++ clock, &zero?/1) -> {:ok, "P#{duration.week}W"}
      true -> :error
    end
  end

  defp negative?(duration) do
    {micro, precision} = duration.microsecond

    Enum.any?([duration.year, duration.month, duration.week, duration.day], &(&1 < 0)) or
      Enum.any?([duration.hour, duration.minute, duration.second, micro, precision], &(&1 < 0))
  end

  # Every unit from the first non-zero one to the last is written, zeros included, because the
  # grammar nests them: a year and a day need the month between them.
  defp span(units) do
    units
    |> Enum.drop_while(&zero?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&zero?/1)
    |> Enum.reverse()
    |> Enum.map_join(fn {amount, mark} -> "#{amount}#{mark}" end)
  end

  defp zero?({amount, _mark}), do: amount == 0

  defp marked(""), do: ""
  defp marked(clock), do: "T" <> clock

  # "P" on its own is not a duration, and a duration of nothing is written "PT0S".
  defp iso("P"), do: "PT0S"
  defp iso(rendered), do: rendered

  # =============================================
  # Addresses
  # =============================================

  # RFC 5321 section 4.1.2, scanned rather than matched: a dot-atom or a quoted string, then the
  # `@`. A quoted string takes printable ASCII, with a backslash escaping any one of them, so it
  # can hold an `@` of its own.
  defp email(value) do
    case local_part(value) do
      {:ok, domain} -> if mail_domain?(domain), do: {:ok, value}, else: :error
      :error -> :error
    end
  end

  defp local_part(<<?", rest::binary>>), do: quoted(rest)
  defp local_part(value), do: dot_atom(value)

  defp quoted(<<?", ?@, domain::binary>>), do: {:ok, domain}
  defp quoted(<<?\\, c, rest::binary>>) when c in 0x20..0x7E, do: quoted(rest)
  defp quoted(<<c, rest::binary>>) when c in 0x20..0x7E and c not in [?", ?\\], do: quoted(rest)
  defp quoted(_rest), do: :error

  defp dot_atom(<<c, rest::binary>>) when atext?(c), do: atom(rest)
  defp dot_atom(_rest), do: :error

  defp atom(<<?@, domain::binary>>), do: {:ok, domain}
  defp atom(<<?., rest::binary>>), do: dot_atom(rest)
  defp atom(<<c, rest::binary>>) when atext?(c), do: atom(rest)
  defp atom(_rest), do: :error

  defp mail_domain?("[" <> literal) do
    case :binary.split(literal, "]") do
      [address, ""] -> address_literal?(address)
      _other -> false
    end
  end

  defp mail_domain?(domain), do: hostname(domain) != :error

  # `IPv6:` is a tag, and ABNF strings are case-insensitive; anything untagged is IPv4.
  defp address_literal?(<<tag::binary-size(5), address::binary>> = literal) do
    if String.downcase(tag, :ascii) == "ipv6:",
      do: ipv6(address) != :error,
      else: ipv4(literal) != :error
  end

  defp address_literal?(literal), do: ipv4(literal) != :error

  # An address is ASCII, so the byte check goes first: it keeps `to_charlist/1` away from bytes
  # that are not UTF-8 (which would raise), and it refuses what `:inet` reads leniently — a
  # leading `+` on an octet, or a zone id after an IPv6 address.
  defp ipv4(value) do
    if only?(value, &(&1 in ?0..?9 or &1 == ?.)),
      do: address(:inet.parse_ipv4strict_address(to_charlist(value)), value),
      else: :error
  end

  defp ipv6(value) do
    if only?(value, &(hex?(&1) or &1 in [?:, ?.])),
      do: address(:inet.parse_ipv6strict_address(to_charlist(value)), value),
      else: :error
  end

  defp only?(<<c, rest::binary>>, allowed?), do: allowed?.(c) and only?(rest, allowed?)
  defp only?(<<>>, _allowed?), do: true

  defp address({:ok, _tuple}, value), do: {:ok, value}
  defp address({:error, _reason}, _value), do: :error

  defp hostname(value) when byte_size(value) > 253, do: :error

  defp hostname(value) do
    if labels?(value, 0, false) and a_labels?(value), do: {:ok, value}, else: :error
  end

  # RFC 1123: dot-separated labels of 1-63 letters, digits and hyphens, none starting or ending
  # with a hyphen. `length` is the current label's so far and `hyphen?` whether it ends in one.
  defp labels?(<<?., rest::binary>>, length, false) when length > 0, do: labels?(rest, 0, false)

  defp labels?(<<c, rest::binary>>, length, _hyphen?) when alphanumeric?(c) and length < 63,
    do: labels?(rest, length + 1, false)

  defp labels?(<<?-, rest::binary>>, length, _hyphen?) when length in 1..62,
    do: labels?(rest, length + 1, true)

  defp labels?(<<>>, length, hyphen?), do: length > 0 and not hyphen?
  defp labels?(_rest, _length, _hyphen?), do: false

  # An `xn--` label is Punycode for a Unicode label, and is a hostname only if that label is one
  # IDNA2008 allows. Nothing else can hold `--`, so the common case never splits.
  defp a_labels?(value) do
    :binary.match(value, "--") == :nomatch or
      value |> :binary.split(".", [:global]) |> Enum.all?(&(not ace?(&1) or IDNA.a_label?(&1)))
  end

  defp ace?(<<x, n, ?-, ?-, _rest::binary>>) when x in [?x, ?X] and n in [?n, ?N], do: true
  defp ace?(_label), do: false

  # `URI.new/1` reaches `:uri_string`, which raises rather than returning an error on invalid
  # UTF-8, so the same guard fronts it. It also takes `%` followed by anything, which RFC 3986
  # does not.
  defp uri(value) do
    with true <- String.valid?(value),
         false <- Regex.match?(@percent, value),
         {:ok, %URI{scheme: scheme}} when not is_nil(scheme) <- URI.new(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end
end

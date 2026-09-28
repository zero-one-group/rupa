defmodule Rupa.FormatTest do
  use ExUnit.Case, async: true

  alias Rupa.Format

  doctest Rupa.Format

  describe "whole-string anchoring" do
    # PCRE's `$` also matches before a final newline, so `^...$` quietly accepted "value\n" on
    # every format checked by a regex. The official format corpus is what found it.
    test "a trailing newline is not part of the value" do
      assert Rupa.Format.decode(:uuid, "6ba7b810-9dad-11d1-80b4-00c04fd430c8\n") == :error
      assert Rupa.Format.decode(:email, "a@b.com\n") == :error
      assert Rupa.Format.decode(:hostname, "example.com\n") == :error
      assert Rupa.Format.decode(:duration, "P1D\n") == :error
    end

    test "and the value itself still decodes" do
      assert Rupa.Format.decode(:uuid, "6ba7b810-9dad-11d1-80b4-00c04fd430c8") ==
               {:ok, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"}

      assert Rupa.Format.decode(:email, "a@b.com") == {:ok, "a@b.com"}
      assert Rupa.Format.decode(:hostname, "example.com") == {:ok, "example.com"}
      assert Rupa.Format.decode(:duration, "P1D") == {:ok, Duration.new!(day: 1)}
    end
  end

  describe "the four that change the value" do
    test "date_time" do
      assert Format.decode(:date_time, "2026-09-16T10:00:00Z") == {:ok, ~U[2026-09-16 10:00:00Z]}
      assert Format.decode(:date_time, "2026-09-16") == :error
    end

    test "a date_time decodes to UTC, whatever offset it was written with" do
      assert Format.decode(:date_time, "2026-09-16T17:00:00.120+07:00") ==
               {:ok, ~U[2026-09-16 10:00:00.120Z]}

      assert Format.decode(:date_time, "2026-09-16t10:00:00z") == {:ok, ~U[2026-09-16 10:00:00Z]}
      assert Format.decode(:date_time, "2026-09-16 10:00:00Z") == :error
    end

    # `Calendar` has no second 60, so a leap second is the second before it, and only where UTC
    # had one: at 23:59.
    test "a leap second decodes to the second before it" do
      assert Format.decode(:date_time, "1998-12-31T23:59:60.5Z") ==
               {:ok, ~U[1998-12-31 23:59:59.5Z]}

      assert Format.decode(:date_time, "1998-12-31T22:59:60Z") == :error
      assert Format.decode(:time, "15:59:60-08:00") == {:ok, ~T[23:59:59]}
      assert Format.decode(:time, "23:59:60+01:00") == :error
    end

    # The wire has four digits of year, so a value whose UTC year needs five could not be written
    # back. It is refused on the way in rather than on the way out.
    test "a date_time whose UTC year leaves 0000-9999 is refused" do
      assert Format.decode(:date_time, "9999-12-31T23:30:00-01:00") == :error
      assert Format.decode(:date_time, "0000-01-01T00:30:00+01:00") == :error
      assert {:ok, _} = Format.decode(:date_time, "0000-01-01T00:30:00Z")
    end

    test "date and time" do
      assert Format.decode(:date, "2026-09-16") == {:ok, ~D[2026-09-16]}
      assert Format.decode(:date, "2026-13-01") == :error
      assert Format.decode(:date, "+2026-09-16") == :error
      assert Format.decode(:time, "10:00:00Z") == {:ok, ~T[10:00:00]}
      assert Format.decode(:time, "10:00:00") == :error
      assert Format.decode(:time, "25:00:00Z") == :error
    end

    test "a time decodes to UTC too, wrapping at midnight" do
      assert Format.decode(:time, "08:30:06.25+07:00") == {:ok, ~T[01:30:06.25]}
      assert Format.decode(:time, "00:30:00+01:00") == {:ok, ~T[23:30:00]}
      assert Format.decode(:time, "23:30:00-01:00") == {:ok, ~T[00:30:00]}
    end

    test "a fraction past microseconds is read and truncated" do
      assert Format.decode(:time, "00:59:59.123456789Z") == {:ok, ~T[00:59:59.123456]}
      assert Format.decode(:time, "00:59:59.Z") == :error
    end

    test "duration, component by component" do
      assert {:ok, whole} = Format.decode(:duration, "P1Y2M4DT5H6M7S")

      assert Map.take(whole, [:year, :month, :week, :day, :hour, :minute, :second]) ==
               %{year: 1, month: 2, week: 0, day: 4, hour: 5, minute: 6, second: 7}

      assert {:ok, weeks} = Format.decode(:duration, "P3W")
      assert weeks.week == 3

      assert {:ok, time_only} = Format.decode(:duration, "PT90M")
      assert time_only.minute == 90
    end

    # Appendix A's units nest, so none can be skipped between two that are written; weeks stand
    # alone; and there is no fraction anywhere.
    test "duration rejects what RFC 3339 rejects" do
      for value <-
            ["P", "PT", "1Y", "P1H", "-PT1S", "PT1S2H", "", "PT1.5S", "P1Y2W", "P1WT1H"] ++
              ["P1Y2D", "PT1H2S", "P1Y0M2DT1H2S"] do
        assert Format.decode(:duration, value) == :error, value
      end

      assert {:ok, _} = Format.decode(:duration, "P1Y0M2DT1H0M2S")
    end

    # `Duration.from_iso8601/1` parses the seconds field as an integer, so a value past 2^53 keeps
    # every digit. A hand-rolled `Float.parse/1` would round 9_007_199_254_740_993 down to the
    # nearest representable double and lose the trailing 3.
    test "duration keeps an integer past a double's reach exact" do
      assert {:ok, huge} = Format.decode(:duration, "PT9007199254740993S")
      assert huge.second == 9_007_199_254_740_993
    end
  end

  describe "the six that validate and hand the string back" do
    test "uuid" do
      assert Format.decode(:uuid, "6BA7B810-9DAD-11D1-80B4-00C04FD430C8") ==
               {:ok, "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"}

      assert Format.decode(:uuid, "6ba7b810-9dad-11d1-80b4-00c04fd430c") == :error
    end

    test "email" do
      for valid <-
            ["ada@example.co.id", "ada@localhost", ~s("ada lovelace"@example.com)] ++
              [~s("a@b"@example.com), "ada@[192.168.0.1]", "ada@[IPv6:2001:db8::1]"] do
        assert Format.decode(:email, valid) == {:ok, valid}, valid
      end

      for invalid <-
            ["no-at-sign", "two@@example.com", ".ada@example.com", "a..b@example.com"] ++
              ["ada@example.com.", "ada@[300.0.0.1]", "ada@[IPv6:::1", "ada@[x]"] ++
              ["ada@[IPv6:1.2.3.4]", "adá@example.com", "a b@example.com"] do
        assert Format.decode(:email, invalid) == :error, invalid
      end
    end

    test "uri, which has to be absolute and well-escaped" do
      assert Format.decode(:uri, "https://example.com/a?b=1") ==
               {:ok, "https://example.com/a?b=1"}

      assert Format.decode(:uri, "https://example.com/%20") == {:ok, "https://example.com/%20"}
      assert Format.decode(:uri, "/just/a/path") == :error
      assert Format.decode(:uri, "https://example.com/ a") == :error
      assert Format.decode(:uri, "https://example.com/%2") == :error
    end

    test "ipv4 and ipv6" do
      assert Format.decode(:ipv4, "192.168.0.1") == {:ok, "192.168.0.1"}
      assert Format.decode(:ipv4, "192.168.0.256") == :error
      assert Format.decode(:ipv4, "+1.2.3.4") == :error
      assert Format.decode(:ipv6, "2001:db8::1") == {:ok, "2001:db8::1"}
      assert Format.decode(:ipv6, "192.168.0.1") == :error
      assert Format.decode(:ipv6, "fe80::1%eth0") == :error
    end

    test "hostname" do
      assert Format.decode(:hostname, "api.example.com") == {:ok, "api.example.com"}
      assert Format.decode(:hostname, "a--b.example.com") == {:ok, "a--b.example.com"}
      assert Format.decode(:hostname, "-leading-hyphen.com") == :error
      assert Format.decode(:hostname, String.duplicate("a", 254)) == :error
    end

    # `decode/3` can be handed a binary that never went through the JSON parser, so a non-UTF-8
    # one has to be a plain :error rather than a raise out of `to_charlist/1` or `:uri_string`.
    test "the charlist and URI formats do not raise on a non-UTF-8 binary" do
      assert Format.decode(:ipv4, <<255, 1, 2>>) == :error
      assert Format.decode(:ipv6, <<255, 1, 2>>) == :error
      assert Format.decode(:uri, <<"http://", 255>>) == :error
      assert Format.decode(:email, <<255, "@example.com">>) == :error
    end
  end

  # The corpus has thirty-eight A-label cases (format_suite_test.exs); these are the paths
  # through `Rupa.Format.IDNA` it does not reach.
  describe "hostname A-labels" do
    test "an xn-- label is checked, in either case, in any position" do
      assert Format.decode(:hostname, "xn--caf-dma.example") == {:ok, "xn--caf-dma.example"}

      assert Format.decode(:hostname, "www.XN--CAF-DMA.example") ==
               {:ok, "www.XN--CAF-DMA.example"}

      assert Format.decode(:hostname, "www.xn--caf-dm.example") == :error
    end

    test "the Punycode has to decode, to something that is not ASCII, by the encoder's route" do
      for label <- ["xn--", "xn--abc-", "xn--99999999", "xn---caf-dma", "xn--caf-dmA"] do
        expected = if label == "xn--caf-dmA", do: {:ok, label}, else: :error
        assert Format.decode(:hostname, label) == expected, label
      end
    end

    test "the Unicode label has to be in NFC" do
      # e + U+0301 composes to é, so the decomposed spelling is not a U-label.
      assert Format.decode(:hostname, "xn--e-xbb") == :error
      # a + U+0323 + U+0301 composes only as far as ạ, which leaves U+0301 standing.
      assert Format.decode(:hostname, "xn--a-xbb5h") == :error
      # b has no composite with U+0301, so b + U+0301 + c is already NFC.
      assert Format.decode(:hostname, "xn--bc-8tb") == {:ok, "xn--bc-8tb"}
    end

    test "no hyphen at either end of the Unicode label" do
      assert Format.decode(:hostname, "xn----eha") == :error
      assert Format.decode(:hostname, "xn----dha") == :error
    end

    # RFC 5892 A.1: a ZWNJ needs a virama before it, or a joining letter on each side with only
    # transparent marks between.
    test "a zero width non-joiner between joining letters, past a transparent mark" do
      assert Format.decode(:hostname, "xn--ngba7iz95i") == {:ok, "xn--ngba7iz95i"}
      assert Format.decode(:hostname, "xn--ab-j1t") == :error
      # A joining letter before it and the end of the label after.
      assert Format.decode(:hostname, "xn--ngb073k") == :error
    end
  end

  describe "encode/2" do
    test "is the inverse of decode/2, for every format" do
      for {format, wire} <- [
            date_time: "2026-09-16T10:00:00Z",
            date: "2026-09-16",
            time: "10:00:00Z",
            duration: "P1Y2M4DT5H6M7S",
            uuid: "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
            email: "ada@example.com",
            uri: "https://example.com/a",
            ipv4: "192.168.0.1",
            ipv6: "2001:db8::1",
            hostname: "api.example.com"
          ] do
        assert {:ok, decoded} = Format.decode(format, wire)
        assert Format.encode(format, decoded) == {:ok, wire}, "#{format} did not round-trip"
      end
    end

    test "a duration of nothing is written the way RFC 3339 writes it" do
      assert Format.encode(:duration, struct!(Duration, [])) == {:ok, "PT0S"}
      assert Format.decode(:duration, "PT0S") == {:ok, struct!(Duration, [])}
    end

    test "a duration writes the zero units the grammar needs between two others" do
      assert Format.encode(:duration, struct!(Duration, year: 1, day: 2)) == {:ok, "P1Y0M2D"}
      assert Format.encode(:duration, struct!(Duration, hour: 1, second: 2)) == {:ok, "PT1H0M2S"}
      assert Format.encode(:duration, struct!(Duration, week: 3)) == {:ok, "P3W"}
    end

    test "a duration the format has no syntax for is refused rather than mangled" do
      assert Format.encode(:duration, struct!(Duration, second: -1)) == :error
      assert Format.encode(:duration, struct!(Duration, microsecond: {-1, 1})) == :error
      assert Format.encode(:duration, struct!(Duration, second: 1, microsecond: {5, 6})) == :error
      assert Format.encode(:duration, struct!(Duration, week: 1, day: 1)) == :error
    end

    test "a time goes out in UTC, which is where it came back from" do
      assert Format.encode(:time, ~T[01:30:06.25]) == {:ok, "01:30:06.25Z"}
    end

    test "a date_time in another zone goes out in UTC" do
      {:ok, jakarta} = Format.decode(:date_time, "2026-09-16T10:00:00Z")
      jakarta = %{jakarta | time_zone: "Asia/Jakarta", zone_abbr: "WIB", utc_offset: 25_200}
      jakarta = %{jakarta | hour: 17}

      assert Format.encode(:date_time, jakarta) == {:ok, "2026-09-16T10:00:00Z"}
    end

    test "a year the wire has no four digits for is refused" do
      assert Format.encode(:date, Date.new!(10_000, 1, 1)) == :error
      assert Format.encode(:date, Date.new!(-1, 1, 1)) == :error
      assert Format.encode(:date_time, DateTime.new!(Date.new!(-1, 1, 1), ~T[00:00:00])) == :error
    end

    test "the wrong type is an error, not a crash" do
      assert Format.encode(:date, "2026-09-16") == :error
      assert Format.encode(:date_time, ~D[2026-09-16]) == :error
      assert Format.encode(:duration, 1) == :error
      assert Format.encode(:uuid, 1) == :error
      assert Format.encode(:uuid, "nope") == :error
    end
  end

  test "names/0 is the whole set, and Rupa.Schema agrees with it" do
    assert Format.names() == Rupa.Schema.formats()
  end
end

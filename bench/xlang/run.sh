#!/usr/bin/env bash
# bench/xlang/run.sh — runs all five, several times, and prints one table.
#
# Each program prints exactly one line, `<name> <ns/op> <iterations>`, so this file does no
# parsing worth the name and any one of them can be run on its own. bench/xlang/README.md says
# what is being timed and where the columns differ.

set -euo pipefail

# Every column reads these, so one variable re-runs all five. Raising the warmup is how you
# tell a slow library from an under-warmed one -- the JVM column is the one that needs it, and
# a number that moves when you raise this was never a measurement of the library.
export XLANG_WARMUP="${XLANG_WARMUP:-50000}"
export XLANG_ITERATIONS="${XLANG_ITERATIONS:-100000}"

# How many times each column is measured. One sample per column cannot tell a slow library
# from a noisy machine, and the failure is not hypothetical: four columns holding still while
# a fifth moves thirty percent between runs is a fact about the harness, not about the fifth.
# The passes are interleaved rather than repeated per column, so thermal drift and whatever
# else the machine is doing lands on all five equally instead of on whichever ran last.
repeats="${XLANG_REPEATS:-5}"

# The one flag the table applies to one column, and bench/xlang/README.md argues the case for
# it at length. In short: the BEAM starts a busy-waiting scheduler thread per core, so on a
# host with heterogeneous cores the thread carrying a single-threaded benchmark lands on a
# performance core or an efficiency one at the host's discretion, and the same measured work
# comes out 1.36x apart. Set XLANG_BEAM_FLAGS= to take it off and see that for yourself.
beam_flags="${XLANG_BEAM_FLAGS-+S 1:1 +sbwt none +sbwtdcpu none}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
fixture="$here/fixture.json"

# Rupa has no required dependencies, so its column needs no Hex and no `mix deps.get`: the
# library compiles from lib/ with elixirc and runs. That is worth saying out loud, because it
# is the same claim the README makes about installing it.
ebin="$(mktemp -d)"
trap 'rm -rf "$ebin"' EXIT

elixirc -o "$ebin" $(find "$repo/lib" -name '*.ex') >/dev/null

# A column that will not run is named rather than quietly dropped, and the table is still
# printed for the rest -- but the exit status says something went wrong, because a table with
# four of five rows is not the comparison this directory claims to be.
samples=()
missing=()

column() {
  local name="$1" out sample
  shift

  if ! out="$("$@" 2>&1)"; then
    missing+=("$name: ${out:-exited non-zero and said nothing}")
    return
  fi

  # Folding stderr in is what makes a broken column explain itself, but it also catches
  # whatever a healthy runtime decides to say there -- a locale warning, a JIT notice -- and
  # one stray line becomes a row in the table. So the sample is the line that looks like the
  # protocol, and everything else is diagnostics that only surface if there is no such line.
  sample="$(printf '%s\n' "$out" |
    awk -v n="$name" '$1 == n && $2 + 0 == $2 { line = $0 } END { print line }')"

  if [ -n "$sample" ]; then
    samples+=("$sample")
  else
    missing+=("$name: ${out:-produced no output}")
  fi
}

pass() {
  column rupa env ELIXIR_ERL_OPTIONS="$beam_flags" \
    elixir -pa "$ebin" "$here/elixir/rupa.exs" "$fixture"
  column serde_json "$here/rust/target/release/xlang-serde" "$fixture"
  column pydantic-core python3 "$here/python/main.py" "$fixture"
  column zod env -C "$here/js" node main.mjs "$fixture"
  column malli env -C "$here/clojure" clojure -M -m bench "$fixture"
}

# Progress goes to stderr: five languages times five passes is a couple of minutes, and a
# silent terminal for that long looks like a hang.
for n in $(seq 1 "$repeats"); do
  printf 'pass %s of %s\n' "$n" "$repeats" >&2
  pass
done

if [ ${#samples[@]} -eq 0 ]; then
  printf 'Every column failed:\n'
  printf '  %s\n' "${missing[@]}" | sort -u
  exit 1
fi

# Best of the passes, and how far the worst one landed above it. Best rather than mean because
# every source of noise here is additive -- another process got the core, the JIT had not
# finished, the fan had not spun up -- so the fastest pass is the closest to the library and
# the spread is the honest error bar around it.
summary="$(
  printf '%s\n' "${samples[@]}" \
    | awk '
        !($1 in best) || $2 < best[$1] { best[$1] = $2 }
        !($1 in worst) || $2 > worst[$1] { worst[$1] = $2 }
        { seen[$1]++ }
        END { for (k in seen) printf "%s %s %s %s\n", k, best[k], worst[k], seen[k] }' \
    | sort -k2 -n
)"

# serde_json is the 1.0x line: the ceiling, and the namesake. Without it there is no line, so
# the relative column is left out rather than rebased on whatever else happened to run.
baseline="$(printf '%s\n' "$summary" | awk '$1 == "serde_json" { print $2 }')"
baseline="${baseline:-0}"

printf '\n%s, %s\n' "$(uname -sm)" "$(date -u +%Y-%m-%d)"
printf '%s iterations per case, warmup %s, best of %s passes\n' \
  "$XLANG_ITERATIONS" "$XLANG_WARMUP" "$repeats"

# A flag on one column is disclosed by the table that carries it, not only by the README that
# argues for it -- a number pasted into an issue should arrive with its own asterisk.
if [ -n "$beam_flags" ]; then
  printf 'rupa column runs with %s (README: "The one flag on the table")\n\n' "$beam_flags"
else
  printf 'rupa column runs with the default scheduler settings\n\n'
fi

printf '%-16s | %12s | %10s | %10s\n' "library" "ns/op" "spread" "rel"
printf -- '---------------------------------------------------------\n'

printf '%s\n' "$summary" \
  | awk -v base="$baseline" '
      { printf "%-16s | %12.1f | %9.1f%% | ", $1, $2, ($3 - $2) / $2 * 100 }
      base > 0 { printf "%9.2fx", $2 / base }
      base <= 0 { printf "%10s", "-" }
      { printf "\n" }'

cat <<'NOTE'

Versions:
NOTE

printf '  elixir    %s on %s\n' "$(elixir --short-version)" "$(erl -noshell -eval 'io:format("OTP ~s", [erlang:system_info(otp_release)]), halt().')"
printf '  rust      %s\n' "$(rustc --version | awk '{print $2}')"
printf '  python    %s, pydantic %s\n' "$(python3 --version | awk '{print $2}')" "$(python3 -c 'import pydantic; print(pydantic.VERSION)')"
printf '  node      %s, zod %s\n' "$(node --version)" "$(cd "$here/js" && node -p "require('zod/package.json').version")"
printf '  clojure   %s\n' "$(cd "$here/clojure" && clojure -M -e '(println (clojure-version))' 2>/dev/null || echo 'not run')"

cat <<'NOTE'

ns/op is wall clock, one process at a time — the only currency five runtimes share. There is
no cross-language equivalent of the words and reductions bench/BUDGET.md is written in, which
is why this table is run by hand and published with a machine and a date beside it rather than
treated as a constant.

`spread` is how far that column's worst pass landed above its best. A few percent is the
machine's noise floor and the ns/op beside it is the library. Double digits is a column that
has not settled — raise XLANG_WARMUP, or XLANG_REPEATS, before believing either number, and do
not publish a row whose spread is larger than the gap it is being used to claim.
NOTE

if [ ${#missing[@]} -gt 0 ]; then
  printf '\nDid not run, so the table above is not the whole comparison:\n'
  printf '  %s\n' "${missing[@]}" | sort -u
  exit 1
fi

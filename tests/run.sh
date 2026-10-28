#!/usr/bin/env bash
# tests/run.sh — Stub-Test-Harness (parallel, JOBS Slots, freie Slots werden nachbesetzt).
#
# Aufruf:
#   ./tests/run.sh                 # alle Suiten, JOBS=$(nproc 2>/dev/null || echo 8)
#   JOBS=1 ./tests/run.sh          # sequenziell
#   ./tests/run.sh 33 01           # nur Suiten, deren Dateiname "33" oder "01" enthält
#
# Exit: 0 = ok, 1 = Assertion-/Prozess-/Infrastrukturfehler, 2 = ungültiges JOBS.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
source "$HERE/lib.sh"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 8)}"
case "$JOBS" in
  ''|*[!0-9]*) printf 'JOBS muss eine positive Ganzzahl sein: %s\n' "$JOBS" >&2; exit 2 ;;
esac
if [ "$JOBS" -lt 1 ]; then
  printf 'JOBS muss eine positive Ganzzahl sein: %s\n' "$JOBS" >&2
  exit 2
fi

# Auswahlfilter (Positionsargumente) -> Suite-Dateiname-Substrings.
filters=("$@")

suites=()
for suite in "$HERE"/suites/*.sh; do
  [ -f "$suite" ] || continue
  name="$(basename "$suite")"
  if [ "${#filters[@]}" -eq 0 ]; then
    suites+=("$suite")
  else
    for f in "${filters[@]}"; do
      case "$name" in *"$f"*) suites+=("$suite"); break ;; esac
    done
  fi
done
n=${#suites[@]}

START_TS="$(date +%s)"

# Jede Suite bekommt ein eigenes Run-Tempverzeichnis (Ergebnis, stdout/stderr, Exit-Code).
RUN_TMP="$(mktemp -d)"
_cleanup() { rm -rf "$RUN_TMP"; }
trap _cleanup EXIT

WORKER_PIDS=()
_on_signal() {
  local pid
  trap - INT TERM
  for pid in "${WORKER_PIDS[@]:-}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  _cleanup
  exit 130
}
trap '_on_signal' INT TERM

# Starte Suiten, höchstens JOBS gleichzeitig; freie Slots werden nachbesetzt.
i=0
running=0
while [ "$i" -lt "$n" ]; do
  while [ "$running" -lt "$JOBS" ] && [ "$i" -lt "$n" ]; do
    slot="$RUN_TMP/slot-$i"
    mkdir -p "$slot"
    suite="${suites[$i]}"
    (
      TEST_RESULTS_FILE="$slot/results.txt"
      export TEST_RESULTS_FILE
      : > "$TEST_RESULTS_FILE"
      # Nested Subshell, damit ein `exit` im Suite-Code den Exit-Code erfassbar lässt.
      # shellcheck disable=SC1090
      ( source "$suite" > "$slot/out.log" 2> "$slot/err.log" )
      printf '%s' "$?" > "$slot/exit"
    ) &
    WORKER_PIDS+=("$!")
    running=$((running + 1))
    i=$((i + 1))
  done
  [ "$i" -ge "$n" ] && break
  wait -n 2>/dev/null || true
  running=$((running - 1))
done

# Auf alle noch laufenden Kinder warten.
wait 2>/dev/null || true

pass=0; fail=0; procfail=0; infra=0
for idx in $(seq 0 $((n - 1))); do
  slot="$RUN_TMP/slot-$idx"
  name="$(basename "${suites[$idx]}")"
  # Deterministisch in Suite-Reihenfolge ausgeben (nicht in Fertigstellungsreihenfolge).
  cat "$slot/out.log" 2>/dev/null
  cat "$slot/err.log" 2>/dev/null >&2
  if [ ! -f "$slot/exit" ]; then
    printf '  [Infrastrukturfehler: keine Exit-Information für %s]\n' "$name" >&2
    infra=$((infra + 1))
    continue
  fi
  if [ ! -f "$slot/results.txt" ]; then
    printf '  [Infrastrukturfehler: keine Ergebnisdatei für %s]\n' "$name" >&2
    infra=$((infra + 1))
    continue
  fi
  rc="$(cat "$slot/exit")"
  if [ "$rc" -ne 0 ]; then
    printf '  [Suite-Prozess beendet mit Exit %s]\n' "$rc" >&2
    procfail=$((procfail + 1))
  fi
  pass=$((pass + $(grep -c '^PASS$' "$slot/results.txt" 2>/dev/null || true)))
  fail=$((fail + $(grep -c '^FAIL$' "$slot/results.txt" 2>/dev/null || true)))
done

END_TS="$(date +%s)"
elapsed=$((END_TS - START_TS))

echo ""
echo "=============================="
echo "Ergebnis: ${pass} PASS, ${fail} FAIL, ${procfail} Prozessfehler, ${infra} Infrastrukturfehler (JOBS=${JOBS}, ${elapsed}s)"
echo "=============================="

if [ "$fail" -gt 0 ] || [ "$procfail" -gt 0 ] || [ "$infra" -gt 0 ]; then
  exit 1
fi
exit 0

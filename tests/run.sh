#!/usr/bin/env bash
# tests/run.sh — Einstieg in die Stub-Test-Harness (parallel, JOBS Slots).
# Führt alle Suiten aus, höchstens JOBS gleichzeitig, und beendet mit
# Exit-Code ungleich 0, wenn ein Test fehlschlägt oder eine Suite mit
# Nichtnull-Exit abbricht.
#
# Aufruf: ./tests/run.sh          (JOBS=8)
#         JOBS=1 ./tests/run.sh   (sequenziell)
#         JOBS=4 ./tests/run.sh   (4 Slots)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
source "$HERE/lib.sh"

JOBS="${JOBS:-8}"
case "$JOBS" in
  ''|*[!0-9]*) printf 'JOBS muss eine positive Ganzzahl sein: %s\n' "$JOBS" >&2; exit 2 ;;
esac
if [ "$JOBS" -lt 1 ]; then
  printf 'JOBS muss eine positive Ganzzahl sein: %s\n' "$JOBS" >&2
  exit 2
fi

START_TS="$(date +%s)"

# Jede Suite bekommt ein eigenes Run-Tempverzeichnis (Ergebnisdatei, stdout/stderr-Logs).
RUN_TMP="$(mktemp -d)"
_cleanup() { rm -rf "$RUN_TMP"; }
trap _cleanup EXIT
trap 'trap - INT TERM; kill 0 2>/dev/null; _cleanup; exit 130' INT TERM

suites=()
for suite in "$HERE"/suites/*.sh; do
  [ -f "$suite" ] || continue
  suites+=("$suite")
done
n=${#suites[@]}

# Starte Suiten in Batches zu höchstens JOBS parallel; jede Suite in eigener Subshell.
i=0
while [ "$i" -lt "$n" ]; do
  batch=()
  j=0
  while [ "$j" -lt "$JOBS" ] && [ "$i" -lt "$n" ]; do
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
    batch+=("$!")
    i=$((i + 1)); j=$((j + 1))
  done
  for pid in "${batch[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
done

pass=0; fail=0; procfail=0
for idx in $(seq 0 $((n - 1))); do
  slot="$RUN_TMP/slot-$idx"
  # Deterministisch in Suite-Reihenfolge ausgeben (nicht in Fertigstellungsreihenfolge).
  cat "$slot/out.log" 2>/dev/null
  cat "$slot/err.log" 2>/dev/null >&2
  rc="$(cat "$slot/exit" 2>/dev/null)"; rc="${rc:-0}"
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
echo "Ergebnis: ${pass} PASS, ${fail} FAIL, ${procfail} Prozessfehler (JOBS=${JOBS}, ${elapsed}s)"
echo "=============================="

if [ "$fail" -gt 0 ] || [ "$procfail" -gt 0 ]; then
  exit 1
fi
exit 0

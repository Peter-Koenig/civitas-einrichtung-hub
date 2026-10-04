#!/usr/bin/env bash
# tests/run.sh — Einstieg in die Stub-Test-Harness.
# Führt alle Suiten aus und beendet mit Exit-Code ungleich 0, wenn ein Test fehlschlägt.
# Aufruf: ./tests/run.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./lib.sh
source "$HERE/lib.sh"

TEST_RESULTS_FILE="$(mktemp)"
export TEST_RESULTS_FILE
: > "$TEST_RESULTS_FILE"

for suite in "$HERE"/suites/*.sh; do
  [ -f "$suite" ] || continue
  # Jede Suite läuft in einer eigenen Subshell (isoliert PATH/log_*-Stubs).
  # shellcheck disable=SC1090
  ( source "$suite" )
done

pass=$(grep -c '^PASS$' "$TEST_RESULTS_FILE" 2>/dev/null || true)
fail=$(grep -c '^FAIL$' "$TEST_RESULTS_FILE" 2>/dev/null || true)

echo ""
echo "=============================="
echo "Ergebnis: ${pass} PASS, ${fail} FAIL"
echo "=============================="

rm -f "$TEST_RESULTS_FILE"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0

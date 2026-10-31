#!/usr/bin/env bash
# Suite 42: retry-Helper (02_lib.sh) — Wiederholung und Erschöpfung.

begin_suite "retry"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)

# retry wird extrahiert (statt 02_lib.sh zu sourcen), damit das `check` der
# Harness nicht durch die 02_lib-Variante überschrieben wird.
sed -n '/^retry()/,/^}/p' "$REPO/modules_V1s/02_lib.sh" > "$T/retry.sh"
log_warn() { :; }
# shellcheck disable=SC1090
source "$T/retry.sh"

# Stub-Befehl: fehlschlägt die ersten $2 Male, danach Erfolg. Zählt Aufrufe.
flaky_cmd() {
  local cnt=0 f="$1" fails="$2"
  [ -f "$f" ] && cnt=$(cat "$f")
  cnt=$((cnt + 1))
  printf '%s' "$cnt" > "$f"
  [ "$cnt" -le "$fails" ] && return 1
  return 0
}

# 1) Erfolg beim dritten Versuch (zwei Fehlversuche).
: > "$T/c1"
retry 3 0 flaky_cmd "$T/c1" 2; rc=$?
check "retry Erfolg beim 3. Versuch" "0" "$rc"
check "3 Versuche durchgeführt" "3" "$(cat "$T/c1")"

# 2) Erschöpfung nach N Versuchen -> rc 1.
: > "$T/c2"
retry 3 0 flaky_cmd "$T/c2" 99; rc=$?
check "Erschöpfung -> rc 1" "1" "$rc"
check "genau 3 Versuche" "3" "$(cat "$T/c2")"

rm -rf "$T"

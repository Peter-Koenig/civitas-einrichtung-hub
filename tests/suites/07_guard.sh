#!/usr/bin/env bash
# Suite 07: guard_placeholder_literals — Literal-Scan über Secrets/ConfigMaps.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "guard_placeholder_literals"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGBUF=$(mktemp)

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

K8S_NAMESPACES=("ns1")
KUBECONFIG_PATH="/dev/null"
VERIFY_ERRORS=0

LIT_B64=$(printf 'CHANGE_ME' | base64)

# kubectl-Funktion: liefert ein Secret mit dem Literal (base64-kodiert).
kubectl() {
  case "$*" in
    *"get secrets"*) printf '{"items":[{"metadata":{"name":"s1"},"data":{"k1":"%s"}}]}' "$LIT_B64" ;;
    *"get configmaps"*) printf '{"items":[]}' ;;
    *) printf '' ;;
  esac
}

# shellcheck source=../../modules_V1/07b_verify_phase2.sh
source "$REPO/modules_V1/07b_verify_phase2.sh"

# 07b_verify_phase2.sh definiert kein 'check'; lib.sh-Assertion verwenden.
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS" >> "${TEST_RESULTS_FILE}"
    echo "PASS: ${name}"
  else
    echo "FAIL" >> "${TEST_RESULTS_FILE}"
    echo "FAIL: ${name} (erwartet=${expected}, ist=${actual})"
  fi
}

# Treffer: Secret enthält CHANGE_ME → return 1, Ausgabe ohne Wert
: > "$LOGBUF"
VERIFY_ERRORS=0
guard_placeholder_literals; rc=$?
check "G1 Treffer -> rc=1" "1" "$rc"
check "G1 Treffer geloggt" "yes" "$(grep -q 'Platzhalter-Literal: Secret ns1/s1 key=k1' "$LOGBUF" && echo yes || echo no)"
check "G1 kein Wert geloggt" "no" "$(grep -q 'CHANGE_ME' "$LOGBUF" && echo yes || echo no)"
check "G1 VERIFY_ERRORS=1" "1" "$VERIFY_ERRORS"

# Kein Treffer: leere Items → return 0
: > "$LOGBUF"
kubectl() { case "$*" in *"get secrets"*) printf '{"items":[]}' ;; *"get configmaps"*) printf '{"items":[]}' ;; *) printf '' ;; esac; }
VERIFY_ERRORS=0
guard_placeholder_literals; rc=$?
check "G2 kein Treffer -> rc=0" "0" "$rc"

rm -f "$LOGBUF"

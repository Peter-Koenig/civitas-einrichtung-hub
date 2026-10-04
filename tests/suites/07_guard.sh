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

LIT_B64=$(printf 'CHANGE_ME' | base64)
NO_DATA_SECRET='{"metadata":{"name":"s-nodata"},"binaryData":{"b":"eA=="}}'
LIT_SECRET='{"metadata":{"name":"s1"},"data":{"k1":"'"${LIT_B64}"'"}}'
CLEAN_SECRET='{"metadata":{"name":"s-clean"},"data":{"k":"eA=="}}'
CM_WITH_CA='{"items":[{"metadata":{"name":"kube-root-ca.crt"},"data":{"ca.crt":"Zm9v"}}]}'
EMPTY='{"items":[]}'

# T1: Secret ohne data vor einem Secret mit Literal — Treffer wird gefunden,
# Ausgabe ohne Wert, rc=1.
: > "$LOGBUF"
VERIFY_ERRORS=0
kubectl() {
  case "$*" in
    *"get secrets"*) printf '{"items":[%s,%s]}' "${NO_DATA_SECRET}" "${LIT_SECRET}" ;;
    *"get configmaps"*) printf '%s' "${CM_WITH_CA}" ;;
    *) printf '' ;;
  esac
}
guard_placeholder_literals; rc=$?
check "G1 Treffer trotz Secret ohne data -> rc=1" "1" "$rc"
check "G1 Treffer geloggt" "yes" "$(grep -q 'Platzhalter-Literal: Secret ns1/s1 key=k1' "$LOGBUF" && echo yes || echo no)"
check "G1 kein Wert geloggt" "no" "$(grep -q 'CHANGE_ME' "$LOGBUF" && echo yes || echo no)"

# T2: kubectl-Fehler (Exitcode != 0) -> rc=1 (Fehler, nicht OK).
: > "$LOGBUF"
VERIFY_ERRORS=0
kubectl() { return 1; }
guard_placeholder_literals; rc=$?
check "G2 kubectl-Fehler -> rc=1" "1" "$rc"

# T3: leere ConfigMap-Ausgabe -> Sanity-Check "keine Objekte gelesen" -> rc=1.
: > "$LOGBUF"
VERIFY_ERRORS=0
kubectl() {
  case "$*" in
    *"get secrets"*) printf '%s' "${EMPTY}" ;;
    *"get configmaps"*) printf '%s' "${EMPTY}" ;;
    *) printf '' ;;
  esac
}
guard_placeholder_literals; rc=$?
check "G3 leere ConfigMaps -> rc=1" "1" "$rc"
check "G3 'keine Objekte gelesen' geloggt" "yes" "$(grep -q 'Scan hat keine Objekte gelesen' "$LOGBUF" && echo yes || echo no)"

# T4: sauberer Lauf (kein Literal, ConfigMap mit kube-root-ca.crt) -> rc=0.
: > "$LOGBUF"
VERIFY_ERRORS=0
kubectl() {
  case "$*" in
    *"get secrets"*) printf '{"items":[%s]}' "${CLEAN_SECRET}" ;;
    *"get configmaps"*) printf '%s' "${CM_WITH_CA}" ;;
    *) printf '' ;;
  esac
}
guard_placeholder_literals; rc=$?
check "G4 sauber -> rc=0" "0" "$rc"
check "G4 VERIFY_ERRORS unverändert" "0" "$VERIFY_ERRORS"

rm -f "$LOGBUF"

#!/usr/bin/env bash
# Suite 04: 02_lib.sh wait_pods_ready — Job-Pods (Succeeded) ausnehmen.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "wait_pods_ready"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log()      { :; }
log_ok()   { :; }
log_warn() { :; }
log_error(){ :; }

# shellcheck source=../../modules_V1/02_lib.sh
source "$REPO/modules_V1/02_lib.sh"

# 02_lib.sh definiert ein eigenes 'check' (VERIFY-Mechanismus); Assertion
# aus lib.sh wiederherstellen.
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

TIMEOUT_POD_READY=300

# Kein nicht-Succeeded-Pod vorhanden (kubectl-Stub liefert leere Liste) →
# wait_pods_ready gibt 0 zurück, ohne kubectl wait aufzurufen.
wait_pods_ready "ns"; rc=$?
check "wait_pods_ready kein Pod -> 0" "0" "$rc"

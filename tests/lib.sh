#!/usr/bin/env bash
# tests/lib.sh — gemeinsame Helfer für die Stub-Test-Harness.
# Wird von tests/run.sh gesourct. Keine echten Secrets, kein Cluster/Netz.

set -u

# Binde das Stub-Verzeichnis vorne in PATH ein.
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${TEST_ROOT}/stubs:${PATH}"

# Gemeinsame Ergebnisdatei (run.sh zählt am Ende die PASS/FAIL-Zeilen).
TEST_RESULTS_FILE="${TEST_RESULTS_FILE:-/tmp/civitas-test-results.$$}"

# ── Assertions ────────────────────────────────────────────────────────────────
# check <name> <expected> <actual>
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

begin_suite() {
  echo ""
  echo "=== Suite: $1 ==="
}

# ── Fixture-Helfer ────────────────────────────────────────────────────────────
# Erzeugt einen fatal:-Block (Ansible-Log-Zeile) mit dem angegebenen msg.
mk_fatal_block() {
  local out="$1" msg="$2"
  printf '2026-10-03 23:06:36,005 p=11788 u=root n=ansible | fatal: [localhost]: FAILED! => {\n    "msg": "%s"\n}\n' "${msg}" > "${out}"
}

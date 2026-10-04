#!/usr/bin/env bash
# Suite 14: write_le_backup — kein Trailing-Separator, korrekte Dokumentzahl.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "backup_write"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

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

CERT_BACKUP_FILE="$T/backup.yaml"

# kubectl-Stub: 2 Certificate-Objekte; je Secret ein YAML mit kind: Secret + tls.crt.
kubectl() {
  case "$*" in
    *"get certificate"*)
      printf '{"items":[{"metadata":{"name":"c1","namespace":"ns1"},"spec":{"secretName":"s1"}},{"metadata":{"name":"c2","namespace":"ns1"},"spec":{"secretName":"s2"}}]}'
      ;;
    *"get secret"*)
      printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: s\n  namespace: ns1\ndata:\n  tls.crt: eA==\n  tls.key: eQ==\n'
      ;;
    *) return 0 ;;
  esac
}

# shellcheck source=../../modules_V1/06a_network_certs.sh
source "$REPO/modules_V1/06a_network_certs.sh"
set +e

write_le_backup; rc=$?

check "write_le_backup rc=0" "0" "$rc"
check "2 Secret-Dokumente" "2" "$(backup_secret_doc_count "$CERT_BACKUP_FILE")"
check "letzte Zeile ist kein ---" "no" "$(tail -n 1 "$CERT_BACKUP_FILE" | grep -qx '\-\-\-' && echo yes || echo no)"

rm -rf "$T"

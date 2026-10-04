#!/usr/bin/env bash
# Suite 03: 06a_network_certs.sh — Backup-Secret-Enumeration (yq-Absicherung).
# Nur Testwerte, kein Cluster/Netz.

begin_suite "network_certs"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1/06a_network_certs.sh
source "$REPO/modules_V1/06a_network_certs.sh"
set +e

# Fixture: Backup mit drei Secret-Dokumenten.
mk_backup() {
  local f="$1" n="$2" i
  : > "$f"
  for i in $(seq 1 "$n"); do
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: host%d-tls\n  namespace: ns\n' "$i" >> "$f"
    printf '%s\n' '---' >> "$f"
  done
}

mk_backup "$T/three.yaml" 3
check "backup_secret_doc_count 3 Secrets" "3" "$(backup_secret_doc_count "$T/three.yaml")"

mk_backup "$T/zero.yaml" 0
check "backup_secret_doc_count 0 Secrets" "0" "$(backup_secret_doc_count "$T/zero.yaml")"

rm -rf "$T"

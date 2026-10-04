#!/usr/bin/env bash
# Suite 10: install_civitas — Backup wird VOR der IDM-Provisionierung
# geschrieben, damit ein IDM-Fehler das Backup nicht verliert.
# Nur Stubs, kein Cluster/Netz.

begin_suite "install_civitas_order"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"
ORDER="$T/order.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Globale aus 01_config.sh, die install_civitas benötigt.
K8S_NAMESPACES=("ns1")
WG_ENABLED=false
LE_FRESH_PROD_ISSUED=true

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

# Stubs für alle von install_civitas aufgerufenen Funktionen (nach dem Sourcen
# überschreiben sie die realen Definitionen bzw. ergänzen ausgelagerte Module).
check_dns_hard() { :; }
clone_civitas_repo() { :; }
build_geoportal_backend_image() { :; }
apply_overlay() { :; }
patch_masterportal_release_name() { :; }
install_cc_cli() { :; }
render_inventory() { :; }
setup_wireguard() { :; }
patch_playbook_urls() { :; }
cleanup_geodata_ingress() { :; }
run_cc_cli_validate() { :; }
run_cc_cli_exec() { :; }
wait_pods_ready() { return 0; }
resolve_target_state() { echo "keep_staging"; }
apply_target_state() { return 0; }
verify_certificates() { return 0; }
cluster_backup_diverges() { return 1; }
write_le_backup() { echo "WRITE_BACKUP" >> "$ORDER"; return 0; }
ensure_keycloak_admin_user() { echo "IDM" >> "$ORDER"; return 1; }
configure_pgadmin_ca_trust() { return 0; }

# install_civitas ruft bei IDM-Fehler exit 1 — in einer Subshell ausführen.
( install_civitas )
rc=$?

check "IDM-Fehler -> rc=1" "1" "$rc"
check "write_le_backup VOR IDM" "WRITE_BACKUP" "$(head -1 "$ORDER")"
check "IDM wurde aufgerufen" "yes" "$(grep -q 'IDM' "$ORDER" && echo yes || echo no)"

rm -rf "$T"

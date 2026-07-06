#!/usr/bin/env bash
#
# install_civitas_core_v2.sh — CIVITAS/CORE V2 Installationsskript
#
# Läuft auf dem Proxmox-Host ODER in der Ziel-VM:
#   - Auf dem Proxmox-Host: VM provisionieren (Phase -1), dann Anleitung für SSH
#   - In der Ziel-VM: Phase 0 (Preflight) + Phase 1a (k3s) + Phase 1b (Add-ons)
#     + Phase 2a–2d (Deployment-Repo, Preconditions, helmfile, WireGuard)
#     + Phase 3 (Verifikation)
#
# Siehe: skriptarchitektur.md (V2), installationsphasen-und-abnahme.md (V2)
#
# Aufruf (von Proxmox-Host):
#   export ROOT_PASSWORD="..."
#   export SMTP_HOST="..."
#   export SMTP_USER="..."
#   export SMTP_PASS="..."
#   export WG_VM_PRIVATE_KEY="..."
#   export WG_OPN_PUBLIC_KEY="..."
#   export WG_OPN_ENDPOINT="..."
#   ./install_civitas_core_v2.sh
#
# Optionen:
#   LOG_FILE=/var/log/civitas_install_v2.log ./install_civitas_core_v2.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Optionales File-Logging — VOR source-Aufrufen ───────────────────────────
LOG_FILE="${LOG_FILE:-}"
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# ── Module laden ─────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules_V2/01_config.sh"       # Config + Env-Var-Prüfung
source "${SCRIPT_DIR}/modules_V2/02_lib.sh"          # Hilfsfunktionen (Logging, Checks)
source "${SCRIPT_DIR}/modules_V2/00_provision_vm.sh" # Phase -1: VM-Provisionierung
source "${SCRIPT_DIR}/modules_V2/03_preflight.sh"    # Phase 0:  Preflight
source "${SCRIPT_DIR}/modules_V2/04_k3s.sh"          # Phase 1a: k3s-Cluster
source "${SCRIPT_DIR}/modules_V2/05_addons.sh"       # Phase 1b: Add-ons
source "${SCRIPT_DIR}/modules_V2/06_civitas.sh"      # Phase 2a–2d: CIVITAS/CORE-V2-Deployment
source "${SCRIPT_DIR}/modules_V2/07_verify.sh"       # Phase 3:  Verifikation

# ── Traps ────────────────────────────────────────────────────────────────────
# ERR-Trap: Exit-Code sichern, dann sauber beenden
trap 'CIVITAS_EXIT_CODE=$?
      log_error "Unerwarteter Fehler in Zeile ${LINENO}. Abbruch."
      exit "${CIVITAS_EXIT_CODE}"' ERR

trap 'log_warn "Skript durch Signal unterbrochen."; exit 130' INT TERM

trap 'CIVITAS_EXIT_CODE=${CIVITAS_EXIT_CODE:-0}
      if [[ "${CIVITAS_EXIT_CODE}" -ne 0 ]]; then
        log_warn "EXIT-Trap: Fehler erkannt (Exit ${CIVITAS_EXIT_CODE}) — temporäre Dateien bleiben für Debugging erhalten"
        log_warn "  Manueller Cleanup: rm -f \"${CONFIG_YAML_PATH:-}\"; rm -rf /tmp/civitas-core-v2-deploy-*"
      else
        log_warn "EXIT-Trap: Räume temporäre Dateien auf …"
        rm -f "${CONFIG_YAML_PATH:-}"
        rm -rf "/tmp/civitas-core-v2-deploy-*"
      fi' EXIT

# ── Startmeldung ─────────────────────────────────────────────────────────────
log "============================================"
log " CIVITAS/CORE V2 — Installation"
log " Zielplattform: Proxmox-Knoten civitas"
log " Domain:        ${DOMAIN}"
log " Environment:   ${CC_V2_ENVIRONMENT}"
log " k3s:           ${K3S_VERSION}"
log " helmfile:      ${HELMFILE_VERSION}"
log " Phase:         -1 bis 3 (VM, Preflight, k3s, Add-ons, helmfile, Verify)"
log "============================================"
log ""

# ── Phasen ausführen ─────────────────────────────────────────────────────────
provision_vm            # Phase -1: VM erstellen (nur auf Proxmox-Host)
run_preflight           # Phase 0:  Vorbedingungen (in der VM)
install_k3s             # Phase 1a: k3s-Cluster (in der VM)
install_addons          # Phase 1b: Helm, helmfile, cert-manager, nginx (in der VM)
install_civitas_v2      # Phase 2:  Repo-Setup, Preconditions, helmfile sync, WireGuard (in der VM)
run_verification        # Phase 3:  Verifikation, Fehlerreport (in der VM)

log ""
log "============================================"
log " CIVITAS/CORE V2-Installation vollständig."
log "============================================"

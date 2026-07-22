#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 CIVITAS/CORE Contributors
#
# Licensed under the EUPL, Version 1.2 only (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#   https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Licence for the specific language governing permissions and
# limitations under the Licence.
#
# install_civitas_core_V1.sh — CIVITAS/CORE V1 Installationsskript
#
# Läuft auf dem Proxmox-Host ODER in der Ziel-VM:
#   - Auf dem Proxmox-Host: VM provisionieren (Phase -1), dann automatischer
#     SSH-Hop in die VM (scp + ssh) für Phasen 0–2
#   - In der Ziel-VM: CIVITAS_CONTEXT=vm → Phasen 0–2 ohne VM-Provisionierung
#
# Siehe: skriptarchitektur.md (V1), installationsphasen-und-abnahme.md (V1)
#
# Aufruf (von Proxmox-Host):
#   export ROOT_PASSWORD="..."
#   export SMTP_HOST="..."
#   export SMTP_USER="..."
#   export SMTP_PASS="..."
#   ./install_civitas_core_V1.sh
#
# Optionen:
#   LOG_FILE=/var/log/civitas_install_v1.log ./install_civitas_core_V1.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Module laden ─────────────────────────────────────────────────────────────
# ── Optionales File-Logging — VOR source-Aufrufen ───────────────────────────
LOG_FILE="${LOG_FILE:-}"
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# ── Module laden ─────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules_V1/01_config.sh"    # Config + ROOT_PASSWORD check
source "${SCRIPT_DIR}/modules_V1/02_lib.sh"
source "${SCRIPT_DIR}/modules_V1/00_provision_vm.sh"
source "${SCRIPT_DIR}/modules_V1/03_preflight.sh"
source "${SCRIPT_DIR}/modules_V1/04_k3s.sh"
source "${SCRIPT_DIR}/modules_V1/05_addons.sh"

source "${SCRIPT_DIR}/modules_V1/06a_network_certs.sh"
source "${SCRIPT_DIR}/modules_V1/06b_idm_provisioning.sh"
source "${SCRIPT_DIR}/modules_V1/06_civitas.sh"
source "${SCRIPT_DIR}/modules_V1/07_verify.sh"
source "${SCRIPT_DIR}/modules_V1/07_login_summary.sh"

# ── Traps (DEAKTIVIERT für Debugging) ──────────────────────────────────────
# Alle Traps sind auskommentiert, damit temporäre Dateien bei Fehlern
# erhalten bleiben. Das Skript bricht bei Fehlern normal mit Exit-Code >0 ab.
#
# ERR-Trap:
# trap 'rc=$?; log_error "Unerwarteter Fehler in Zeile ${LINENO}."; exit "${rc}"' ERR
# INT/TERM-Trap:
# trap 'log_warn "Skript durch Signal unterbrochen."; exit 130' INT TERM
# EXIT-Trap (Cleanup):
# trap '...' EXIT

# ── Ausführungskontext ───────────────────────────────────────────────────────
CIVITAS_CONTEXT="${CIVITAS_CONTEXT:-host}"

# ── Funktion: Hop in die VM ──────────────────────────────────────────────────
run_in_vm() {
  # Alten SSH-Host-Key entfernen (VM wird bei jedem Scratch-Lauf neu erstellt)
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${VM_IP_STATIC}" 2>/dev/null || true
  log "Kopiere Skript-Dateien in die VM (${VM_IP_STATIC}) …"
  ssh -o StrictHostKeyChecking=no \
      "root@${VM_IP_STATIC}" \
      "mkdir -p ${VM_REMOTE_INSTALL_DIR}" \
      || { log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar"; exit 1; }
  scp -o StrictHostKeyChecking=no -r \
    "${SCRIPT_DIR}/install_civitas_core_V1.sh" \
    "${SCRIPT_DIR}/modules_V1" \
    "${SCRIPT_DIR}/templates_V1" \
    "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
    || { log_error "scp fehlgeschlagen — VM ${VM_IP_STATIC} nicht erreichbar?"; exit 1; }
  log_ok "Skript-Dateien kopiert nach ${VM_REMOTE_INSTALL_DIR}"

  if [[ -d "${SCRIPT_DIR}/overlay_V1" ]]; then
    scp -o StrictHostKeyChecking=no -r \
      "${SCRIPT_DIR}/overlay_V1" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
      || { log_error "Overlay-Verzeichnis konnte nicht kopiert werden"; exit 1; }
    log_ok "Overlay-Verzeichnis kopiert"
  else
    log_error "Overlay-Verzeichnis nicht gefunden: ${SCRIPT_DIR}/overlay_V1"
    log_error "  Fehlt nach git pull? Prüfe: ls -la ${SCRIPT_DIR}/overlay_V1"
    exit 1
  fi

  if [[ -f "${SCRIPT_DIR}/.env.local" ]]; then
    scp -o StrictHostKeyChecking=no \
      "${SCRIPT_DIR}/.env.local" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/.env.local" \
      || { log_error "scp .env.local fehlgeschlagen"; exit 1; }
    log_ok ".env.local nach ${VM_REMOTE_INSTALL_DIR} kopiert"
  else
    log_warn ".env.local nicht gefunden — alle Secrets müssen als Umgebungsvariablen gesetzt sein"
  fi

  if [[ -f "${SCRIPT_DIR}/le-certs-backup.yaml" ]]; then
    scp -o StrictHostKeyChecking=no \
      "${SCRIPT_DIR}/le-certs-backup.yaml" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/le-certs-backup.yaml" \
      || { log_error "scp le-certs-backup.yaml fehlgeschlagen"; exit 1; }
    log_ok "LE-Zertifikats-Backup nach ${VM_REMOTE_INSTALL_DIR} kopiert"
  else
    log "Kein LE-Zertifikats-Backup gefunden — Zertifikate werden neu ausgestellt"
  fi

  log "Starte Installation in der VM (SSH-Hop) …"
  ssh -o StrictHostKeyChecking=no \
      "root@${VM_IP_STATIC}" \
      "CIVITAS_CONTEXT=vm CIVITAS_DEBUG=${CIVITAS_DEBUG:-false} bash -lc '
        cd ${VM_REMOTE_INSTALL_DIR}
        if [[ -f .env.local ]]; then
          set -a
          source .env.local
          set +a
        fi
        ./install_civitas_core_V1.sh
      '"
  local ssh_exit=$?
  if [[ "${ssh_exit}" -ne 0 ]]; then
    log_error "SSH-Hop fehlgeschlagen (Exit ${ssh_exit}) — Logs in der VM prüfen"
    log_error "  ssh root@${VM_IP_STATIC}"
    exit "${ssh_exit}"
  fi
  log_ok "Installation in der VM vollständig"
}

# ── Startmeldung ─────────────────────────────────────────────────────────────
log "============================================"
log " CIVITAS/CORE V1 — Installation"
log " Zielplattform: Proxmox-Knoten civitas"
log " Domain:        ${DOMAIN}"
log " k3s:           ${K3S_VERSION}"
log " Phase:         -1 bis 3 (VM, Vorbedingungen, k3s, Add-ons, cc-cli, Verify) — V1"
log "============================================"
log ""

# ── Phasen ausführen ─────────────────────────────────────────────────────────
if [[ "${CIVITAS_CONTEXT}" == "host" ]]; then
  # Auf dem Proxmox-Host: VM provisionieren + Hop in die VM
  provision_vm
  run_in_vm
else
  # In der VM (CIVITAS_CONTEXT=vm): Phasen 0–3 ausführen
  run_preflight
  install_k3s
  install_addons
  install_civitas
  run_verification
  login_summary
fi

log ""
log "============================================"
log " CIVITAS/CORE V1-Installation vollständig."
log "============================================"

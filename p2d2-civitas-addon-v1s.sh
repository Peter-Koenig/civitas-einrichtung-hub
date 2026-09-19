#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-civitas-addon-v1s.sh — p2d2-AddOn für CIVITAS/CORE V1s
#
# Rudimentäres Skript (Schritt 1+2 von 2 abgeschlossen). Installiert die
# FERTIGEN Bausteine (PostgreSQL, GeoServer, MapProxy) plus IAM/Keycloak-
# Provisionierung (addon_25) in der manuell verifizierten Reihenfolge und baut
# sie per --uninstall spiegelbildlich wieder ab (IAM bewusst AUSGENOMMEN, da
# geteilte Infrastruktur); Frontend ist ein klar markierter Platzhalter (Baustein
# noch nicht fertig, siehe addon_30_frontend.sh).
#
# V1s-Kopplung: dieses AddOn setzt auf CIVITAS/CORE V1s auf (nicht V1, nicht V2).
#
# Ausführungskontext (analog install_civitas_core_V1s.sh):
#   ADDON_CONTEXT=host (Default): auf dem Proxmox-Host/der Workstation das Skript
#     selbst, modules_addon_V1s/, overlay_addon_V1s/ und die .env-Datei per scp
#     auf die Ziel-VM kopieren und dann ANHALTEN (kein Auto-Run der Phasen).
#   ADDON_CONTEXT=vm: in der VM die Install-/Uninstall-Phasen ausführen.
#
# TODO (später, NICHT jetzt): Stage-Scope-Parameter `--stage=main|all`. Die Module
# iterieren intern bereits über alle bekannten Stages — dort lässt sich der Scope
# später ohne Grundumbau nachrüsten.
#
# Aufruf:
#   # Host (Selbstkopie + Stopp mit Anleitung):
#   set -a; source ../.env.p2d2-addon; set +a
#   ./p2d2-civitas-addon-v1s.sh
#   # VM (Phasen ausführen):
#   ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh              # Installation
#   ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh --uninstall  # Rückbau

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (rudimentär; später aus inventory/01_config.sh) ─────────────────────
export ADDON_NS="${ADDON_NS:-cc-prd-geodata-stack}"
export ADDON_DB_NS="${ADDON_DB_NS:-cc-prd-database-stack}"
export ADDON_DOMAIN="${ADDON_DOMAIN:-udp.data-dna.eu}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/p2d2-addon-installer.kubeconfig}"

# ── Host→VM-Selbstkopie (analog install_civitas_core_V1s.sh) ──────────────────
export ADDON_CONTEXT="${ADDON_CONTEXT:-host}"
export VM_IP_STATIC="${VM_IP_STATIC:-192.168.12.139}"
export VM_REMOTE_INSTALL_DIR="${VM_REMOTE_INSTALL_DIR:-/root/p2d2-addon}"
# .env liegt laut Konvention im Elternverzeichnis (source ../.env.p2d2-addon).
export ADDON_ENV_FILE="${ADDON_ENV_FILE:-${SCRIPT_DIR}/../.env.p2d2-addon}"

# ── Log-Helfer (minimal, self-contained; analog modules_V1s/02_lib.sh) ────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ── Module laden ───────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules_addon_V1s/addon_00_postgresql.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_10_geoserver.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_20_mapproxy.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_25_iam.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_30_frontend.sh"

# ── Funktion: Selbstkopie auf die Ziel-VM (mit Stopp-Punkt, KEIN Auto-Run) ─────
run_in_vm_addon() {
  # Alten SSH-Host-Key entfernen (VM wird bei Scratch-Läufen ggf. neu erstellt).
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${VM_IP_STATIC}" 2>/dev/null || true

  log "Kopiere AddOn-Skriptdateien in die VM (${VM_IP_STATIC}) …"
  ssh -o StrictHostKeyChecking=no \
      "root@${VM_IP_STATIC}" \
      "mkdir -p ${VM_REMOTE_INSTALL_DIR}" \
      || { log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar"; exit 1; }

  scp -o StrictHostKeyChecking=no -r \
    "${SCRIPT_DIR}/p2d2-civitas-addon-v1s.sh" \
    "${SCRIPT_DIR}/modules_addon_V1s" \
    "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
    || { log_error "scp fehlgeschlagen — VM ${VM_IP_STATIC} nicht erreichbar?"; exit 1; }
  log_ok "Skript + Module kopiert nach ${VM_REMOTE_INSTALL_DIR}"

  if [[ -d "${SCRIPT_DIR}/overlay_addon_V1s" ]]; then
    scp -o StrictHostKeyChecking=no -r \
      "${SCRIPT_DIR}/overlay_addon_V1s" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
      || { log_error "Overlay-Verzeichnis konnte nicht kopiert werden"; exit 1; }
    log_ok "Overlay-Verzeichnis kopiert"
  else
    log_error "Overlay-Verzeichnis nicht gefunden: ${SCRIPT_DIR}/overlay_addon_V1s"
    exit 1
  fi

  # .env-Datei: auf der VM ins ELTERNVERZEICHNIS des Install-Dirs legen, damit die
  # Konvention `source ../.env.p2d2-addon` dort unverändert funktioniert.
  if [[ -f "${ADDON_ENV_FILE}" ]]; then
    scp -o StrictHostKeyChecking=no \
      "${ADDON_ENV_FILE}" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/../.env.p2d2-addon" \
      || { log_error "scp $(basename "${ADDON_ENV_FILE}") fehlgeschlagen"; exit 1; }
    log_ok "$(basename "${ADDON_ENV_FILE}") kopiert nach ${VM_REMOTE_INSTALL_DIR}/../"
  else
    log_warn ".env.p2d2-addon nicht gefunden (${ADDON_ENV_FILE}) — Werte manuell in der VM setzen"
  fi

  # Stopp-Punkt: NICHT automatisch die Phasen ausführen (Frontend ist noch Platzhalter).
  log ""
  log "============================================"
  log_ok "Dateien kopiert nach ${VM_REMOTE_INSTALL_DIR} — bitte manuell fortsetzen:"
  echo ""
  echo "  ssh root@${VM_IP_STATIC}"
  echo "  cd ${VM_REMOTE_INSTALL_DIR}"
  echo "  set -a; source ../.env.p2d2-addon; set +a"
  echo "  ./overlay_addon_V1s/k8s/frontend/build-de1.sh   # nutzt P2D2_GITHUB_TOKEN aus der .env"
  echo ""
  echo "  # später (3 fertige Bausteine) bzw. Rückbau:"
  echo "  ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh"
  echo "  ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh --uninstall"
  log "============================================"
}

# ── Host-Kontext: nur Selbstkopie + Stopp (kein Auto-Run der Phasen) ───────────
if [[ "${ADDON_CONTEXT}" == "host" ]]; then
  log "============================================"
  log " p2d2-AddOn (CIVITAS/CORE V1s) — Host → VM Selbstkopie"
  log " Ziel-VM: ${VM_IP_STATIC}"
  log " Remote:  ${VM_REMOTE_INSTALL_DIR}"
  log "============================================"
  run_in_vm_addon
  exit 0
fi

# ── Startmeldung (VM-Kontext) ──────────────────────────────────────────────────
log "============================================"
log " p2d2-AddOn (CIVITAS/CORE V1s) — Installation"
log " Namespace: ${ADDON_NS}"
log " DB-Namespace: ${ADDON_DB_NS}"
log " Domain:       ${ADDON_DOMAIN}"
log "============================================"

# ── Bausteine in Reihenfolge ────────────────────────────────────────────────────
# Uninstall: Frontend bewusst AUSGENOMMEN (Platzhalter kann es nicht wiederherstellen).
if [[ "${1:-}" == "--uninstall" ]]; then
  log "Modus: Uninstall (umgekehrte Reihenfolge, Frontend ausgenommen)"
  uninstall_addon_mapproxy
  uninstall_addon_geoserver
  uninstall_addon_postgresql
else
  install_addon_postgresql
  install_addon_geoserver
  install_addon_mapproxy
  install_addon_iam
  install_addon_frontend
fi

log ""
log "============================================"
if [[ "${1:-}" == "--uninstall" ]]; then
  log " p2d2-AddOn (V1s) — Uninstall abgeschlossen."
else
  log " p2d2-AddOn (V1s) — Installation abgeschlossen."
fi
log "============================================"

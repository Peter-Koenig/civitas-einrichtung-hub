#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-civitas-addon-v1s.sh — p2d2-AddOn für CIVITAS/CORE V1s
#
# Installiert die Bausteine (PostgreSQL, GeoServer, MapProxy, IAM/Keycloak,
# Frontend) in der verifizierten Reihenfolge und baut sie per --uninstall
# spiegelbildlich (frontend -> iam -> mapproxy -> geoserver -> postgresql) wieder
# ab — rückstandsfrei (Turn 63/65).
#
# Vollautonom (Turn 65): ausgehend von diesem Skriptverzeichnis + .env.p2d2-addon
# (einzige Quelle für mandantenabhängige Werte) läuft ein einziger Aufruf durch —
# inkl. Image-Builds (install_addon_frontend_build) und Host->VM-Selbstkopie.
#
# V1s-Kopplung: dieses AddOn setzt auf CIVITAS/CORE V1s auf (nicht V1, nicht V2).
#
# Ausführungskontext (analog install_civitas_core_V1s.sh):
#   ADDON_CONTEXT=host (Default): auf dem Proxmox-Host/der Workstation das Skript
#     selbst, modules_addon_V1s/, overlay_addon_V1s/, supplement/ und die .env-Datei
#     per scp auf die Ziel-VM kopieren und danach automatisch per SSH die Phasen
#     in der VM anstoßen (vollautonomer Lauf, kein manueller Zwischenschritt).
#   ADDON_CONTEXT=vm: in der VM die Install-/Uninstall-Phasen ausführen.
#
# TODO (später, NICHT jetzt): Stage-Scope-Parameter `--stage=main|all`. Die Module
# iterieren intern bereits über alle bekannten Stages — dort lässt sich der Scope
# später ohne Grundumbau nachrüsten.
#
# Aufruf:
#   # Host (Selbstkopie + vollautonomer Lauf in der VM):
#   ./p2d2-civitas-addon-v1s.sh             # Installation
#   ./p2d2-civitas-addon-v1s.sh --uninstall # Rückbau
#   # VM (Phasen direkt ausführen):
#   ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh              # Installation
#   ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh --uninstall  # Rückbau

set -euo pipefail

# ── Argumente früh abfangen (Turn 70): --help/-h und unbekannte Argumente ──────
# Gültig sind nur: (leer) = Install, --uninstall = Rückbau. Alles andere darf
# keinen Install-Lauf auslösen (bisher fiel z. B. --help in den Install-Zweig).
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'USAGE'
p2d2-AddOn für CIVITAS/CORE V1s — Installation & Rückbau

Aufruf:
  ./p2d2-civitas-addon-v1s.sh              # Installation
  ./p2d2-civitas-addon-v1s.sh --uninstall  # Rückbau
  ./p2d2-civitas-addon-v1s.sh --help       # diese Hilfe

Kontext (Env ADDON_CONTEXT):
  host (Default)  Selbstkopie auf die Ziel-VM + automatischer Lauf dort
  vm              Install-/Uninstall-Phasen direkt in der VM ausführen
USAGE
  exit 0
fi
if [[ -n "${1:-}" && "${1:-}" != "--uninstall" ]]; then
  echo "FEHLER: unbekanntes Argument '${1}'. Gültig: --uninstall, --help/-h." >&2
  echo "Aufruf: $0 [--uninstall|--help]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (rudimentär; später aus inventory/01_config.sh) ─────────────────────
export ADDON_NS="${ADDON_NS:-cc-prd-geodata-stack}"
export ADDON_DB_NS="${ADDON_DB_NS:-cc-prd-database-stack}"
export ADDON_DOMAIN="${ADDON_DOMAIN:-udp.data-dna.eu}"
# KUBECONFIG: Standard-Datei jeder CIVITAS/CORE-VM (volle Cluster-Rechte). Der
# eingeschränkte SA-Kubeconfig der geteilten sdt-Testumgebung
# (~/.kube/p2d2-addon-installer.kubeconfig) wird NICHT mehr als Default erzwungen,
# sondern bleibt über `KUBECONFIG=… ./p2d2-civitas-addon-v1s.sh` ansteuerbar (Turn 70).
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

# ── Host→VM-Selbstkopie (analog install_civitas_core_V1s.sh) ──────────────────
export ADDON_CONTEXT="${ADDON_CONTEXT:-host}"
export VM_IP_STATIC="${VM_IP_STATIC:-192.168.12.139}"
export VM_REMOTE_INSTALL_DIR="${VM_REMOTE_INSTALL_DIR:-/root/p2d2-addon}"
# .env liegt laut Konvention im Elternverzeichnis (wird im VM-Kontext gesourct).
export ADDON_ENV_FILE="${ADDON_ENV_FILE:-${SCRIPT_DIR}/../.env.p2d2-addon}"
# Supplement-Ordner (GeoTIFF-Mosaic, Git-ignored) + APISIX-/Masterportal-Referenzen.
export ADDON_SUPPLEMENT_DIR="${ADDON_SUPPLEMENT_DIR:-${SCRIPT_DIR}/supplement}"
export ADDON_GEOTIFF_DIR="${ADDON_GEOTIFF_DIR:-${ADDON_SUPPLEMENT_DIR}/geotiffs}"
export ADDON_APISIX_CREDENTIALS_FILE="${ADDON_APISIX_CREDENTIALS_FILE:-/root/civitas-install/credentials.env}"
export ADDON_MASTERPORTAL_SERVICE="${ADDON_MASTERPORTAL_SERVICE:-masterportal}"

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

# ── Fail-Fast-Vorprüfungen (Turn 63/65) ────────────────────────────────────────
# _preflight_env — prüft, dass .env.p2d2-addon alle Pflichtvariablen liefert.
# OIDC_CLIENT_ID/-SECRET sind bewusst NICHT Pflicht (werden von IAM erzeugt).
_preflight_env() {
  local missing=() v key
  for v in \
    P2D2_BASE_ALTCHA_HMAC_KEY \
    P2D2_BASE_SMTP_PASS \
    P2D2_BASE_OIDC_ISSUER \
    P2D2_DEMO_PASSWORD \
    P2D2_OSM_IDP_CLIENT_ID \
    P2D2_OSM_IDP_CLIENT_SECRET \
    P2D2_GITHUB_TOKEN \
    P2D2_GITLAB_TOKEN; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  for key in MAIN DEVELOP DE1 DE2 FV; do
    for v in "P2D2_${key}_DB_PASSWORD" "P2D2_${key}_WFST_PASSWORD" "P2D2_${key}_SESSION_SECRET"; do
      [[ -n "${!v:-}" ]] || missing+=("$v")
    done
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error ".env.p2d2-addon unvollständig — fehlende Pflichtvariablen:"
    printf '  - %s\n' "${missing[@]}" >&2
    return 1
  fi
  log_ok ".env.p2d2-addon vollständig (Pflichtvariablen gesetzt)"
  return 0
}

# _preflight_masterportal — Masterportal-Service (statisch, Teil von CIVITAS/CORE)
# muss vorhanden sein. Lose Namenssuche (Muster via ADDON_MASTERPORTAL_SERVICE).
_preflight_masterportal() {
  local svc
  svc="$(kubectl -n "${ADDON_NS}" get services -o name 2>/dev/null | grep -i "${ADDON_MASTERPORTAL_SERVICE}" | head -1 || true)"
  if [[ -z "${svc}" ]]; then
    log_error "Masterportal-Service (Muster '${ADDON_MASTERPORTAL_SERVICE}') in ${ADDON_NS} nicht gefunden — ist CIVITAS/CORE (statisches Masterportal) installiert?"
    return 1
  fi
  log_ok "Masterportal-Service gefunden: ${svc}"
  return 0
}

# preflight_addon — bricht früh ab, bevor irgendein Teil-Deploy passiert.
preflight_addon() {
  log "=== Vorprüfung (Fail-Fast) ==="
  if ! kubectl get namespace "${ADDON_NS}" &>/dev/null; then
    log_error "CIVITAS/CORE-Namespace '${ADDON_NS}' nicht vorhanden — ist CIVITAS/CORE installiert?"
    return 1
  fi
  log_ok "Namespace ${ADDON_NS} vorhanden"

  # Für Uninstall ist .env/Masterportal nicht erforderlich (Creds kommen aus k8s).
  if [[ "${1:-}" != "--uninstall" ]]; then
    _preflight_env || return 1
    _preflight_masterportal || return 1
  fi
  log_ok "Vorprüfung abgeschlossen"
  return 0
}

# ── Funktion: Selbstkopie auf die Ziel-VM (mit automatischem Lauf) ───────────
run_in_vm_addon() {
  local mode="${1:-}"
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

  # Supplement-Verzeichnis (GeoTIFF-Mosaic) — optional, aber mitkopieren, damit die
  # Mosaic-Anlage im VM-Kontext ihre Daten nachweisbar aus dem Supplement-Ordner bezieht.
  if [[ -d "${ADDON_SUPPLEMENT_DIR}" ]]; then
    scp -o StrictHostKeyChecking=no -r \
      "${ADDON_SUPPLEMENT_DIR}" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
      || { log_warn "Supplement-Verzeichnis konnte nicht kopiert werden (nicht fatal)"; }
    log_ok "Supplement-Verzeichnis kopiert"
  else
    log_warn "Supplement-Verzeichnis nicht gefunden (${ADDON_SUPPLEMENT_DIR}) — Mosaic wird im VM-Lauf übersprungen"
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

  # Vollautonomer Lauf (Turn 65): nach Selbstkopie per SSH die Phasen in der VM
  # anstoßen — kein manueller Zwischenschritt mehr.
  local remote_cmd
  if [[ "${mode}" == "--uninstall" ]]; then
    remote_cmd="ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh --uninstall"
  else
    remote_cmd="ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh"
  fi

  log ""
  log "============================================"
  log "Dateien kopiert nach ${VM_REMOTE_INSTALL_DIR} — starte vollautonomen Lauf:"
  log "  ssh root@${VM_IP_STATIC} \"cd ${VM_REMOTE_INSTALL_DIR} && ${remote_cmd}\""
  log "============================================"
  ssh -o StrictHostKeyChecking=no \
      "root@${VM_IP_STATIC}" \
      "cd ${VM_REMOTE_INSTALL_DIR} && ${remote_cmd}" \
    || { log_error "Lauf in der VM fehlgeschlagen — bitte VM-Log prüfen"; exit 1; }
  log_ok "Lauf in der VM abgeschlossen"
}

# ── Host-Kontext: Selbstkopie + vollautonomer Lauf in der VM ──────────────────
if [[ "${ADDON_CONTEXT}" == "host" ]]; then
  log "============================================"
  log " p2d2-AddOn (CIVITAS/CORE V1s) — Host → VM Selbstkopie + Lauf"
  log " Ziel-VM: ${VM_IP_STATIC}"
  log " Remote:  ${VM_REMOTE_INSTALL_DIR}"
  log " Modus:   $([[ "${1:-}" == "--uninstall" ]] && echo Uninstall || echo Install)"
  log "============================================"
  run_in_vm_addon "${1:-}"
  exit 0
fi

# ── VM-Kontext: .env.p2d2-addon laden (einzige Quelle für mandantenabhängige Werte) ─
if [[ -f "${ADDON_ENV_FILE}" ]]; then
  set -a; source "${ADDON_ENV_FILE}"; set +a
  log_ok ".env.p2d2-addon geladen (${ADDON_ENV_FILE})"
else
  log_error ".env.p2d2-addon nicht gefunden (${ADDON_ENV_FILE}) — im Host-Kontext wird sie ins Elternverzeichnis der VM kopiert"
  exit 1
fi

# ── Fail-Fast-Vorprüfungen ─────────────────────────────────────────────────────
preflight_addon "${1:-}" || exit 1

# ── Startmeldung (VM-Kontext) ─────────────────────────────────────────────────
log "============================================"
log " p2d2-AddOn (CIVITAS/CORE V1s) — Installation"
log " Namespace: ${ADDON_NS}"
log " DB-Namespace: ${ADDON_DB_NS}"
log " Domain:       ${ADDON_DOMAIN}"
log "============================================"

# ── Bausteine in Reihenfolge ──────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  log "Modus: Uninstall (frontend -> iam -> mapproxy -> geoserver -> postgresql)"
  uninstall_addon_frontend
  uninstall_addon_iam
  uninstall_addon_mapproxy
  uninstall_addon_geoserver
  uninstall_addon_postgresql
else
  install_addon_postgresql
  install_addon_geoserver
  install_addon_mapproxy
  install_addon_iam
  install_addon_frontend_build
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

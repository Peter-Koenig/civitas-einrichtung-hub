#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 p2d2 Contributors
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
# install_civitas_core_V1s.sh — CIVITAS/CORE V1s Installationsskript
# (V1s = CIVITAS/CORE V1 mit statischer Masterportal-Konfiguration)
#
# Läuft auf dem Proxmox-Host ODER in der Ziel-VM:
#   - Auf dem Proxmox-Host: VM provisionieren (Phase -1), dann automatischer
#     SSH-Hop in die VM (scp + ssh) für Phasen 0–2
#   - In der Ziel-VM: CIVITAS_CONTEXT=vm → Phasen 0–2 ohne VM-Provisionierung
#
# Siehe: skriptarchitektur.md (V1), installationsphasen-und-abnahme.md (V1)
#
# Aufruf (von Proxmox-Host):
#   export SMTP_HOST="..."
#   export SMTP_USER="..."
#   export SMTP_PASS="..."
#   ./install_civitas_core_V1s.sh
#
# ROOT_PASSWORD ist optional (Zugangsregel: VM_SSH_PUBKEY ODER ROOT_PASSWORD,
# siehe init_ssh_access). Secrets liegen in ${HOME}/.env-v1s.local (bei root
# /root/.env-v1s.local); der Host-Zweig verlangt diese Datei (require_env_file).
# Vor dem Aufruf: set -a; source ${HOME}/.env-v1s.local; set +a
#
# Optionen:
#   LOG_FILE=/var/log/civitas_install_v1.log ./install_civitas_core_V1s.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Module laden ─────────────────────────────────────────────────────────────
# ── Optionales File-Logging — VOR source-Aufrufen ───────────────────────────
LOG_FILE="${LOG_FILE:-}"
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

# ── Module laden ─────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules_V1s/01_config.sh"    # Konfiguration
source "${SCRIPT_DIR}/modules_V1s/02_lib.sh"
source "${SCRIPT_DIR}/modules_V1s/00_provision_vm.sh"
source "${SCRIPT_DIR}/modules_V1s/03_preflight.sh"
source "${SCRIPT_DIR}/modules_V1s/04_k3s.sh"
source "${SCRIPT_DIR}/modules_V1s/05_addons.sh"

source "${SCRIPT_DIR}/modules_V1s/06a_network_certs.sh"
source "${SCRIPT_DIR}/modules_V1s/06b_idm_provisioning.sh"
source "${SCRIPT_DIR}/modules_V1s/06c_image_build.sh"    # vor 06_civitas.sh (wird dort aufgerufen)
source "${SCRIPT_DIR}/modules_V1s/06_civitas.sh"
source "${SCRIPT_DIR}/modules_V1s/07_verify.sh"
source "${SCRIPT_DIR}/modules_V1s/07_login_summary.sh"

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

# ── SSH-Zugang zur VM ────────────────────────────────────────────────────────
ensure_vm_ssh_access() {
  local target="root@${VM_IP_STATIC}"
  if ssh "${VM_SSH_OPTS[@]}" -o ConnectTimeout=5 "${target}" true 2>/dev/null; then return 0; fi
  # Altbestand: VM wurde mit dem alten Verfahren angelegt
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
         -o UserKnownHostsFile="${VM_SSH_KNOWN_HOSTS}" "${target}" true 2>/dev/null; then
    log_warn "Installations-Key ist in der VM unbekannt (Altbestand) — trage ihn über den bisherigen Zugang ein"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${VM_SSH_KNOWN_HOSTS}" \
        "${target}" 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys' < "${INSTALL_KEY}.pub" \
      || { log_error "Installations-Key konnte nicht eingetragen werden"; exit 1; }
    ssh "${VM_SSH_OPTS[@]}" -o ConnectTimeout=5 "${target}" true 2>/dev/null && return 0
  fi
  log_error "SSH-Zugang zur VM nicht möglich (weder Installations-Key noch bisheriger Zugang)."
  log_error "Falls sich der Host-Key der VM geändert hat: ssh-keygen -R ${VM_IP_STATIC} -f ${VM_SSH_KNOWN_HOSTS}"
  exit 1
}

remove_install_key() {
  # Entfernt den Key nur aus der laufenden VM. Das Cloud-Init-Laufwerk der VM
  # enthält ihn weiterhin; ob ein späterer Neustart ihn wieder einträgt, ist nicht verifiziert.
  [[ "${VM_REMOVE_INSTALL_KEY:-false}" == "true" ]] || return 0
  if [[ -z "${VM_SSH_PUBKEY:-}" ]]; then
    log_warn "VM_REMOVE_INSTALL_KEY=true, aber VM_SSH_PUBKEY leer: Installations-Key bleibt (sonst kein SSH-Zugang)"
    return 0
  fi
  if ssh "${VM_SSH_OPTS[@]}" "root@${VM_IP_STATIC}" "sed -i '/ civitas-install-${VM_ID}\$/d' ~/.ssh/authorized_keys"; then
    log_ok "Installations-Key aus der VM entfernt"
  else
    log_warn "Installations-Key konnte nicht aus der VM entfernt werden"
  fi
}

# ── Env-Datei (Host-Zweig) ───────────────────────────────────────────────────
# Die Env-Datei liegt bewusst außerhalb von ${SCRIPT_DIR}, damit der --delete-Sync
# des Installations-Repos sie nicht entfernt. Bei root ist ${HOME} = /root.
HOST_ENV_FILE="${HOME}/.env-v1s.local"

find_env_file() {
  [[ -r "${HOST_ENV_FILE}" ]] && printf '%s\n' "${HOST_ENV_FILE}"
}

require_env_file() {
  local env_file mode
  env_file="$(find_env_file)"
  if [[ -z "${env_file}" ]]; then
    log_error "Env-Datei fehlt oder ist nicht lesbar: ${HOST_ENV_FILE}"
    log_error "Die Datei liegt bewusst außerhalb von ${SCRIPT_DIR}, damit der --delete-Sync sie nicht entfernt."
    log_error "Vor dem Aufruf laden: set -a; source ${HOST_ENV_FILE}; set +a"
    exit 1
  fi
  mode="$(stat -c '%a' "${env_file}" 2>/dev/null || true)"
  if [[ -n "${mode}" ]] && (( (8#${mode} & 0022) != 0 )); then
    log_error "Env-Datei ist für group/other schreibbar: ${env_file} (Modus ${mode})"
    log_error "Korrigieren: chmod 600 ${env_file}"
    exit 1
  fi
}

# ── Root-Passwort in der VM (optional, per stdin/chpasswd) ───────────────────
set_root_password() {
  [[ -n "${ROOT_PASSWORD:-}" ]] || return 0
  if printf 'root:%s\n' "${ROOT_PASSWORD}" | ssh "${VM_SSH_OPTS[@]}" "root@${VM_IP_STATIC}" chpasswd; then
    log_ok "Root-Passwort in der VM gesetzt (Konsole)"
  else
    log_error "Root-Passwort konnte nicht gesetzt werden"; exit 1
  fi
}

# ── Funktion: Hop in die VM ──────────────────────────────────────────────────
run_in_vm() {
  ensure_vm_ssh_access
  set_root_password
  log "Kopiere Skript-Dateien in die VM (${VM_IP_STATIC}) …"
  ssh "${VM_SSH_OPTS[@]}" \
      "root@${VM_IP_STATIC}" \
      "mkdir -p ${VM_REMOTE_INSTALL_DIR}" \
      || { log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar"; exit 1; }
  scp "${VM_SSH_OPTS[@]}" -r \
    "${SCRIPT_DIR}/install_civitas_core_V1s.sh" \
    "${SCRIPT_DIR}/modules_V1s" \
    "${SCRIPT_DIR}/templates_V1s" \
    "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
    || { log_error "scp fehlgeschlagen — VM ${VM_IP_STATIC} nicht erreichbar?"; exit 1; }
  log_ok "Skript-Dateien kopiert nach ${VM_REMOTE_INSTALL_DIR}"

  if [[ -d "${SCRIPT_DIR}/overlay_V1s" ]]; then
    scp "${VM_SSH_OPTS[@]}" -r \
      "${SCRIPT_DIR}/overlay_V1s" \
      "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/" \
      || { log_error "Overlay-Verzeichnis konnte nicht kopiert werden"; exit 1; }
    log_ok "Overlay-Verzeichnis kopiert"
  else
    log_error "Overlay-Verzeichnis nicht gefunden: ${SCRIPT_DIR}/overlay_V1s"
    log_error "  Fehlt nach git pull? Prüfe: ls -la ${SCRIPT_DIR}/overlay_V1s"
    exit 1
  fi

  local env_file
  env_file="$(find_env_file)"
  scp "${VM_SSH_OPTS[@]}" \
    "${env_file}" \
    "root@${VM_IP_STATIC}:${VM_REMOTE_INSTALL_DIR}/.env.local" \
    || { log_error "scp $(basename "${env_file}") fehlgeschlagen"; exit 1; }
  log_ok "$(basename "${env_file}") nach ${VM_REMOTE_INSTALL_DIR}/.env.local kopiert"

  ssh "${VM_SSH_OPTS[@]}" "root@${VM_IP_STATIC}" \
    "chmod 700 ${VM_REMOTE_INSTALL_DIR} && chmod 600 ${VM_REMOTE_INSTALL_DIR}/.env.local" \
    || { log_error "chmod auf .env.local fehlgeschlagen"; exit 1; }

  # LE-Zertifikats-Backup in die VM kopieren (Host-Datei hat Vorrang).
  local backup_src=""
  if [[ -f "${CERT_BACKUP_HOST_FILE}" ]]; then
    backup_src="${CERT_BACKUP_HOST_FILE}"
  elif [[ -f "${SCRIPT_DIR}/le-certs-backup.yaml" ]]; then
    log_warn "Host-Datei ${CERT_BACKUP_HOST_FILE} fehlt — nutze veralteten Pfad ${SCRIPT_DIR}/le-certs-backup.yaml"
    backup_src="${SCRIPT_DIR}/le-certs-backup.yaml"
  fi
  if [[ -n "${backup_src}" ]]; then
    scp "${VM_SSH_OPTS[@]}" \
      "${backup_src}" \
      "root@${VM_IP_STATIC}:${CERT_BACKUP_FILE}" \
      || { log_error "scp $(basename "${backup_src}") fehlgeschlagen"; exit 1; }
    log_ok "LE-Zertifikats-Backup nach ${CERT_BACKUP_FILE} in der VM kopiert"
  else
    log "Kein LE-Zertifikats-Backup gefunden — Zertifikate werden neu ausgestellt"
  fi

  log "Starte Installation in der VM (SSH-Hop) …"
  ssh "${VM_SSH_OPTS[@]}" \
      "root@${VM_IP_STATIC}" \
      "CIVITAS_CONTEXT=vm CIVITAS_DEBUG=${CIVITAS_DEBUG:-false} bash -lc '
        cd ${VM_REMOTE_INSTALL_DIR}
        if [[ -f .env.local ]]; then
          set -a
          source .env.local
          set +a
        fi
        ./install_civitas_core_V1s.sh
      '"
  local ssh_exit=$?

  # LE-Zertifikats-Backup VOR der SSH-Exitcode-Auswertung zurückholen, damit
  # ein in der VM bereits geschriebenes Backup auch im Fehlerfall gesichert
  # wird (write_le_backup validiert vor dem mv, die VM-Datei ist vertrauenswürdig).
  # Atomar (tmp im selben Verzeichnis + mv), 0600, nur ersetzen wenn abweichend.
  if ssh "${VM_SSH_OPTS[@]}" "root@${VM_IP_STATIC}" "test -f ${CERT_BACKUP_FILE}"; then
    local tmp_host="${CERT_BACKUP_HOST_FILE}.tmp.$$"
    if scp "${VM_SSH_OPTS[@]}" "root@${VM_IP_STATIC}:${CERT_BACKUP_FILE}" "${tmp_host}"; then
      if [[ -f "${CERT_BACKUP_HOST_FILE}" ]] && cmp -s "${tmp_host}" "${CERT_BACKUP_HOST_FILE}"; then
        rm -f "${tmp_host}"
        log_ok "LE-Zertifikats-Backup unverändert (${CERT_BACKUP_HOST_FILE})"
      else
        mv "${tmp_host}" "${CERT_BACKUP_HOST_FILE}"
        chmod 600 "${CERT_BACKUP_HOST_FILE}"
        log_ok "LE-Zertifikats-Backup nach ${CERT_BACKUP_HOST_FILE} zurückgeholt"
      fi
    else
      rm -f "${tmp_host}"
      log_warn "LE-Zertifikats-Backup konnte nicht zurückgeholt werden"
    fi
  fi

  if [[ "${ssh_exit}" -ne 0 ]]; then
    log_error "SSH-Hop fehlgeschlagen (Exit ${ssh_exit}) — Logs in der VM prüfen"
    log_error "  ssh root@${VM_IP_STATIC}"
    exit "${ssh_exit}"
  fi
  log_ok "Installation in der VM vollständig"
}

# ── Startmeldung ─────────────────────────────────────────────────────────────
log "============================================"
log " CIVITAS/CORE V1s — Installation"
if [[ "${CIVITAS_CONTEXT}" == "host" ]]; then
  log " Zielplattform: Proxmox-Knoten $(hostname)"
else
  log " Ziel-VM:       $(hostname)"
fi
log " Domain:        ${DOMAIN}"
log " Netzwerkmodus: WireGuard ${WG_ENABLED}"
log " Storage:       ${PROXMOX_STORAGE}"
log " Bridge:        ${VM_BRIDGE}"
log " k3s:           ${K3S_VERSION}"
log " Phase:         -1 bis 3 (VM, Vorbedingungen, k3s, Add-ons, cc-cli, Verify) — V1s"
log "============================================"
log ""

warn_changeme_values "Start"

# ── Phasen ausführen ─────────────────────────────────────────────────────────
if [[ "${CIVITAS_CONTEXT}" == "host" ]]; then
  # Auf dem Proxmox-Host: Env-Datei prüfen, VM-Werte validieren, VM provisionieren, Hop in die VM
  require_env_file
  validate_vm_config
  init_ssh_access
  provision_vm
  run_in_vm
  remove_install_key
else
  # In der VM (CIVITAS_CONTEXT=vm): Phasen 0–3 ausführen
  run_preflight
  install_k3s
  install_addons
  install_civitas
  run_verification
  login_summary
fi

warn_changeme_values "Ende"

log ""
log "============================================"
log " CIVITAS/CORE V1s-Installation vollständig."
log "============================================"

#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_05_ssh.sh — p2d2-AddOn: SSH-Zugang vom Host in die VM (V1s)
#
# Wählt den SSH-Schlüssel für den Host→VM-Hop des AddOn-Skripts. Das AddOn
# erzeugt keinen Schlüssel und trägt keinen in die VM ein. Es sucht an der
# Stelle, an der der Installer (install_civitas_core_V1s.sh, 00_provision_vm.sh)
# seinen Installations-Key ablegt:
#
#   1) ${INSTALL_KEY_DIR}/id_ed25519 (zuerst)
#   2) übrige reguläre Dateien in ${INSTALL_KEY_DIR}/ (alphabetisch,
#      ohne *.pub und ohne known_hosts*)
#   3) ADDON_SSH_KEY_FILE, falls gesetzt
#
# Die Defaults spiegeln den Installer (01_config.sh):
#   VM_ID=2010, INSTALL_KEY_DIR=${HOME}/.local/share/civitas-install/${VM_ID}.
# Eine gemeinsame Quelle für diese Werte folgt in Schritt 2.
#
# Alle Kandidaten werden der Reihe nach probiert. Passt keiner, bricht das
# Skript mit exit 1 ab (vor jedem scp).

# addon_ssh_key_file_from_env — liest ADDON_SSH_KEY_FILE aus der AddOn-.env.
# Läuft in einer Subshell, gibt nur diesen einen Wert aus und übernimmt keine
# anderen Variablen in die Host-Umgebung. Fehlt die Datei, ist das kein Fehler.
addon_ssh_key_file_from_env() {
  [[ -f "${ADDON_ENV_FILE}" ]] || return 0
  # shellcheck disable=SC1090
  ( set -a; source "${ADDON_ENV_FILE}" 2>/dev/null; printf '%s\n' "${ADDON_SSH_KEY_FILE:-}" )
}

# addon_ssh_vm_reachable — TCP-Verbindung zu ${VM_IP_STATIC}:22 mit kurzem Timeout.
addon_ssh_vm_reachable() {
  timeout 3 bash -c "exec 3<>/dev/tcp/${VM_IP_STATIC}/22" 2>/dev/null
}

# addon_ssh_select_key — wählt den ersten verwendbaren Schlüssel.
# Setzt ADDON_SSH_KEY (Pfad) und ADDON_SSH_OPTS (Array). Kein Treffer: exit 1.
addon_ssh_select_key() {
  # ADDON_SSH_KEY_FILE: zuerst die Umgebungsvariable, sonst der Wert aus der AddOn-.env.
  if [[ -z "${ADDON_SSH_KEY_FILE:-}" ]]; then
    ADDON_SSH_KEY_FILE="$(addon_ssh_key_file_from_env)"
  fi

  # 1) Kandidaten sammeln (id_ed25519 zuerst, Rest alphabetisch, dann ADDON_SSH_KEY_FILE).
  local cand=() f
  if [[ -d "${INSTALL_KEY_DIR}" ]]; then
    [[ -f "${INSTALL_KEY_DIR}/id_ed25519" ]] && cand+=("${INSTALL_KEY_DIR}/id_ed25519")
    while IFS= read -r f; do
      [[ -n "${f}" ]] && cand+=("${f}")
    done < <(find "${INSTALL_KEY_DIR}" -maxdepth 1 -type f ! -name '*.pub' ! -name 'known_hosts*' ! -name 'id_ed25519' -print 2>/dev/null | sort)
  fi
  [[ -n "${ADDON_SSH_KEY_FILE:-}" ]] && cand+=("${ADDON_SSH_KEY_FILE}")

  # 3) Erreichbarkeit vorab (eigene Meldung, nicht die Schlüsselmeldung).
  if ! addon_ssh_vm_reachable; then
    log_error "VM ${VM_IP_STATIC} auf Port 22 nicht erreichbar — SSH-Zugang kann nicht hergestellt werden"
    exit 1
  fi

  # known_hosts-Verzeichnis bei Bedarf mit Rechten 700 anlegen.
  local kh_dir
  kh_dir="$(dirname "${ADDON_SSH_KNOWN_HOSTS}")"
  if [[ ! -d "${kh_dir}" ]]; then
    ( umask 077; mkdir -p "${kh_dir}" ) 2>/dev/null || true
    chmod 700 "${kh_dir}" 2>/dev/null || true
  fi

  # 2+4) Vorprüfung und Verbindungstest je Kandidat.
  local key tried=() fp perms ssh_err
  for key in "${cand[@]}"; do
    if [[ ! -f "${key}" ]]; then
      log_warn "SSH-Schlüssel ${key} nicht gefunden — übersprungen"
      tried+=("${key}: Datei fehlt")
      continue
    fi
    # Privater Schlüssel ohne Passphrase? ssh-keygen -y mit leerer Passphrase,
    # ohne Interaktion (stdin aus /dev/null).
    if ! ssh-keygen -y -P "" -f "${key}" </dev/null >/dev/null 2>&1; then
      log_warn "SSH-Schlüssel ${key} nicht verwendbar (kein privater Schlüssel ohne Passphrase) — übersprungen"
      tried+=("${key}: kein privater Schlüssel oder Passphrase")
      continue
    fi
    # Gruppen-/welt-lesbar: ssh verweigert solche Schlüssel, daher eigener Hinweis.
    perms="$(stat -c '%a' "${key}" 2>/dev/null || true)"
    if [[ "${perms}" =~ ^[0-7][0-7][0-7]$ && $(( 8#${perms} & 044 )) -ne 0 ]]; then
      log_warn "SSH-Schlüssel ${key} ist gruppen-/welt-lesbar (Rechte ${perms}) — ssh verweigert ihn"
    fi
    if ssh_err="$(ssh -i "${key}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${ADDON_SSH_KNOWN_HOSTS}" \
        "root@${VM_IP_STATIC}" true 2>&1 >/dev/null)"; then
      # Ausgabevariablen für den Aufrufer (run_in_vm_addon im Hauptskript).
      # shellcheck disable=SC2034
      ADDON_SSH_KEY="${key}"
      # shellcheck disable=SC2034
      ADDON_SSH_OPTS=(-i "${key}" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${ADDON_SSH_KNOWN_HOSTS}")
      fp="$(ssh-keygen -l -f "${key}" 2>/dev/null || true)"
      log_ok "SSH-Zugang: ${key} (Fingerprint: ${fp})"
      return 0
    fi
    # Geänderter Host-Key ist ein harter Fehler, kein Grund zum Weiterprobieren.
    if [[ "${ssh_err}" == *"REMOTE HOST IDENTIFICATION"* || "${ssh_err}" == *"HOST IDENTIFICATION"* ]]; then
      log_error "Host-Key der VM ${VM_IP_STATIC} hat sich geändert."
      log_error "  ssh-keygen -R ${VM_IP_STATIC} -f ${ADDON_SSH_KNOWN_HOSTS}"
      exit 1
    fi
    log_warn "SSH-Schlüssel ${key} abgelehnt — nächster Kandidat"
    tried+=("${key}: abgelehnt")
  done

  # 6) Kein Treffer: Abbruch vor jedem scp.
  log_error "Kein verwendbarer SSH-Schlüssel für root@${VM_IP_STATIC} gefunden."
  local t
  for t in "${tried[@]}"; do
    log_error "  - ${t}"
  done
  log_error "Abhilfe: Installer-Schlüssel unter ${INSTALL_KEY_DIR} (prüfe VM_ID und INSTALL_KEY_DIR) oder ADDON_SSH_KEY_FILE auf einen in VM_SSH_PUBKEY eingetragenen Admin-Schlüssel setzen."
  exit 1
}

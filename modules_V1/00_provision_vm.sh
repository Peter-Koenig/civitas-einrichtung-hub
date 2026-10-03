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
# 00_provision_vm.sh — Phase -1: VM auf Proxmox-Host provisionieren (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 00
# Siehe: installationsphasen-und-abnahme.md (V1), Phase -1
#
# Dieses Modul läuft auf dem Proxmox-Host und erstellt die CIVITAS/CORE-VM
# aus einem Debian-13-Cloud-Image. Nach erfolgreicher Provisionierung werden
# die restlichen Phasen (0–3) innerhalb der VM ausgeführt.
#
# Abhängigkeiten:
#   - qm (Proxmox VE)
#   - curl (für Cloud-Image-Download)
#   - ssh (für Verbindungstest nach VM-Start)
#   - ROOT_PASSWORD optional; Zugangsregel (VM_SSH_PUBKEY oder ROOT_PASSWORD) in init_ssh_access
#   - Installations-Key (ensure_install_key) und VM_SSH_PUBKEY (in die VM injiziert)
#
# Idempotenz: Wenn die VM mit der konfigurierten VM_ID bereits existiert,
# wird die Provisionierung übersprungen.
#
# Unterstützte Storage-Typen: zfspool, lvmthin. Verzeichnis-/NFS-Storage ist
# nicht getestet und wird abgelehnt (check_proxmox_prereqs).

check_proxmox_prereqs() {
  local line storage_type storage_status
  line="$(pvesm status 2>/dev/null | awk -v s="${PROXMOX_STORAGE}" '$1==s {print $2, $3}' || true)"
  storage_type="${line%% *}"
  storage_status="${line##* }"

  if [[ -z "${line}" ]]; then
    log_error "Proxmox-Storage '${PROXMOX_STORAGE}' nicht gefunden (pvesm status)."
    log_error "Verfügbare Storages:"
    pvesm status 2>/dev/null | awk 'NR>1 {print "  - " $1 " (" $2 ", " $3 ")"}' || true
    exit 1
  fi
  if [[ "${storage_status}" != "active" ]]; then
    log_error "Storage '${PROXMOX_STORAGE}' ist nicht aktiv (Status: ${storage_status})."
    exit 1
  fi
  case "${storage_type}" in
    zfspool|lvmthin)
      log_ok "Proxmox-Storage '${PROXMOX_STORAGE}' (Typ: ${storage_type}) geeignet" ;;
    *)
      log_error "Storage-Typ '${storage_type}' wird nicht unterstützt (unterstützt: zfspool, lvmthin)."
      exit 1 ;;
  esac

  if ! ip link show "${VM_BRIDGE}" &>/dev/null; then
    log_error "Bridge '${VM_BRIDGE}' existiert nicht auf diesem Host."
    log_error "Vorhandene Bridges: $(ip -br link show type bridge 2>/dev/null | awk '{print $1}' | paste -sd' ')"
    exit 1
  fi
  log_ok "Bridge '${VM_BRIDGE}' vorhanden"

  PROXMOX_STORAGE_TYPE="${storage_type}"
}

# ── VM-Konfiguration validieren (vor jeder VM-Änderung) ──────────────────────
# Prüft Format und Konsistenz der VM-Werte. Läuft im Host-Zweig VOR provision_vm,
# damit Tippfehler nicht erst nach der VM-Anlage auffallen (der Idempotenz-Check
# würde den zweiten Lauf sonst überspringen).
ipv4_to_int() {   # a.b.c.d -> Ganzzahl, Return 1 bei ungültig
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
  local c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

validate_vm_config() {
  local errs=0 ip gw mask v
  [[ "${VM_ID}" =~ ^[0-9]+$ ]] && (( VM_ID >= 100 )) || { log_error "VM_ID ungültig: '${VM_ID}' (Zahl >= 100)"; errs=$((errs+1)); }
  [[ "${VM_NAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || { log_error "VM_NAME ungültig: '${VM_NAME}'"; errs=$((errs+1)); }
  for v in VM_RAM_MB VM_CORES VM_DISK_GB; do
    [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} > 0 )) || { log_error "${v} ungültig: '${!v}' (positive Zahl)"; errs=$((errs+1)); }
  done
  ip="$(ipv4_to_int "${VM_IP_STATIC}")" || { log_error "VM_IP_STATIC ungültig: '${VM_IP_STATIC}'"; errs=$((errs+1)); }
  gw="$(ipv4_to_int "${VM_GW}")" || { log_error "VM_GW ungültig: '${VM_GW}'"; errs=$((errs+1)); }
  if [[ "${VM_IP_PREFIX}" =~ ^[0-9]+$ ]] && (( VM_IP_PREFIX >= 8 && VM_IP_PREFIX <= 30 )); then
    if [[ -n "${ip:-}" && -n "${gw:-}" ]]; then
      mask=$(( (0xFFFFFFFF << (32 - VM_IP_PREFIX)) & 0xFFFFFFFF ))
      (( (ip & mask) == (gw & mask) )) || { log_error "VM_GW ${VM_GW} liegt nicht im Subnetz ${VM_IP_STATIC}/${VM_IP_PREFIX}"; errs=$((errs+1)); }
      (( ip != gw )) || { log_error "VM_GW und VM_IP_STATIC sind identisch"; errs=$((errs+1)); }
    fi
  else
    log_error "VM_IP_PREFIX ungültig: '${VM_IP_PREFIX}' (8..30)"; errs=$((errs+1))
  fi
  if [[ -n "${VM_IP6_STATIC:-}" ]]; then      # IPv6 nur prüfen, wenn gesetzt (Opt-in)
    [[ "${VM_IP6_STATIC}" =~ ^[0-9A-Fa-f:]+$ && "${VM_IP6_STATIC}" == *:*:* ]] || { log_error "VM_IP6_STATIC ungültig: '${VM_IP6_STATIC}'"; errs=$((errs+1)); }
    [[ "${VM_IP6_PREFIX}" =~ ^[0-9]+$ ]] && (( VM_IP6_PREFIX >= 8 && VM_IP6_PREFIX <= 128 )) || { log_error "VM_IP6_PREFIX ungültig: '${VM_IP6_PREFIX}'"; errs=$((errs+1)); }
    [[ -n "${VM_GW6:-}" && "${VM_GW6}" =~ ^[0-9A-Fa-f:]+$ && "${VM_GW6}" == *:*:* ]] || { log_error "VM_GW6 fehlt oder ist ungültig (Pflicht, wenn VM_IP6_STATIC gesetzt ist)"; errs=$((errs+1)); }
  fi
  (( errs == 0 )) || exit 1
}

ensure_install_key() {
  INSTALL_KEY="${INSTALL_KEY_DIR}/id_ed25519"
  if [[ ! -f "${INSTALL_KEY}" ]]; then
    ( umask 077; mkdir -p "${INSTALL_KEY_DIR}" )
    chmod 700 "${INSTALL_KEY_DIR}"
    ssh-keygen -q -t ed25519 -N "" -C "civitas-install-${VM_ID}" -f "${INSTALL_KEY}" \
      || { log_error "Installations-Key konnte nicht erzeugt werden"; exit 1; }
    log_ok "Installations-Key erzeugt: ${INSTALL_KEY}"
  fi
  [[ -f "${INSTALL_KEY}.pub" ]] || ssh-keygen -y -f "${INSTALL_KEY}" > "${INSTALL_KEY}.pub"
}

# Gibt die validierten Zeilen aus VM_SSH_PUBKEY auf stdout aus. Return 1 bei ungültiger Zeile.
validate_vm_pubkeys() {
  local line tmp
  [[ -n "${VM_SSH_PUBKEY:-}" ]] || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    if [[ "${line}" == *PRIVATE\ KEY* || "${line}" == *CHANGEME* ]]; then
      log_error "VM_SSH_PUBKEY: Platzhalter oder privater Schlüssel erkannt (nur Public Keys erlaubt)"; return 1
    fi
    if ! [[ "${line}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
      log_error "VM_SSH_PUBKEY: Zeile ist kein einfacher Public Key (Optionen wie command= sind nicht erlaubt)"; return 1
    fi
    tmp="$(mktemp)"; printf '%s\n' "${line}" > "${tmp}"
    if ! ssh-keygen -l -f "${tmp}" >/dev/null 2>&1; then
      rm -f "${tmp}"; log_error "VM_SSH_PUBKEY: ssh-keygen akzeptiert die Zeile nicht"; return 1
    fi
    rm -f "${tmp}"
    printf '%s\n' "${line}"
  done <<< "${VM_SSH_PUBKEY}"
}

# Schreibt Installations-Pubkey + VM_SSH_PUBKEY in eine temporäre Datei (0600), gibt den Pfad aus.
build_sshkeys_file() {
  local f keys
  keys="$(validate_vm_pubkeys)" || return 1
  f="$(mktemp)"; chmod 600 "${f}"
  cat "${INSTALL_KEY}.pub" > "${f}"
  [[ -z "${keys}" ]] || printf '%s\n' "${keys}" >> "${f}"
  echo "${f}"
}

# Idempotent. Im Host-Zweig des Installers VOR provision_vm aufrufen.
# Validiert VM_SSH_PUBKEY bereits hier (vor jeder VM-Änderung).
init_ssh_access() {
  [[ "${VM_SSH_INIT_DONE:-false}" == "true" ]] && return 0
  validate_vm_pubkeys >/dev/null || exit 1
  if [[ -z "${VM_SSH_PUBKEY:-}" && -z "${ROOT_PASSWORD:-}" ]]; then
    log_error "Kein Zugang für Menschen konfiguriert: mindestens VM_SSH_PUBKEY oder ROOT_PASSWORD setzen."
    exit 1
  fi
  [[ "${ROOT_PASSWORD:-}" != *$'\n'* ]] || { log_error "ROOT_PASSWORD darf keinen Zeilenumbruch enthalten"; exit 1; }
  ensure_install_key
  VM_SSH_KNOWN_HOSTS="${INSTALL_KEY_DIR}/known_hosts"
  VM_SSH_OPTS=(-i "${INSTALL_KEY}" -o IdentitiesOnly=yes -o BatchMode=yes
               -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${VM_SSH_KNOWN_HOSTS}")
  if [[ -z "${VM_SSH_PUBKEY:-}" ]]; then
    log_warn "Kein VM_SSH_PUBKEY gesetzt: direkter SSH-Login nur mit dem Installations-Key auf diesem Host."
  fi
  VM_SSH_INIT_DONE="true"
}

provision_vm() {
  log "=== Phase -1: VM provisionieren ==="

  # Prüfen ob auf Proxmox-Host
  if ! is_installed qm; then
    log_warn "Nicht auf Proxmox-Host — VM-Provisionierung übersprungen"
    log_warn "Stelle sicher, dass die CIVITAS/CORE-VM (ID ${VM_ID}) existiert"
    return 0
  fi

  # Idempotenz: VM bereits vorhanden?
  if qm status "${VM_ID}" &>/dev/null; then
    local vm_status
    vm_status="$(qm status "${VM_ID}" | awk '{print $2}')"
    log_ok "VM ${VM_ID} (${VM_NAME}) existiert bereits — Status: ${vm_status}"
    return 0
  fi

  # Storage-/Bridge-Prüfung VOR Download und qm create (kein halbfertiger Zustand).
  check_proxmox_prereqs

  # ── Schritt 1: Cloud-Image herunterladen (24h-Cache) ─────────────────────
  local image_name image_path cache_dir
  image_name="debian-13-genericcloud-amd64-daily.qcow2"
  cache_dir="${CLOUD_IMAGE_CACHE:-/var/lib/vz/template/qcow}"
  image_path="${cache_dir}/${image_name}"

  mkdir -p "${cache_dir}"

  if [[ -f "${image_path}" ]]; then
    local file_age
    file_age=$(find "${image_path}" -mtime +1 -printf '%f' 2>/dev/null || echo "")
    if [[ -z "${file_age}" ]]; then
      # Datei existiert und ist < 24h alt → Cache gültig
      log_ok "Cloud-Image-Cache gültig (< 24h): ${image_name}"
    else
      log "Cloud-Image-Cache älter als 24h — lade neu herunter …"
      curl -fsSL "${CLOUD_IMAGE_URL}" -o "${image_path}"
      log_ok "Cloud-Image aktualisiert: ${image_name}"
    fi
  else
    log "Lade Cloud-Image herunter (${CLOUD_IMAGE_URL}) ..."
    curl -fsSL "${CLOUD_IMAGE_URL}" -o "${image_path}"
    log_ok "Cloud-Image heruntergeladen: ${image_name}"
  fi

  # ── Schritt 2: VM anlegen ─────────────────────────────────────────────────
  log "Erstelle VM ${VM_ID} (${VM_NAME}) ..."
  qm create "${VM_ID}" \
    --name "${VM_NAME}" \
    --memory "${VM_RAM_MB}" \
    --cores "${VM_CORES}" \
    --cpu host \
    --net0 virtio,bridge="${VM_BRIDGE}" \
    --agent enabled=1 \
    --onboot 1

  # ── Schritt 3: Disk importieren (Ziel: PROXMOX_STORAGE) ───────────────────
  log "Importiere Disk von Cloud-Image nach ${PROXMOX_STORAGE} (${PROXMOX_STORAGE_TYPE}) ..."
  if [[ "${PROXMOX_STORAGE_TYPE}" == "lvmthin" ]]; then
    qm importdisk "${VM_ID}" "${image_path}" "${PROXMOX_STORAGE}" --format raw
  else
    qm importdisk "${VM_ID}" "${image_path}" "${PROXMOX_STORAGE}"
  fi

  # ── Schritt 4: Hardware konfigurieren ─────────────────────────────────────
  # Wichtig: --ide2 zeigt auf PROXMOX_STORAGE (Cloud-Init-ISO), nicht auf template-storage
  log "Konfiguriere Hardware (SCSI, Boot-Reihenfolge, Cloud-Init-ISO) ..."
  qm set "${VM_ID}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${PROXMOX_STORAGE}:vm-${VM_ID}-disk-0" \
    --ide2 "${PROXMOX_STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0

  # ── Schritt 5: Disk auf ${VM_DISK_GB} GiB vergrößern ────────────────────────
  log "Vergrößere Disk auf ${VM_DISK_GB} GiB ..."
  qm resize "${VM_ID}" scsi0 "${VM_DISK_GB}G"
  log_ok "Disk auf ${VM_DISK_GB} GiB vergrößert"

  # ── Schritt 6: Cloud-Init konfigurieren (SSH-Key + statische IP) ──────────
  log "Konfiguriere Cloud-Init (root, SSH-Key, statische IP ${VM_IP_STATIC}) ..."
  init_ssh_access
  local keyfile
  keyfile="$(build_sshkeys_file)" || exit 1
  local ipconfig0="ip=${VM_IP_STATIC}/${VM_IP_PREFIX},gw=${VM_GW}"
  if [[ -n "${VM_IP6_STATIC:-}" ]]; then
    ipconfig0+=",ip6=${VM_IP6_STATIC}/${VM_IP6_PREFIX},gw6=${VM_GW6}"
  fi
  qm set "${VM_ID}" \
    --ciuser root \
    --sshkeys "${keyfile}" \
    --ipconfig0 "${ipconfig0}" || { rm -f "${keyfile}"; exit 1; }
  rm -f "${keyfile}"
  log_ok "Cloud-Init konfiguriert (IP ${VM_IP_STATIC}, SSH-Key injiziert)"

  # ── Schritt 7: (entfällt – Image verbleibt im Cache) ──────────────────────

  # ── Schritt 8: VM starten und auf SSH warten ──────────────────────────────
  # Host-Key einer frischen VM entfernen, damit accept-new den neuen Key akzeptiert.
  ssh-keygen -R "${VM_IP_STATIC}" -f "${VM_SSH_KNOWN_HOSTS}" >/dev/null 2>&1 || true
  log "Starte VM ${VM_ID} ..."
  qm start "${VM_ID}"
  log "Warte auf SSH unter ${VM_IP_STATIC} (max. 120s) ..."

  local attempt=0
  until ssh "${VM_SSH_OPTS[@]}" -o ConnectTimeout=5 root@"${VM_IP_STATIC}" true 2>/dev/null; do
    sleep 5
    (( attempt++ )) || true
    if [[ $attempt -gt 24 ]]; then
      log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar nach 120s"
      exit 1
    fi
  done
  log_ok "VM erreichbar unter ${VM_IP_STATIC}"

  # ── Schritt 8b: Cloud-Init-Hostname stabilisieren ────────────────────────
  # Debian-Cloud-Images führen cloud-init bei jedem Boot aus. Ohne
  # preserve_hostname würde ein Hostname-Drift (z. B. bei Re-Provisionierung)
  # k3s-Geister-Nodes und PV-nodeAffinity-Konflikte erzeugen (Root Cause des
  # Vorfalls 2026-08-31/2026-09-05). Die k3s-Node selbst wird separat über
  # --node-name (01_config.sh) gepinnt.
  log "Stabilisiere Cloud-Init-Hostname (preserve_hostname) ..."
  ssh "${VM_SSH_OPTS[@]}" root@"${VM_IP_STATIC}" \
    'if grep -q "^preserve_hostname:" /etc/cloud/cloud.cfg 2>/dev/null; then
       sed -i "s/^preserve_hostname:.*/preserve_hostname: true/" /etc/cloud/cloud.cfg
     else
       echo "preserve_hostname: true" >> /etc/cloud/cloud.cfg
     fi'
  log_ok "Cloud-Init-Hostname stabilisiert (preserve_hostname: true)"

  # ── Abschlussmeldung ──────────────────────────────────────────────────────
  log ""
  log "  ┌────────────────────────────────────────────────────────────────────┐"
  log "  │ VM ${VM_ID} (${VM_NAME}) betriebsbereit unter ${VM_IP_STATIC}"
  log "  │                                                                    │"
  log "  │ Das Skript startet nun automatisch in der VM und führt Phase 0–2  │"
  log "  │ dort aus.                                                          │"
  log "  │                                                                    │"
  log "  │ Bei Bedarf (Debugging):                                            │"
  log "  │   ssh root@${VM_IP_STATIC}                                         │"
  log "  │   cd /root/civitas-install                                         │"
  log "  │   CIVITAS_CONTEXT=vm ./install_civitas_core_V1.sh                  │"
  log "  └────────────────────────────────────────────────────────────────────┘"
  log ""
  log_ok "VM-Provisionierung abgeschlossen"
}

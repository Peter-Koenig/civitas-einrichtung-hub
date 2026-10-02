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
#   - ROOT_PASSWORD als Umgebungsvariable (geprüft in 01_config.sh)
#   - SSH-Public-Key unter SSH_PUBKEY_PATH (wird in die VM injiziert)
#
# Idempotenz: Wenn die VM mit der konfigurierten VM_ID bereits existiert,
# wird die Provisionierung übersprungen.
#
# Unterstützte Storage-Typen: zfspool, lvmthin. Verzeichnis-/NFS-Storage ist
# nicht getestet und wird abgelehnt (check_proxmox_prereqs).

check_proxmox_prereqs() {
  local line storage_type storage_status
  line="$(pvesm status 2>/dev/null | awk -v s="${PROXMOX_STORAGE}" '$1==s {print $2, $3}')"
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
  local ipconfig0="ip=${VM_IP_STATIC}/${VM_IP_PREFIX},gw=${VM_GW}"
  if [[ -n "${VM_IP6_STATIC:-}" ]]; then
    ipconfig0+=",ip6=${VM_IP6_STATIC}/${VM_IP6_PREFIX},gw6=${VM_GW6}"
  fi
  qm set "${VM_ID}" \
    --ciuser root \
    --sshkeys "${SSH_PUBKEY_PATH}" \
    --ipconfig0 "${ipconfig0}"
  log_ok "Cloud-Init konfiguriert (IP ${VM_IP_STATIC}, SSH-Key injiziert)"

  # ── Schritt 7: (entfällt – Image verbleibt im Cache) ──────────────────────

  # ── Schritt 8: VM starten und auf SSH warten ──────────────────────────────
  log "Starte VM ${VM_ID} ..."
  qm start "${VM_ID}"
  log "Warte auf SSH unter ${VM_IP_STATIC} (max. 120s) ..."

  local attempt=0
  until ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            root@"${VM_IP_STATIC}" true 2>/dev/null; do
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
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes root@"${VM_IP_STATIC}" \
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

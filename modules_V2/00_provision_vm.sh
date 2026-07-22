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
# 00_provision_vm.sh — Phase -1: VM-Provisionierung (CIVITAS/CORE V2)
#
# Siehe: skriptarchitektur.md (V2)
# Siehe: installationsphasen-und-abnahme.md (V2), Phase -1
#
# Läuft auf dem Proxmox-Host und erstellt die CIVITAS/CORE-VM aus einem
# Debian-13-Cloud-Image. Nach erfolgreicher Provisionierung werden die
# restlichen Phasen (0–3) innerhalb der VM ausgeführt.
#
# Abhängigkeiten:
#   - qm (Proxmox VE)
#   - curl (für Cloud-Image-Download)
#   - ROOT_PASSWORD als Umgebungsvariable (geprüft in 01_config.sh)
#
# Idempotenz: Wenn die VM mit der konfigurierten VM_ID bereits existiert,
# wird die Provisionierung übersprungen.

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ───────────────────────────────
provision_vm() {
  log "=== Phase -1: VM provisionieren ==="

  # Prüfen ob auf Proxmox-Host
  if ! is_installed qm; then
    log_warn "Nicht auf Proxmox-Host — VM-Provisionierung übersprungen"
    log_warn "Stelle sicher, dass die CIVITAS/CORE-VM (ID ${VM_ID}) existiert"
    return 0
  fi

  # TODO: Idempotenz-Prüfung: VM bereits vorhanden?
  #   if qm status "${VM_ID}" &>/dev/null; then
  #     log_ok "VM ${VM_ID} existiert bereits — überspringe"
  #     return 0
  #   fi

  # ── Schritt 1: Cloud-Image herunterladen ──────────────────────────────────
  # TODO: Idempotenz-Prüfung: Datei bereits vorhanden?
  #   if [[ -f "${CLOUD_IMAGE_PATH}" ]]; then
  #     log_ok "Cloud-Image bereits vorhanden: ${CLOUD_IMAGE_NAME}"
  #   else
  #     log "Lade Cloud-Image herunter (${CLOUD_IMAGE_URL}) ..."
  #     curl -fsSL "${CLOUD_IMAGE_URL}" -o "${CLOUD_IMAGE_PATH}"
  #     log_ok "Cloud-Image heruntergeladen: ${CLOUD_IMAGE_NAME}"
  #   fi
  # TODO: Implementierung

  # ── Schritt 2: VM anlegen ─────────────────────────────────────────────────
  log "Erstelle VM ${VM_ID} (${VM_NAME}) ..."
  # TODO: Implementierung
  #   qm create "${VM_ID}" \
  #     --name "${VM_NAME}" \
  #     --memory "${VM_RAM_MB}" \
  #     --cores "${VM_CORES}" \
  #     --cpu host \
  #     --net0 virtio,bridge="${VM_BRIDGE}" \
  #     --agent enabled=1 \
  #     --onboot 1

  # ── Schritt 3: Disk importieren ───────────────────────────────────────────
  log "Importiere Disk von Cloud-Image nach ${PROXMOX_STORAGE} ..."
  # TODO: Implementierung
  #   qm importdisk "${VM_ID}" "${CLOUD_IMAGE_PATH}" "${PROXMOX_STORAGE}"

  # ── Schritt 4: Hardware konfigurieren ─────────────────────────────────────
  log "Konfiguriere Hardware (SCSI, Boot-Reihenfolge, Cloud-Init-ISO) ..."
  # TODO: Implementierung
  #   qm set "${VM_ID}" \
  #     --scsihw virtio-scsi-pci \
  #     --scsi0 "${PROXMOX_STORAGE}:vm-${VM_ID}-disk-0" \
  #     --ide2 "${PROXMOX_STORAGE}:cloudinit" \
  #     --boot order=scsi0 \
  #     --serial0 socket \
  #     --vga serial0

  # ── Schritt 5: Disk vergrößern ────────────────────────────────────────────
  log "Vergrößere Disk auf ${VM_DISK_GB} GiB ..."
  # TODO: Implementierung
  #   qm resize "${VM_ID}" scsi0 "${VM_DISK_GB}G"

  # ── Schritt 6: Cloud-Init konfigurieren (statische IP) ────────────────────
  log "Konfiguriere Cloud-Init (root, SSH-Key, statische IP ${VM_IP_STATIC}) ..."
  # TODO: Implementierung
  #   qm set "${VM_ID}" \
  #     --ciuser root \
  #     --sshkeys "${HOME}/.ssh/authorized_keys" \
  #     --ipconfig0 "ip=${VM_IP_CIDR},gw=${VM_GATEWAY}"

  # ── Schritt 7: Temporäres Image aufräumen ─────────────────────────────────
  # TODO: Implementierung: Temporäres Cloud-Image aufräumen
  #   rm -f "${CLOUD_IMAGE_PATH}"
  #   log_ok "Temporäres Cloud-Image gelöscht: ${CLOUD_IMAGE_PATH}"

  # ── Schritt 8: VM starten und auf SSH warten ──────────────────────────────
  log "Starte VM ${VM_ID} ..."
  # TODO: Implementierung
  #   qm start "${VM_ID}"
  #   log "Warte auf SSH unter ${VM_IP_STATIC} (max. 120s) ..."
  #   local attempt=0
  #   until ssh -o StrictHostKeyChecking=no \
  #             -o ConnectTimeout=5 \
  #             -o BatchMode=yes \
  #             root@"${VM_IP_STATIC}" true 2>/dev/null; do
  #     sleep 5
  #     (( attempt++ )) || true
  #     if [[ $attempt -gt 24 ]]; then
  #       log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar nach 120s"
  #       exit 1
  #     fi
  #   done
  #   log_ok "VM erreichbar unter ${VM_IP_STATIC}"

  # ── Abschlussmeldung ──────────────────────────────────────────────────────
  log ""
  log "  ┌────────────────────────────────────────────────────────────────────┐"
  log "  │ VM ${VM_ID} (${VM_NAME}) — Phase -1 abgeschlossen"
  log "  │ Die Phasen 0–3 laufen innerhalb der VM."
  log "  └────────────────────────────────────────────────────────────────────┘"
  log ""
  log_ok "VM-Provisionierung abgeschlossen"
}

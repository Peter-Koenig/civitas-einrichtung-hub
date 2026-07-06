#!/usr/bin/env bash
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
  log "Importiere Disk von Cloud-Image nach ${PROXMOX_STORAGE} ..."
  qm importdisk "${VM_ID}" "${image_path}" "${PROXMOX_STORAGE}"

  # ── Schritt 4: Hardware konfigurieren ─────────────────────────────────────
  # Wichtig: --ide2 zeigt auf PROXMOX_STORAGE (ZFS), nicht auf template-storage
  log "Konfiguriere Hardware (SCSI, Boot-Reihenfolge, Cloud-Init-ISO) ..."
  qm set "${VM_ID}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${PROXMOX_STORAGE}:vm-${VM_ID}-disk-0" \
    --ide2 "${PROXMOX_STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0

  # ── Schritt 5: Disk auf 300 GiB vergrößern ────────────────────────────────
  log "Vergrößere Disk auf ${VM_DISK_GB} GiB ..."
  qm resize "${VM_ID}" scsi0 "${VM_DISK_GB}G"
  log_ok "Disk auf ${VM_DISK_GB} GiB vergrößert"

  # ── Schritt 6: Cloud-Init konfigurieren (SSH-Key + statische IP) ──────────
  log "Konfiguriere Cloud-Init (root, SSH-Key, statische IP ${VM_IP_STATIC}) ..."
  qm set "${VM_ID}" \
    --ciuser root \
    --sshkeys "${SSH_PUBKEY_PATH}" \
    --ipconfig0 "ip=${VM_IP_STATIC}/${VM_IP_PREFIX},gw=${VM_GW},ip6=${VM_IP6_STATIC}/${VM_IP6_PREFIX},gw6=${VM_GW6}"
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

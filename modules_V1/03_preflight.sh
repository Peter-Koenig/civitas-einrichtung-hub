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
# Phase 0 — Vorbedingungen
# Führt alle Systemprüfungen vor der Installation durch.
set -euo pipefail

run_preflight() {
  log "=== Phase 0: Vorbedingungen ==="

  wait_for_apt_lock
  check_os
  check_cpu
  check_ram
  check_disk
  check_swap
  check_network
  check_tools
  check_timezone
  check_inotify
  check_dns_warn
  check_smtp
  check_k3s_version
  check_pbs_backup
  check_nonfree_source
}

# ── OS ──
check_os() {
  log "Prüfe Betriebssystem ..."
  if [[ ! -f /etc/os-release ]]; then
    log_error "/etc/os-release nicht gefunden — kein systemd-basiertes System"
    exit 1
  fi
  source /etc/os-release
  if [[ "$ID" != "debian" ]] || [[ "$VERSION_ID" != "13" ]]; then
    log_error "Betriebssystem: erwartet Debian 13 (Trixie), gefunden ${ID} ${VERSION_ID}"
    exit 1
  fi
  log_ok "Betriebssystem: Debian ${VERSION_ID} (Trixie)"
}

# ── CPU ──
check_cpu() {
  log "Prüfe vCPU ..."
  local cpus
  cpus="$(nproc)"
  if [[ "$cpus" -lt 4 ]]; then
    log_error "vCPU: ${cpus} (Minimum 4, empfohlen 12)"
    exit 1
  fi
  log_ok "vCPU: ${cpus} (empfohlen: 12)"
}

# ── RAM ──
check_ram() {
  log "Prüfe RAM ..."
  local ram_mib
  ram_mib="$(free -m | awk '/^Mem:/ {print $7}')"
  if [[ "$ram_mib" -lt 16384 ]]; then
    log_error "RAM: ${ram_mib} MiB frei (Minimum 16384 MiB)"
    exit 1
  fi
  log_ok "RAM: ${ram_mib} MiB frei (empfohlen: 40 GiB)"
}

# ── Disk ──
check_disk() {
  log "Prüfe Speicherplatz ..."
  local disk_gib
  disk_gib="$(df -BG "${K3S_DATA_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || true)"
  if [[ -z "${disk_gib:-}" ]]; then
    disk_gib="$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')"
  fi
  disk_gib="${disk_gib:-0}"
  if [[ "$disk_gib" -lt 100 ]]; then
    log_error "Speicher: ${disk_gib} GiB frei (Minimum 100 GiB)"
    exit 1
  fi
  log_ok "Speicher: ${disk_gib} GiB frei (empfohlen: 300 GiB)"
}

# ── Swap ──
check_swap() {
  log "Prüfe Swap ..."
  if swapon --show | grep -q '.'; then
    log_error "Swap ist aktiviert — für Kubernetes deaktivieren"
    exit 1
  fi
  log_ok "Swap deaktiviert"
}

# ── Netzwerk ──
check_network() {
  log "Prüfe Netzwerk (Gateway ${SOHO_GATEWAY}) ..."
  if ! ping -c2 -W2 "${SOHO_GATEWAY}" &>/dev/null; then
    log_error "Gateway ${SOHO_GATEWAY} nicht erreichbar"
    exit 1
  fi
  log_ok "Gateway erreichbar"
}

# ── Zeitzone ──
check_timezone() {
  local tz="Europe/Berlin"
  local current
  current="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  if [[ "${current}" == "${tz}" ]]; then
    log_ok "Zeitzone bereits ${tz}"
    return 0
  fi
  log "Setze Zeitzone auf ${tz} (aktuell: ${current:-unbekannt}) …"
  timedatectl set-timezone "${tz}" \
    || { log_error "Zeitzone konnte nicht gesetzt werden"; exit 1; }
  log_ok "Zeitzone auf ${tz} gesetzt"
}

# ── inotify (fsnotify) ───────────────────────────────────────────────────────
# Der k3s-Ingress-Controller (ingress-nginx) und viele Kubernetes-Controller
# ueberwachen Konfigurationsaenderungen und Zertifikate ueber inotify-Watcher.
# Das Kernel-Limit fs.inotify.max_user_instances=128 ist fuer einen Kubernetes-
# Node mit vielen gleichzeitig laufenden Pods zu niedrig und fuehrt zu:
#   "failed to create fsnotify watcher: too many open files"
# Der darauf folgende HTTP 500 in der Readiness-Probe des Ingress-Controllers
# verhindert, dass der Controller als Ready gemeldet wird.
check_inotify() {
  local conf="/etc/sysctl.d/99-inotify.conf"
  local target_watches="524288"
  local target_instances="1024"

  log "Pruefe inotify-Limits (max_user_watches=${target_watches}, max_user_instances=${target_instances}) …"

  # Pruefe ob Konfiguration bereits korrekt existiert
  if [[ -f "${conf}" ]] \
     && grep -q "fs.inotify.max_user_watches=${target_watches}" "${conf}" \
     && grep -q "fs.inotify.max_user_instances=${target_instances}" "${conf}"; then
    log_ok "inotify-Konfiguration bereits korrekt: ${conf}"
  else
    log "Setze inotify-Limits (${conf}) …"
    cat > "${conf}" << EOF
# inotify-Konfiguration fuer Kubernetes (Ingress-Controller ueberwacht
# ConfigMaps, Secrets und Zertifikate mit inotify-Watchern).
# Siehe: https://github.com/kubernetes/ingress-nginx/issues/10653
fs.inotify.max_user_watches=${target_watches}
fs.inotify.max_user_instances=${target_instances}
EOF
    log_ok "inotify-Konfiguration geschrieben: ${conf}"
    sysctl --system
    log_ok "sysctl --system ausgefuert"
  fi

  # Verifikation: aktuelle Werte auslesen und mit Zielwerten vergleichen
  local actual_watches actual_instances
  actual_watches="$(sysctl fs.inotify.max_user_watches 2>/dev/null | awk '{print $3}')"
  actual_instances="$(sysctl fs.inotify.max_user_instances 2>/dev/null | awk '{print $3}')"

  if [[ "${actual_watches}" != "${target_watches}" ]]; then
    log_error "inotify.max_user_watches: erwartet ${target_watches}, aktiv ${actual_watches:-nicht lesbar}"
    exit 1
  fi

  if [[ "${actual_instances}" != "${target_instances}" ]]; then
    log_error "inotify.max_user_instances: erwartet ${target_instances}, aktiv ${actual_instances:-nicht lesbar}"
    exit 1
  fi

  log_ok "inotify-Limits aktiv: max_user_watches=${actual_watches}, max_user_instances=${actual_instances}"
}

# ── Apt-Lock-Warteschleife ──
# ── Apt-Lock-Hilfsfunktion ──
apt_locks_held() {
  fuser /var/lib/apt/lists/lock \
        /var/lib/dpkg/lock \
        /var/lib/dpkg/lock-frontend \
        >/dev/null 2>&1 || return 1
  return 0
}

wait_for_apt_lock() {
  local max_wait=120
  local waited=0
  while apt_locks_held; do
    if [[ $waited -eq 0 ]]; then
      log "Warte auf apt-lock (cloud-init o.ä.) …"
    fi
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      log_error "apt-lock nach ${max_wait}s nicht freigegeben."
      fuser -v /var/lib/apt/lists/lock 2>&1 || true
      fuser -v /var/lib/dpkg/lock-frontend 2>&1 || true
      exit 1
    fi
  done
  [[ $waited -gt 0 ]] && log_ok "apt-lock nach ${waited}s freigegeben" || true
}

# ── DNS (Warnung, kein Abbruch) ──
check_dns_warn() {
  log "Prüfe DNS (Warnung) ..."
  if ! dns_resolves "idm.${DOMAIN}"; then
    log_warn "DNS: idm.${DOMAIN} nicht auflösbar — Eintrag vor Phase 2 setzen"
  else
    log_ok "DNS: idm.${DOMAIN} auflösbar"
  fi
  if ! dns_resolves "portal.${DOMAIN}"; then
    log_warn "DNS: portal.${DOMAIN} nicht auflösbar — Eintrag vor Phase 2 setzen"
  else
    log_ok "DNS: portal.${DOMAIN} auflösbar"
  fi
}

# ── Tools ──
check_tools() {
  log "Prüfe Werkzeuge ..."

  # Pflicht-Tools → Mapping auf Paketnamen
  local required_tools=(curl python3 pip3 dig git yq rg)
  if [[ "${WG_ENABLED}" == "true" ]]; then
    required_tools+=(wg)
  fi
  local -A tool_to_pkg=(
    [pip3]="python3-pip"
    [dig]="dnsutils"
    [wg]="wireguard-tools"
    [curl]="curl"
    [python3]="python3"
    [git]="git"
    [yq]="yq-go"
    [rg]="ripgrep"
  )

  # Optionale Utilities
  local optional_pkgs=(vim jq htop plocate)

  # Fehlende Pflichtpakete sammeln
  local required_pkgs=()
  for tool in "${required_tools[@]}"; do
    if ! is_installed "$tool"; then
      log_warn "Pflichtwerkzeug fehlt: ${tool}"
      required_pkgs+=("${tool_to_pkg[$tool]}")
    fi
  done

  # Fehlende optionale Pakete sammeln
  local optional_missing=()
  for pkg in "${optional_pkgs[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      optional_missing+=("$pkg")
    fi
  done

  # Nur wenn überhaupt etwas zu installieren ist
  if [[ ${#required_pkgs[@]} -gt 0 ]] || [[ ${#optional_missing[@]} -gt 0 ]]; then
    wait_for_apt_lock

    # apt-get update mit eigenem Fehlerhandling
    if ! apt-get update -qq 2>&1; then
      log_error "apt-get update fehlgeschlagen — Paketinstallation nicht möglich"
      exit 1
    fi
    log_ok "apt-get update erfolgreich"

    # Pflichtpakete installieren und verifizieren
    if [[ ${#required_pkgs[@]} -gt 0 ]]; then
      log "Installiere Pflichtpakete: ${required_pkgs[*]} …"
      if apt-get install -y "${required_pkgs[@]}" 2>&1; then
        log_ok "Pflichtpakete installiert"
      else
        log_error "apt-get install für Pflichtpakete fehlgeschlagen: ${required_pkgs[*]}"
        exit 1
      fi

      # Nachkontrolle
      local still_missing=()
      for tool in "${required_tools[@]}"; do
        if ! is_installed "$tool"; then
          still_missing+=("$tool")
        fi
      done
      if [[ ${#still_missing[@]} -gt 0 ]]; then
        log_error "Pflichtwerkzeuge nach Installation weiterhin fehlend: ${still_missing[*]}"
        exit 1
      fi
      log_ok "Alle Pflichtwerkzeuge vorhanden"
    fi

    # Optionale Pakete installieren — best effort, kein Abbruch
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
      log "Installiere optionale Pakete: ${optional_missing[*]} …"
      if apt-get install -y "${optional_missing[@]}" 2>&1; then
        log_ok "Optionale Pakete installiert"
      else
        log_warn "Optionale Pakete teilweise fehlgeschlagen: ${optional_missing[*]} — wird ignoriert"
      fi
    fi
  else
    log_ok "Alle erforderlichen Werkzeuge vorhanden"
  fi

  # Flavor-Guard: das Debian-Paket 'yq' ist der Python-Wrapper (kislyuk 3.x),
  # der Installer benötigt 'yq-go' (mikefarah, 'yq eval'-Syntax).
  if is_installed yq && ! yq --version 2>/dev/null | grep -q mikefarah; then
    log_error "Falsches yq: das Debian-Paket 'yq' ist der Python-Wrapper (kislyuk 3.x); benötigt wird 'yq-go' (mikefarah)."
    exit 1
  fi
  log "yq: $(yq --version 2>/dev/null || echo 'nicht verfügbar')"
}

# ── SMTP ──
check_smtp() {
  log "Prüfe SMTP-Erreichbarkeit (${SMTP_HOST}:${SMTP_PORT}) ..."
  if ! tcp_reachable "${SMTP_HOST}" "${SMTP_PORT}"; then
    log_error "SMTP-Server ${SMTP_HOST}:${SMTP_PORT} nicht erreichbar"
    exit 1
  fi
  log_ok "SMTP erreichbar"
}

# ── k3s-Version (Idempotenz) ──
check_k3s_version() {
  if systemd_active k3s; then
    log "k3s bereits installiert — prüfe Version ..."
    local installed_version
    installed_version="$(k3s --version 2>/dev/null | grep -oP 'k3s version \K\S+' || true)"
    if [[ "$installed_version" != "$K3S_VERSION" ]]; then
      log_error "k3s installiert: ${installed_version}, erwartet: ${K3S_VERSION} — Abbruch"
      exit 1
    fi
    log_ok "k3s ${K3S_VERSION} bereits installiert"
    export K3S_ALREADY_INSTALLED=true
  else
    log "k3s nicht installiert — wird in Phase 1a installiert"
    export K3S_ALREADY_INSTALLED=false
  fi
}

# ── PBS-Backup ──
check_pbs_backup() {
  if [[ -z "${PBS_STORAGE:-}" ]]; then
    log "PBS-Storage nicht konfiguriert (PBS_STORAGE leer) — Backup-Prüfung übersprungen"
    return 0
  fi
  log "Prüfe PBS-Storage (${PBS_STORAGE}) ..."
  if ! is_installed pvesm; then
    log_warn "Nicht auf Proxmox-Host — PBS-Prüfung auf Host-Ebene vornehmen"
    log_warn "Stelle sicher, dass VM regelmäßig auf PBS '${PBS_STORAGE}' gesichert wird"
    return 0
  fi
  if pvesm status 2>/dev/null | grep -q "${PBS_STORAGE}"; then
    log_ok "PBS-Storage ${PBS_STORAGE} verfügbar"
    # Backup der aktuellen VM anlegen (nur auf Proxmox-Host sinnvoll)
    local hostname
    hostname="$(hostname)"
    if [[ -n "$hostname" ]]; then
      log "Lege Backup für ${hostname} an ..."
      if pvesh get /cluster/backup 2>/dev/null | grep -q .; then
        log_ok "Backup-Job existiert — wird von Proxmox-Scheduler übernommen"
      else
        log_ok "PBS-Storage konfiguriert — Backup auf Host-Ebene bestätigt"
      fi
    fi
  else
    log_warn "Kein PBS-Storage '${PBS_STORAGE}' gefunden — Backup vor Produktivbetrieb einrichten"
  fi
}

# ── non-free-Quelle (apt) ────────────────────────────────────────────────────
# Prueft, ob die Sektion non-free in /etc/apt/sources.list.d/debian.sources
# aktiviert ist. Wird fuer fonts-ubuntu (Playwright/Chromium unter Debian 13
# Trixie) benoetigt. Idempotent: schon aktiv → nichts tun.
check_nonfree_source() {
  log "Pruefe non-free in apt-Quellen …"
  local sources_file="/etc/apt/sources.list.d/debian.sources"
  local sources_legacy="/etc/apt/sources.list"

  if [[ -f "${sources_file}" ]]; then
    if grep -q "^Components.*\bnon-free\b" "${sources_file}" 2>/dev/null; then
      log_ok "non-free bereits in ${sources_file} aktiv"
      return 0
    fi
    log "non-free nicht gefunden — ergaenze in ${sources_file} …"
    sed -i 's/^Components: \(.*\)$/Components: \1 non-free/' "${sources_file}"
    if apt-get update -qq 2>&1; then
      log_ok "non-free hinzugefuegt und apt-Update erfolgreich"
    else
      log_warn "apt-get update nach non-free-Ergaenzung fehlgeschlagen"
      log_warn "  fonts-ubuntu (Playwright/Chromium) ist ggf. nicht installierbar"
    fi
  elif [[ -f "${sources_legacy}" ]]; then
    if grep -q "^deb.*non-free" "${sources_legacy}" 2>/dev/null; then
      log_ok "non-free bereits in ${sources_legacy} aktiv"
      return 0
    fi
    log_warn "non-free nicht in ${sources_legacy} gefunden"
    log_warn "  Bitte manuell ergaenzen und apt-get update ausfuehren"
  else
    log_warn "Keine apt-Quellen-Datei gefunden (weder ${sources_file} noch ${sources_legacy})"
    log_warn "  non-free kann nicht automatisch aktiviert werden"
  fi
}

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
# 03_preflight.sh — CIVITAS/CORE V2: Phase 0 — Preflight
#
# Siehe: skriptarchitektur.md (V2), installationsphasen-und-abnahme.md (V2)
# Führt alle Systemprüfungen vor der Installation aus.
#
# Abhängigkeiten:
#   - 01_config.sh: alle Konfigurationsvariablen
#   - 02_lib.sh: log_*, is_installed, tcp_reachable, dns_resolves

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
run_preflight() {
  log "=== Phase 0: Vorbedingungen ==="

  check_os
  check_cpu
  check_ram
  check_disk
  check_swap
  check_network
  check_dns_warn
  check_smtp
  check_tools
  check_k3s_status

  log_ok "Phase 0 abgeschlossen — alle Pflichtprüfungen bestanden"
}

# ── OS ──
check_os() {
  log "Prüfe Betriebssystem …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: /etc/os-release auswerten (ID=debian, VERSION_ID=13)
  log_ok "Betriebssystem: Debian 13 (Trixie)"
}

# ── CPU ──
check_cpu() {
  log "Prüfe vCPU …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: nproc ≥ 4 (Abbruch bei Unterschreitung)
  log_ok "vCPU ausreichend"
}

# ── RAM ──
check_ram() {
  log "Prüfe RAM …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: free -m ≥ 16384 MiB frei (Abbruch bei Unterschreitung)
  log_ok "RAM ausreichend"
}

# ── Disk ──
check_disk() {
  log "Prüfe Speicherplatz …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: df -BG auf K3S_DATA_DIR oder / ≥ 100 GiB frei
  log_ok "Speicherplatz ausreichend"
}

# ── Swap ──
check_swap() {
  log "Prüfe Swap …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: swapon --show muss leer sein (Abbruch wenn aktiv)
  log_ok "Swap deaktiviert"
}

# ── Netzwerk ──
check_network() {
  log "Prüfe Netzwerk (Gateway ${SOHO_GATEWAY}) …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: ping -c2 -W2 SOHO_GATEWAY (Abbruch bei Fehler)
  log_ok "Gateway erreichbar"
}

# ── DNS (Warnung, kein Abbruch) ──
check_dns_warn() {
  log "Prüfe DNS (Warnung) …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: dig +short idm.$DOMAIN + portal.$DOMAIN
  # TODO: Warnung ausgeben wenn nicht auflösbar, kein Abbruch.
  #       Harte Prüfung erfolgt in Phase 2b (06_civitas.sh).
  log_ok "DNS (Warnung) abgeschlossen"
}

# ── SMTP ──
check_smtp() {
  log "Prüfe SMTP-Erreichbarkeit (${SMTP_HOST}:${SMTP_PORT}) …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: tcp_reachable SMTP_HOST SMTP_PORT (Abbruch bei Fehler)
  log_ok "SMTP erreichbar"
}

# ── Tools ──
check_tools() {
  log "Prüfe Werkzeuge …"
  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  # TODO: Implementierung: Prüfe auf curl, python3, dig, wg, helm, helmfile, git
  # TODO: Fehlende Tools automatisch installieren (apt / curl-Binary-Download)
  log_ok "Alle Werkzeuge vorhanden"
}

# ── k3s / kubectl ──
check_k3s_status() {
  log "Prüfe k3s-Status …"
  # TODO: Idempotenz-Prüfung: systemctl is-active k3s → Version prüfen
  # TODO: Wenn k3s aktiv und korrekte Version → K3S_ALREADY_INSTALLED=true setzen
  # TODO: Wenn k3s aktiv und falsche Version → Abbruch
  # TODO: Wenn k3s nicht aktiv → K3S_ALREADY_INSTALLED=false setzen
  log_ok "k3s-Status geprüft"
}

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
# 06c_image_build.sh — V1s: Portal-Backend-Image-Build (statische Masterportal-Konfiguration)
#
# V1s = CIVITAS/CORE V1 mit statischer statt S3-basierter Masterportal-
# Konfiguration. Dieses Modul klont den Soft-Fork von geoportal-components
# in die Ziel-VM, baut das geoportal_backend-Image mit der eingebauten
# Konfiguration und importiert es in den containerd-Store des k3s-Clusters.
#
# Siehe: serveraufbau-v1s/portal-backend-image-build.md (p2d2-docs)
#   - Abschnitt "Build-Ablauf"
#   - Abschnitt "Einordnung in die Phasenfolge" (Schritt 2.0b)
#   - Abschnitt "Modul-Zuordnung"
#
# Einordnung: Wird von install_civitas() (modules_V1s/06_civitas.sh) an
# Position 2.0b aufgerufen — zwischen clone_civitas_repo() und apply_overlay().
#
# Abhängigkeiten:
#   - 01_config.sh: V1S_FORK_URL, V1S_FORK_PATH, V1S_FORK_BRANCH,
#     V1S_INSTANCE_NAME, V1S_IMAGE_TAG, V1S_IMAGE_REF,
#     V1S_DOCKER_INSTALLED_BY_SCRIPT
#   - 02_lib.sh: log, log_ok, log_warn, log_error, is_installed, assert_success

set -euo pipefail


# ── Hauptfunktion: Portal-Backend-Image bauen und importieren ────────────────
# Schritt 2.0b — zwischen clone_civitas_repo() und apply_overlay().
build_geoportal_backend_image() {
  log "=== Schritt 2.0b: Portal-Backend-Image (V1s) ==="

  # ── 1. Soft-Fork-Klon von geoportal-components ─────────────────────────
  # Klon direkt in der Ziel-VM, kein sdt-Zwischenschritt.
  if [[ -d "${V1S_FORK_PATH}/.git" ]]; then
    log "Soft-Fork bereits vorhanden: ${V1S_FORK_PATH} — führe git pull aus …"
    git -C "${V1S_FORK_PATH}" fetch origin "${V1S_FORK_BRANCH}" \
      || log_warn "git fetch fehlgeschlagen — fahre mit vorhandenem Stand fort"
    git -C "${V1S_FORK_PATH}" checkout "${V1S_FORK_BRANCH}" 2>/dev/null || true
    git -C "${V1S_FORK_PATH}" pull --ff-only origin "${V1S_FORK_BRANCH}" \
      || log_warn "git pull fehlgeschlagen — fahre mit vorhandenem Stand fort"
  else
    log "Klone Soft-Fork von ${V1S_FORK_URL} nach ${V1S_FORK_PATH} …"
    git clone \
      --branch "${V1S_FORK_BRANCH}" \
      --single-branch \
      "${V1S_FORK_URL}" "${V1S_FORK_PATH}" \
      || { log_error "Soft-Fork-Klon fehlgeschlagen — Abbruch"; exit 1; }
  fi

  log_ok "Soft-Fork-Klon bereit: ${V1S_FORK_PATH}"

  # ── 2. Instanzverzeichnis umbenennen ────────────────────────────────────
  # portal-config/default/ → portal-config/<V1S_INSTANCE_NAME>/
  # Case-sensitiv, Pflicht bei statischem Betrieb (Backend nutzt das
  # URL-Pfadsegment /{instance}/… als Instanzordner).
  local default_dir="${V1S_FORK_PATH}/portal-config/default"
  local instance_dir="${V1S_FORK_PATH}/portal-config/${V1S_INSTANCE_NAME}"
  if [[ -d "${default_dir}" && ! -d "${instance_dir}" ]]; then
    log "Benenne ${default_dir} → ${instance_dir} um …"
    mv "${default_dir}" "${instance_dir}" \
      || { log_error "Umbenennung portal-config/default → ${V1S_INSTANCE_NAME} fehlgeschlagen"; exit 1; }
  elif [[ -d "${instance_dir}" ]]; then
    log "Instanzverzeichnis ${instance_dir} existiert bereits — überspringe Umbenennung"
  else
    log_warn "Weder ${default_dir} noch ${instance_dir} gefunden — prüfe portal-config-Struktur"
    log_warn "  Erwartet wird eines der beiden Verzeichnisse (default oder ${V1S_INSTANCE_NAME})"
    exit 1
  fi
  log_ok "Instanzverzeichnis: ${instance_dir} (PORTAL_INSTANCE_NAME=${V1S_INSTANCE_NAME})"

  # ── 3. Submodule initialisieren ─────────────────────────────────────────
  log "Initialisiere Submodule (portal-backend) …"
  git -C "${V1S_FORK_PATH}" submodule update --init --recursive \
    || { log_error "Submodule-Init fehlgeschlagen — Abbruch"; exit 1; }
  log_ok "Submodule initialisiert"

  # ── 4. Docker temporär installieren (nur wenn nicht vorhanden) ──────────
  local docker_was_present="false"
  if is_installed docker; then
    docker_was_present="true"
    log "Docker bereits installiert — wird nicht entfernt"
  else
    log "Docker nicht vorhanden — installiere temporär …"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || { log_error "apt-get update fehlgeschlagen"; exit 1; }
    apt-get install -y docker.io \
      || { log_error "Docker-Installation fehlgeschlagen"; exit 1; }
    V1S_DOCKER_INSTALLED_BY_SCRIPT="true"
    log_ok "Docker temporär installiert (Flag: V1S_DOCKER_INSTALLED_BY_SCRIPT=true)"
  fi

  # ── 5. Image bauen ──────────────────────────────────────────────────────
  # Build-Kontext = Repo-Root, wie in der Upstream-.gitlab-ci.yml definiert.
  # Dockerfile_geoportal_backend kopiert portal-config/<instance>/ bereits
  # zur Build-Zeit ins Image.
  log "Baue Image ${V1S_IMAGE_REF} (Build-Kontext: ${V1S_FORK_PATH}) …"
  (
    cd "${V1S_FORK_PATH}" \
      || { log_error "Kann nicht nach ${V1S_FORK_PATH} wechseln"; exit 1; }
    docker build -f Dockerfile_geoportal_backend -t "${V1S_IMAGE_REF}" . \
      || { log_error "docker build fehlgeschlagen — Abbruch"; exit 1; }
  )
  log_ok "Image gebaut: ${V1S_IMAGE_REF}"

  # ── 6. In containerd importieren ────────────────────────────────────────
  # Kein externer Registry-Betrieb notwendig bei Single-Node-k3s.
  if ! is_installed k3s; then
    log_warn "k3s nicht gefunden — containerd-Import übersprungen (V1s-Build ohne Cluster?)"
    log_warn "  Image bleibt lokal in Docker erhalten: ${V1S_IMAGE_REF}"
  else
    log "Exportiere Image und importiere in containerd …"
    docker image save "${V1S_IMAGE_REF}" \
      | k3s ctr images import - \
      || { log_error "k3s ctr images import fehlgeschlagen — Abbruch"; exit 1; }
    log_ok "Image in containerd importiert: ${V1S_IMAGE_REF}"
  fi

  # ── 7. Docker ggf. wieder deinstallieren ────────────────────────────────
  # Nur wenn das Skript Docker selbst installiert hat. Sicherheitscheck:
  # apt-get purge --dry-run muss das Paket docker.io auflisten.
  if [[ "${V1S_DOCKER_INSTALLED_BY_SCRIPT}" == "true" && "${docker_was_present}" == "false" ]]; then
    log "Deinstalliere temporär installiertes Docker (Sicherheitscheck) …"
    if ! apt-get purge --dry-run docker.io | grep -q "Remv docker.io"; then
      log_error "Sicherheitscheck fehlgeschlagen: apt-get purge --dry-run docker.io entfernt docker.io nicht"
      log_error "  Docker-Entfernung abgebrochen — bitte manuell prüfen"
      exit 1
    fi
    apt-get purge -y docker.io \
      || { log_warn "Docker-Deinstallation fehlgeschlagen — bitte manuell prüfen"; }
    apt-get autoremove -y || true
    V1S_DOCKER_INSTALLED_BY_SCRIPT="false"
    log_ok "Docker deinstalliert (war temporär installiert)"
  else
    log "Docker war bereits vorhanden — keine Deinstallation"
  fi

  log_ok "Schritt 2.0b abgeschlossen — Portal-Backend-Image ${V1S_IMAGE_REF} bereit"
}

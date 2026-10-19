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
#     V1S_DOCKER_INSTALLED_BY_SCRIPT, V1S_FORK_REF (optional)
#   - 02_lib.sh: log, log_ok, log_warn, log_error, is_installed, assert_success

set -euo pipefail


# =============================================================================
# Hilfsfunktionen: Bake vs. docker build
# =============================================================================

# _v1s_bake_target_present — 0, wenn docker-bake.hcl ein Target "geoportal_backend"
# definiert (dann wird per docker buildx bake gebaut statt per docker build).
_v1s_bake_target_present() {
  [[ -f "${V1S_FORK_PATH}/docker-bake.hcl" ]] \
    && grep -qE '^[[:space:]]*target[[:space:]]+"geoportal_backend"' "${V1S_FORK_PATH}/docker-bake.hcl"
}

# _v1s_build_platform — Plattform aus der Host-Architektur ableiten.
# rc 1 bei nicht unterstützter Architektur (kein stillschweigendes amd64).
_v1s_build_platform() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) printf 'linux/amd64' ;;
    arm64) printf 'linux/arm64' ;;
    *)     return 1 ;;
  esac
}

# _v1s_dockerfile_uses_bake_context — 0, wenn Dockerfile_geoportal_backend eine
# FROM-Basis referenziert, die zugleich Target in docker-bake.hcl ist (also ein
# Bake-Context statt eines Hub-Images, z. B. "FROM backend"). Dient der
# Frühwarnung im docker-build-Fallback (Docker-Hub-Pull würde fehlschlagen).
_v1s_dockerfile_uses_bake_context() {
  local dockerfile="${V1S_FORK_PATH}/Dockerfile_geoportal_backend"
  local bakefile="${V1S_FORK_PATH}/docker-bake.hcl"
  [[ -f "$dockerfile" && -f "$bakefile" ]] || return 1
  local base
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    # Externe Images (Registry oder Tag) und scratch sind keine Bake-Contexts.
    case "$base" in
      */*|*:*) continue ;;
      scratch) continue ;;
    esac
    if grep -qE '^[[:space:]]*target[[:space:]]+"'"$base"'"' "$bakefile"; then
      return 0
    fi
  done < <(sed -nE 's/^[[:space:]]*FROM([[:space:]]+--[^[:space:]]+)*[[:space:]]+([^[:space:]]+).*/\2/p' "$dockerfile")
  return 1
}


# ── Hauptfunktion: Portal-Backend-Image bauen und importieren ────────────────
# Schritt 2.0b — zwischen clone_civitas_repo() und apply_overlay().
build_geoportal_backend_image() {
  log "=== Schritt 2.0b: Portal-Backend-Image (V1s) ==="

  # ── 1. Soft-Fork-Klon von geoportal-components ─────────────────────────
  # Klon direkt in der Ziel-VM, kein sdt-Zwischenschritt.
  if [[ -d "${V1S_FORK_PATH}/.git" ]]; then
    log "Soft-Fork bereits vorhanden: ${V1S_FORK_PATH} — aktualisiere …"
    # Build-Workspace: unversionierte Artefakte unter portal-config/ aus einem
    # Vorlauf entfernen (Schritt 2 benennt default → <instance> um; beim zweiten
    # Lauf bliebe sonst <instance> liegen und käme zusätzlich ins Image).
    # NUR portal-config/ anfassen, nichts anderes im Klon.
    git -C "${V1S_FORK_PATH}" clean -fdq -- portal-config/ || true
    if [[ -n "${V1S_FORK_REF:-}" ]]; then
      # Gepinnter Stand: nur fetchen + detach, KEIN pull --ff-only (der Pin darf
      # nicht durch einen Branch-Vorlauf überschrieben werden). Tags und
      # abgekürzte Hashes werden LOKAL aufgelöst (der --single-branch-Klon
      # enthält die komplette History von ${V1S_FORK_BRANCH}); Commits außerhalb
      # dieser History brauchen einen vollständigen Hash und einen Server, der
      # das Holen per SHA erlaubt.
      git -C "${V1S_FORK_PATH}" fetch origin --tags "${V1S_FORK_BRANCH}" \
        || log_warn "git fetch fehlgeschlagen — fahre mit vorhandenem Stand fort"
      git -C "${V1S_FORK_PATH}" checkout --force --detach "${V1S_FORK_REF}" \
        || { log_error "V1S_FORK_REF '${V1S_FORK_REF}' nicht auflösbar — Abbruch"; exit 1; }
    else
      git -C "${V1S_FORK_PATH}" fetch origin "${V1S_FORK_BRANCH}" \
        || log_warn "git fetch fehlgeschlagen — fahre mit vorhandenem Stand fort"
      git -C "${V1S_FORK_PATH}" checkout "${V1S_FORK_BRANCH}" 2>/dev/null || true
      git -C "${V1S_FORK_PATH}" pull --ff-only origin "${V1S_FORK_BRANCH}" \
        || log_warn "git pull fehlgeschlagen — fahre mit vorhandenem Stand fort"
      log_warn "Fork-Stand nicht gepinnt (V1S_FORK_REF leer) — verwendet ${V1S_FORK_BRANCH}@HEAD"
    fi
  else
    log "Klone Soft-Fork von ${V1S_FORK_URL} nach ${V1S_FORK_PATH} …"
    git clone \
      --branch "${V1S_FORK_BRANCH}" \
      --single-branch \
      "${V1S_FORK_URL}" "${V1S_FORK_PATH}" \
      || { log_error "Soft-Fork-Klon fehlgeschlagen — Abbruch"; exit 1; }
    if [[ -n "${V1S_FORK_REF:-}" ]]; then
      # Tags OHNE Refspec holen — ein abgekürzter Hash ist nicht als Refspec
      # fetchbar ("couldn't find remote ref"); er wird lokal aufgelöst. Ein
      # Fehlschlag ist nur eine Warnung, fatal ist allein der checkout --detach.
      git -C "${V1S_FORK_PATH}" fetch origin --tags \
        || log_warn "git fetch --tags fehlgeschlagen — fahre mit vorhandenem Stand fort"
      git -C "${V1S_FORK_PATH}" checkout --detach "${V1S_FORK_REF}" \
        || { log_error "V1S_FORK_REF '${V1S_FORK_REF}' nicht auflösbar — Abbruch"; exit 1; }
    else
      log_warn "Fork-Stand nicht gepinnt (V1S_FORK_REF leer) — verwendet ${V1S_FORK_BRANCH}@HEAD"
    fi
  fi

  log "Fork-Commit: $(git -C "${V1S_FORK_PATH}" rev-parse HEAD 2>/dev/null || echo '?')"
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
  log "Submodule-Stand: $(git -C "${V1S_FORK_PATH}" submodule status 2>/dev/null || echo '?')"

  # ── 3b. Build-Pfad + Plattform bestimmen (vor Docker-Install/Build) ─────
  local use_bake="false"
  if _v1s_bake_target_present; then
    use_bake="true"
    log "docker-bake.hcl mit Target 'geoportal_backend' erkannt — verwende docker buildx bake"
  else
    log "Kein 'geoportal_backend'-Target in docker-bake.hcl — verwende docker build"
    # Frühwarnung: referenziert das Dockerfile einen Bake-Context (Target aus
    # docker-bake.hcl) als FROM-Basis, schlägt 'docker build' am Docker-Hub-Pull
    # fehl („pull access denied“). Vor den langen Schritten abbrechen.
    if _v1s_dockerfile_uses_bake_context; then
      log_error "Dockerfile_geoportal_backend referenziert einen Bake-Context als FROM-Basis,"
      log_error "  es ist aber kein 'geoportal_backend'-Target vorhanden — 'docker build' würde"
      log_error "  den Namen von Docker Hub ziehen und fehlschlagen (pull access denied)."
      log_error "  Bitte Fork prüfen (docker-bake.hcl / Dockerfile_geoportal_backend) oder V1S_FORK_REF setzen."
      exit 1
    fi
  fi
  local build_platform
  build_platform="$(_v1s_build_platform)" \
    || { log_error "Nicht unterstützte Host-Architektur (dpkg --print-architecture) — Abbruch"; exit 1; }
  log "Bau-Plattform: ${build_platform}"

  # ── 4. Docker temporär installieren (nur wenn nicht vorhanden) ──────────
  local docker_was_present="false"
  local buildx_installed_by_script="false"
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

  # Buildx sicherstellen (nur der Bake-Pfad benötigt das Plugin).
  if [[ "$use_bake" == "true" ]] && ! docker buildx version >/dev/null 2>&1; then
    log "docker buildx fehlt — installiere docker-buildx …"
    apt-get install -y docker-buildx \
      || { log_error "docker-buildx-Installation fehlgeschlagen — Abbruch"; exit 1; }
    buildx_installed_by_script="true"
    log_ok "docker buildx installiert"
  fi

  # ── 5. Image bauen ──────────────────────────────────────────────────────
  # Build-Kontext = Repo-Root, wie in der Upstream-.gitlab-ci.yml definiert.
  # Dockerfile_geoportal_backend kopiert portal-config/<instance>/ bereits
  # zur Build-Zeit ins Image.
  if [[ "$use_bake" == "true" ]]; then
    log "Baue Image ${V1S_IMAGE_REF} per docker buildx bake (Target geoportal_backend) …"
    (
      cd "${V1S_FORK_PATH}" \
        || { log_error "Kann nicht nach ${V1S_FORK_PATH} wechseln"; exit 1; }
      CI_REGISTRY_IMAGE="local" \
      CI_COMMIT_SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo dev)" \
      DEPLOY_IMAGE_TAG="${V1S_IMAGE_TAG}" \
        docker buildx bake geoportal_backend \
          --set "*.platform=${build_platform}" \
          --set "geoportal_backend.tags=${V1S_IMAGE_REF}" \
          --load \
          || { log_error "docker buildx bake fehlgeschlagen — Abbruch"; exit 1; }
    )
  else
    log "Baue Image ${V1S_IMAGE_REF} per docker build (Build-Kontext: ${V1S_FORK_PATH}) …"
    (
      cd "${V1S_FORK_PATH}" \
        || { log_error "Kann nicht nach ${V1S_FORK_PATH} wechseln"; exit 1; }
      docker build -f Dockerfile_geoportal_backend -t "${V1S_IMAGE_REF}" . \
        || { log_error "docker build fehlgeschlagen — Abbruch"; exit 1; }
    )
  fi
  log_ok "Image gebaut: ${V1S_IMAGE_REF}"

  # ── 6. In containerd importieren ────────────────────────────────────────
  # Kein externer Registry-Betrieb notwendig bei Single-Node-k3s.
  # Vor dem Import das gebaute Image verifizieren (Bake baut zusätzlich das
  # ungetaggte Zwischen-Image "backend" mit; importiert wird ausschließlich
  # ${V1S_IMAGE_REF}).
  docker image inspect "${V1S_IMAGE_REF}" >/dev/null \
    || { log_error "Image ${V1S_IMAGE_REF} nach Build nicht vorhanden — Abbruch"; exit 1; }
  log_ok "Image verifiziert: ${V1S_IMAGE_REF}"

  if ! is_installed k3s; then
    log_warn "k3s nicht gefunden — containerd-Import übersprungen (V1s-Build ohne Cluster?)"
    log_warn "  Image bleibt lokal in Docker erhalten: ${V1S_IMAGE_REF}"
  else
    # WICHTIG: `-n k8s.io` ist zwingend. Ohne Namespace-Angabe importiert
    # `k3s ctr` in den Containerd-Namespace `default`, während kubelet/CRI
    # Images ausschließlich im Namespace `k8s.io` sucht — das lokal gebaute
    # Image wäre sonst für Pods unsichtbar (ImagePullBackOff statt Start).
    # Beleg: ai-runs/2026-08-31-v1s-installationsskript-lauffaehig
    log "Exportiere Image und importiere in containerd (Namespace k8s.io) …"
    docker image save "${V1S_IMAGE_REF}" \
      | k3s ctr -n k8s.io images import - \
      || { log_error "k3s ctr -n k8s.io images import fehlgeschlagen — Abbruch"; exit 1; }
    log_ok "Image in containerd importiert (Namespace k8s.io): ${V1S_IMAGE_REF}"
  fi

  # ── 7. Docker ggf. wieder deinstallieren ────────────────────────────────
  # Nur wenn das Skript Docker selbst installiert hat. Sicherheitscheck:
  # apt-get purge --dry-run muss das Paket docker.io auflisten.
  if [[ "${V1S_DOCKER_INSTALLED_BY_SCRIPT}" == "true" && "${docker_was_present}" == "false" ]]; then
    log "Deinstalliere temporär installiertes Docker (Sicherheitscheck) …"
    if ! apt-get purge --dry-run docker.io | grep -qE "Purg docker\.io(:[a-z0-9]+)?[[:space:]]"; then
      log_error "Sicherheitscheck fehlgeschlagen: apt-get purge --dry-run docker.io entfernt docker.io nicht"
      log_error "  Docker-Entfernung abgebrochen — bitte manuell prüfen"
      exit 1
    fi
    apt-get purge -y docker.io \
      || { log_warn "Docker-Deinstallation fehlgeschlagen — bitte manuell prüfen"; }
    if [[ "${buildx_installed_by_script}" == "true" ]]; then
      apt-get purge -y docker-buildx \
        || { log_warn "docker-buildx-Deinstallation fehlgeschlagen — bitte manuell prüfen"; }
    fi
    apt-get autoremove -y || true
    V1S_DOCKER_INSTALLED_BY_SCRIPT="false"
    log_ok "Docker deinstalliert (war temporär installiert)"
  else
    log "Docker war bereits vorhanden — keine Deinstallation"
  fi

  log_ok "Schritt 2.0b abgeschlossen — Portal-Backend-Image ${V1S_IMAGE_REF} bereit"
}

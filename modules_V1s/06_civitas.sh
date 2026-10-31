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
# 06_civitas.sh – Phase 2: CIVITAS/CORE-Plattform via cc_cli (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 06
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 2
#
# Enthält die Orchestrierungsfunktion install_civitas(), sowie alle
# Repository-, Overlay- und cc_cli-Lifecycle-Funktionen.
#
# Netzwerk- und Zertifikatsfunktionen (setup_wireguard, patch_playbook_urls,
# cleanup_geodata_ingress, restore_backup_and_switch_to_prod, request_fresh_prod_certificates, resolve_target_state, apply_target_state, verify_certificates)
# wurden nach 06a_network_certs.sh ausgelagert.
#
# IDM-Provisionierungsfunktionen (ensure_keycloak_admin_user) wurden nach
# 06b_idm_provisioning.sh ausgelagert.
#
# Abhängigkeiten:
#   - 01_config.sh: DOMAIN, CC_CLI_VERSION, SMTP_*, …
#   - 02_lib.sh: log_*, wait_pods_ready, dns_resolves, gen_policy_password
#   - 06a_network_certs.sh: setup_wireguard, patch_playbook_urls, …
#   - 06b_idm_provisioning.sh: ensure_keycloak_admin_user
#   - templates_V1s/inventory.yml.tpl
#
# Binary-Name: cc_cli (Unterstrich) – pip-Paket heißt cc-cli (Bindestrich).
# cc_cli validate und cc_cli exec kennen kein --inventory-Flag.
# Beide lesen ./cc_cli_inventory.yml aus dem CWD.
# CWD ist das Verzeichnis mit playbook.yml, das zur Laufzeit per
# find() unter CC_V1_REPO_PATH ermittelt und in CC_CLI_PLAYBOOK_DIR
# gespeichert wird. render_inventory schreibt das Inventory dorthin.

CC_CLI_VENV_PATH="${CC_CLI_VENV_PATH:-/opt/civitas-core-venv}"


# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
install_civitas() {
  log "=== Phase 2: CIVITAS/CORE-Plattform ==="
  check_dns_hard
  clone_civitas_repo
  check_helm_repo_egress           # Schritt 2.0c: Egress-Preflight (Helm-Repos)
  build_geoportal_backend_image   # Schritt 2.0b: V1s — Portal-Backend-Image bauen und in containerd importieren
  apply_overlay
  patch_masterportal_release_name
  install_cc_cli
  verify_k8s_import
  render_inventory
  if [[ "${WG_ENABLED}" == "true" ]]; then
    setup_wireguard
  else
    log "WireGuard deaktiviert (WG_ENABLE=false) — Direktbetrieb bzw. HAProxy/Portweiterleitung im selben Netz"
  fi
  patch_playbook_urls
  cleanup_geodata_ingress
  run_cc_cli_validate
  run_cc_cli_exec


  # Pods in den erwarteten Namespaces abwarten
  local ns_found=0
  for ns in "${K8S_NAMESPACES[@]}"; do
    if wait_pods_ready "${ns}"; then
      ns_found=$((ns_found + 1))
    else
      log_warn "Nicht alle Pods in Namespace ${ns} wurden Ready – wird in Phase 3 erneut geprueft"
    fi
  done
  if [[ ${ns_found} -eq 0 ]]; then
    log_error "Keiner der erwarteten Namespaces gefunden: ${K8S_NAMESPACES[*]}"
    log_error "  Namespace-Konfiguration in 01_config.sh pruefen"
    exit 1
  fi
  local resolved_state
  resolved_state=$(resolve_target_state)
  log "Zielzustand fuer Zertifikate: ${resolved_state}"

  # set -e: ein Fehler von apply_target_state beendet das Skript bereits hier.
  # Der frühere apply_rc-Check war toter Code (apply_target_state erreicht den
  # Rückgabewert unter set -e bei einem Fehler gar nicht).
  apply_target_state "${resolved_state}"

  if ! verify_certificates "${resolved_state}"; then
    log_error "verify_certificates: mindestens ein Host ohne gueltigen Nachweis"
    exit 1
  fi

  # LE-Backup VOR der IDM-Provisionierung schreiben: nach Neuausstellung
  # (LE_FRESH_PROD_ISSUED) oder wenn das Cluster-tls.crt vom Backup abweicht
  # (z. B. cert-manager hat erneuert). So geht ein Backup bei IDM-Fehler nicht
  # verloren.

  if [[ "${LE_FRESH_PROD_ISSUED:-false}" == "true" ]] || cluster_backup_diverges; then
    if ! write_le_backup; then
      log_error "Neu ausgestellte LE-Zertifikate konnten nicht gesichert werden"
      exit 1
    fi
  fi

  if ! ensure_keycloak_admin_user; then
    log_error "CIVITAS/CORE-Cluster ist deployt, aber die Keycloak-Admin-Provisionierung ist unvollständig (betroffene Punkte siehe oben)."
    exit 1
  fi

  configure_pgadmin_ca_trust || log_warn "pgAdmin-CA-Trust fehlgeschlagen — OIDC-Login ueber Keycloak manuell pruefen"
  log_ok "Phase 2 abgeschlossen – CIVITAS/CORE laeuft in Namespaces: ${K8S_NAMESPACES[*]}"
}


# ── Schritt 2.0: DNS hart prüfen ──────────────────────────────────────────────
check_dns_hard() {
  log "Prüfe DNS (harte Prüfung) …"
  local dns_ok=true

  if ! dns_resolves "idm.${DOMAIN}"; then
    log_error "DNS: idm.${DOMAIN} nicht auflösbar – Eintrag im DNS setzen"
    dns_ok=false
  fi
  if ! dns_resolves "portal.${DOMAIN}"; then
    log_error "DNS: portal.${DOMAIN} nicht auflösbar – Eintrag im DNS setzen"
    dns_ok=false
  fi

  if [[ "${dns_ok}" == false ]]; then
    log_error "DNS-Prüfung fehlgeschlagen – Phase 2 wird abgebrochen"
    exit 1
  fi
  log_ok "DNS: idm.${DOMAIN} und portal.${DOMAIN} auflösbar"
}


# ── Schritt 2.1: cc_cli installieren ──────────────────────────────────────────
# pip-Paket: cc-cli (Bindestrich)  |  Binary: cc_cli (Unterstrich)
# Debian 13 (Trixie / PEP 668) → Installation in isoliertem venv
install_cc_cli() {
  log "Installiere cc_cli ${CC_CLI_VERSION} aus GitLab Package Registry …"

  # Idempotenz: Binary vorhanden und Version korrekt?
  local -i fresh=0
  if [[ -f "${CC_CLI_VENV_PATH}/bin/cc_cli" ]]; then
    local installed_ver
    installed_ver="$(
      "${CC_CLI_VENV_PATH}/bin/pip" show cc-cli 2>/dev/null \
        | grep -oP '(?<=Version: )\S+' \
        || true
    )"
    if [[ "${installed_ver}" == "${CC_CLI_VERSION}" ]]; then
      log_ok "cc_cli ${CC_CLI_VERSION} bereits installiert – überspringe Neuinstallation"
    else
      log_warn "cc_cli ${installed_ver:-unbekannt} gefunden, erwartet ${CC_CLI_VERSION} – reinstalliere"
      rm -rf "${CC_CLI_VENV_PATH}"
      fresh=1
    fi
  else
    fresh=1
  fi

  if [[ "${fresh}" -eq 1 ]]; then
    apt-get install -y python3-venv --quiet
    python3 -m venv "${CC_CLI_VENV_PATH}"
    "${CC_CLI_VENV_PATH}/bin/pip" install \
      --quiet \
      --extra-index-url "${CC_CLI_REGISTRY_URL}" \
      "cc-cli==${CC_CLI_VERSION}"
    log "Installiere ansible ${ANSIBLE_VERSION} ins venv ..."
    "${CC_CLI_VENV_PATH}/bin/pip" install --quiet "ansible==${ANSIBLE_VERSION}"
    log_ok "ansible installiert: $("${CC_CLI_VENV_PATH}/bin/ansible" --version | head -1)"

    log "Setze Symlinks fuer ansible-playbook und ansible nach /usr/local/bin ..."
    ln -sf "${CC_CLI_VENV_PATH}/bin/ansible-playbook" /usr/local/bin/ansible-playbook
    ln -sf "${CC_CLI_VENV_PATH}/bin/ansible"          /usr/local/bin/ansible
    log_ok "ansible-playbook im System-PATH: $(ansible-playbook --version | head -1)"
    log_ok "cc_cli ${CC_CLI_VERSION} installiert"
  fi

  # kubernetes-Python-Client gegen den Pin sicherstellen (beide Pfade,
  # auch im Idempotenz-Fruehrueckpfad, ohne das venv zu loeschen).
  ensure_k8s_pin
}


# ── kubernetes-Python-Client: Pin-Durchsetzung ────────────────────────────────
# 37.0.0 entfernt kubernetes.client.apis (von kubernetes.core genutzt).
# ensure_k8s_pin prueft die installierte Version gegen K8S_PY_PIN und
# installiert bei Abweichung nur den Pin nach, ohne das venv zu loeschen.

_k8s_installed_version() {
  "${CC_CLI_VENV_PATH}/bin/pip" show kubernetes 2>/dev/null \
    | sed -n 's/^Version: *//p' \
    | head -1 \
    || true
}

# 0 = installierte Version erfuellt K8S_PY_PIN, 1 = nicht (oder nicht feststellbar).
_k8s_pin_satisfied() {
  local installed="$1"
  [[ -n "${installed}" ]] || return 1
  local py="${CC_CLI_VENV_PATH}/bin/python3"
  [[ -x "${py}" ]] || return 1
  K8S_INSTALLED="${installed}" K8S_PIN="${K8S_PY_PIN}" "${py}" - >/dev/null 2>&1 <<'PY'
import os
import sys
try:
    from packaging.specifiers import SpecifierSet
except Exception:
    sys.exit(1)
installed = os.environ.get("K8S_INSTALLED", "")
pin = os.environ.get("K8S_PIN", "")
spec = pin[len("kubernetes"):] if pin.startswith("kubernetes") else pin
try:
    ok = SpecifierSet(spec).contains(installed)
except Exception:
    sys.exit(1)
sys.exit(0 if ok else 1)
PY
}

_log_python_deps() {
  local k8s_ver ansible_ver core_ver
  k8s_ver="$(_k8s_installed_version)"
  ansible_ver="$("${CC_CLI_VENV_PATH}/bin/ansible" --version 2>/dev/null | head -1 || true)"
  core_ver="$("${CC_CLI_VENV_PATH}/bin/ansible-galaxy" collection list kubernetes.core 2>/dev/null | sed -n 's/^kubernetes\.core[[:space:]]*//p' | head -1 || true)"
  log "venv-Versionen: kubernetes=${k8s_ver:-nicht installiert} | ansible=${ansible_ver:-unbekannt} | kubernetes.core=${core_ver:-unbekannt}"
  return 0
}

ensure_k8s_pin() {
  local installed
  installed="$(_k8s_installed_version)"
  if _k8s_pin_satisfied "${installed}"; then
    log_ok "kubernetes-Client ${installed} erfuellt Pin ${K8S_PY_PIN}"
  else
    if [[ -n "${installed}" ]]; then
      log_warn "kubernetes-Client ${installed} entspricht nicht ${K8S_PY_PIN} – installiere nach"
    else
      log "kubernetes-Client nicht installiert – installiere ${K8S_PY_PIN}"
    fi
    "${CC_CLI_VENV_PATH}/bin/pip" install --quiet "${K8S_PY_PIN}"
    log_ok "kubernetes-Bibliothek installiert (${K8S_PY_PIN})"
  fi
  _log_python_deps
}


# ── Smoke-Test: Importpfad, den kubernetes.core nutzt ──────────────────────────
# Bricht vor cc_cli exec ab, wenn kubernetes.client.apis nicht mehr importierbar
# ist (Client 37.0.0). Meldet, ob der neue Pfad kubernetes.client.api ginge.
verify_k8s_import() {
  local py="${CC_CLI_VENV_PATH}/bin/python3"
  [[ -x "${py}" ]] || { log_error "venv-Python nicht gefunden: ${py}"; exit 1; }

  log "Pruefe kubernetes-Client-Importpfad (kubernetes.client.apis) ..."
  local legacy_out
  if legacy_out="$("${py}" -W default -c 'from kubernetes.client.apis import core_v1_api' 2>&1)"; then
    log_ok "kubernetes-Client-Importpfad kubernetes.client.apis funktioniert"
  else
    local last_err
    last_err="$(printf '%s\n' "${legacy_out}" | grep -v '^$' | tail -1)"
    log_error "kubernetes-Client-Import fehlgeschlagen: ${last_err:-keine Detailzeile}"
    log_error "K8S_PY_PIN=${K8S_PY_PIN} erzwingt einen kompatiblen Client; Installation erneut starten."
    if "${py}" -W default -c 'from kubernetes.client.api import core_v1_api' >/dev/null 2>&1; then
      log_error "Neuer Pfad kubernetes.client.api funktioniert – die Collection nutzt aber weiterhin kubernetes.client.apis."
    fi
    exit 1
  fi

  if "${py}" -W default -c 'from kubernetes.client.api import core_v1_api' >/dev/null 2>&1; then
    log "Neuer Importpfad kubernetes.client.api ebenfalls verfuegbar (nur zur Info)."
  else
    log_warn "Neuer Importpfad kubernetes.client.api nicht verfuegbar – Client pruefen."
  fi
}


# ── Re-Run-Guard: erwartete vs. unerwartete Änderungen im Klon ─────────────────
# Der Installer macht den Klon bei jedem Lauf selbst unsauber (Overlay, sed-Patches,
# ungetracktes Inventory/Logs/Backup). Diese erwarteten Änderungen werden beim
# Re-Run zurückgesetzt; unerwartete (manuelle Edits) führen zum harten Abbruch,
# außer CC_V1_REPO_FORCE_CLEAN=true.

_civitas_overlay_targets=()
_civitas_collect_overlay_targets() {
  _civitas_overlay_targets=()
  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local src="${script_dir}/overlay_V1s" rel f
  [[ -d "${src}" ]] || return 0
  while IFS= read -r -d '' f; do
    rel="${f#"${src}"/}"
    _civitas_overlay_targets+=("${rel}")
  done < <(find "${src}" -type f -print0)
}

# _civitas_is_expected <pfad-relativ-zum-repo> — 0 = erwartet (Allowlist), 1 = unerwartet.
_civitas_is_expected() {
  local p="$1" rel
  for rel in "${_civitas_overlay_targets[@]}" "${CIVITAS_PATCH_TARGETS[@]}"; do
    [[ "${p}" == "core_platform/${rel}" ]] && return 0
  done
  [[ "${p}" == "core_platform/cc_cli_inventory.yml" ]] && return 0
  [[ "${p}" == "core_platform/logs/"* ]] && return 0
  [[ "${p}" == "core_platform/.overlay_backup/"* ]] && return 0
  return 1
}

# _civitas_repo_unexpected_changes <repo> — stdout: unerwartete Pfade, einer je Zeile.
_civitas_repo_unexpected_changes() {
  local repo="$1" entry status pathpart old new
  _civitas_collect_overlay_targets
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    pathpart="${entry:3}"
    if [[ "${status:0:1}" == "R" ]]; then
      old="${pathpart%% -> *}"; new="${pathpart#* -> }"
      _civitas_is_expected "${old}" || printf '%s\n' "${old}"
      _civitas_is_expected "${new}" || printf '%s\n' "${new}"
    else
      _civitas_is_expected "${pathpart}" || printf '%s\n' "${pathpart}"
    fi
  done < <(git -C "${repo}" status --porcelain=v1 -z 2>/dev/null)
}

# _civitas_repo_reset_installer_changes <repo> — 0 = ok/zurückgesetzt, 1 = Abbruch.
_civitas_repo_reset_installer_changes() {
  local repo="$1" unexpected p
  unexpected="$(_civitas_repo_unexpected_changes "${repo}")"
  if [[ -n "${unexpected}" && "${CC_V1_REPO_FORCE_CLEAN:-false}" != "true" ]]; then
    log_error "Unerwartete Änderungen im Klon ${repo}:"
    while IFS= read -r p; do
      [[ -n "${p}" ]] && log_error "  ${p}"
    done <<< "${unexpected}"
    log_error "Manuell prüfen oder CC_V1_REPO_FORCE_CLEAN=true setzen."
    return 1
  fi
  log "Setze erwartete Installer-Änderungen im Klon zurück …"
  git -C "${repo}" reset --hard -q HEAD
  git -C "${repo}" clean -fdq -e 'core_platform/logs' -e 'core_platform/cc_cli_inventory.yml'
}


# ── Schritt 2.0: Repository klonen ────────────────────────────────────────────
clone_civitas_repo() {
  log "Klone CIVITAS/CORE-Repository nach ${CC_V1_REPO_PATH} (Ref: ${CC_V1_REPO_TAG}) …"
  local core_link="${CIVITAS_CORE_LINK:-/opt/civitas-core}"

  if [[ -d "${CC_V1_REPO_PATH}/.git" ]]; then
    log "Repository bereits vorhanden — aktualisiere auf Ref ${CC_V1_REPO_TAG} …"
    _civitas_repo_reset_installer_changes "${CC_V1_REPO_PATH}" || return 1
    git -C "${CC_V1_REPO_PATH}" fetch --tags origin \
      || { log_error "git fetch --tags fehlgeschlagen — Abbruch"; return 1; }
    git -C "${CC_V1_REPO_PATH}" checkout --force "${CC_V1_REPO_TAG}" \
      || { log_error "Ref '${CC_V1_REPO_TAG}' nicht auscheckbar — Abbruch"; return 1; }
  else
    git clone \
      --branch "${CC_V1_REPO_TAG}" \
      --single-branch \
      "${CC_V1_REPO_URL}" \
      "${CC_V1_REPO_PATH}" \
      || { log_error "git clone fehlgeschlagen: ${CC_V1_REPO_URL} (Ref ${CC_V1_REPO_TAG})"; return 1; }
  fi

  # Commit-Pin prüfen (zusätzlich zum Tag; verhindert stilles Driften bei
  # verschobenem Tag). head_sha wird prefix-vergleichen, damit auch ein
  # abgekürzter Pin akzeptiert wird.
  local head_sha
  head_sha="$(git -C "${CC_V1_REPO_PATH}" rev-parse HEAD 2>/dev/null || echo '')"
  if [[ -n "${CC_V1_REPO_COMMIT:-}" && "${head_sha}" != "${CC_V1_REPO_COMMIT}"* ]]; then
    log_error "Commit-Pin verletzt: ${CC_V1_REPO_TAG} zeigt auf ${head_sha}, erwartet ${CC_V1_REPO_COMMIT} (Tag verschoben?)"
    return 1
  fi
  [[ -n "${CC_V1_REPO_COMMIT:-}" ]] || log_warn "Kein Commit-Pin: Stand ${head_sha} nicht gegen ein Soll geprueft"

  # Gepinnten Stand protokollieren (Tag exakt bzw. Commit-SHA).
  local describe_out
  describe_out="$(git -C "${CC_V1_REPO_PATH}" describe --tags --exact-match 2>/dev/null || true)"
  if [[ -n "${describe_out}" ]]; then
    log_ok "CIVITAS/CORE-Stand: ${describe_out}"
  else
    log_ok "CIVITAS/CORE-Stand: Commit $(git -C "${CC_V1_REPO_PATH}" rev-parse HEAD 2>/dev/null || echo 'unbekannt')"
  fi

  # Symlink /opt/civitas-core → /opt/civitas-core-v1
  if [[ "$(readlink "${core_link}" 2>/dev/null)" != "${CC_V1_REPO_PATH}" ]]; then
    ln -sfn "${CC_V1_REPO_PATH}" "${core_link}"
    log "Symlink gesetzt: ${core_link} → ${CC_V1_REPO_PATH}"
  else
    log "Symlink bereits korrekt: ${core_link} → ${CC_V1_REPO_PATH}"
  fi

  # Abnahmekriterien
  [[ -d "${CC_V1_REPO_PATH}/.git" ]] \
    || { log_error "Repository-Verzeichnis fehlt nach Clone: ${CC_V1_REPO_PATH}"; return 1; }
  if [[ ! -f "${CC_CLI_PLAYBOOK_DIR}/playbook.yml" ]]; then
    log_error "playbook.yml nicht gefunden in ${CC_CLI_PLAYBOOK_DIR}"
    log_error "  Verfuegbare playbook.yml:"
    find "${CC_V1_REPO_PATH}" -name "playbook.yml" | sort >&2
    exit 1
  fi
  log_ok "cc_cli Arbeitsverzeichnis: ${CC_CLI_PLAYBOOK_DIR}"

  [[ "$(readlink "${core_link}")" == "${CC_V1_REPO_PATH}" ]] \
    || { log_error "Symlink ${core_link} zeigt nicht auf ${CC_V1_REPO_PATH}"; return 1; }

  log_ok "Repository bereit: ${CC_V1_REPO_PATH}"
}

# ── Schritt 2.0c: Egress-Preflight für Helm-Repos ─

# ── Schritt 2.0c: Egress-Preflight für Helm-Repos ────────────────────────────
# Liest die Helm-Repo-URLs aus dem GEKLONTEN Stand (software_references.yml, Feld
# helm_repo_url) und prüft jede über `helm repo add` in ein temporäres Helm-
# Verzeichnis (das Binary, das später auch lädt), bevor cc_cli validate/exec die
# Charts laden. Verhindert, dass ein transient gestörter Egress (z. B. IPv6-Reset
# zu GitHub Pages) erst nach 45 Minuten mitten im Playbook abbricht. Keine
# hartkodierte URL-Liste im Installer — die 13er-Testliste dient nur als Fixture
# in den Tests.
_egress_probe_helm() {   # $1 = URL; rc 0 = index.yaml per helm geladen und geparst
  local url="$1" tmp rc=0 attempt
  tmp="$(mktemp -d)"; mkdir -p "${tmp}/cfg" "${tmp}/cache/repository" "${tmp}/data"
  for (( attempt = 1; attempt <= ${CC_EGRESS_ATTEMPTS:-3}; attempt++ )); do
    rc=0
    HELM_CONFIG_HOME="${tmp}/cfg" HELM_CACHE_HOME="${tmp}/cache" HELM_DATA_HOME="${tmp}/data" \
    HELM_REPOSITORY_CONFIG="${tmp}/cfg/repositories.yaml" HELM_REPOSITORY_CACHE="${tmp}/cache/repository" \
      timeout "${CC_EGRESS_TIMEOUT:-60}" helm repo add --force-update egress-probe "${url}" >"${tmp}/out" 2>&1 || rc=$?
    (( rc == 0 )) && break
    sleep "${CC_EGRESS_RETRY_DELAY:-5}"
  done
  (( rc == 0 )) || log_warn "    letzte helm-Meldung: $(tail -n 1 "${tmp}/out" | cut -c1-200)"
  rm -rf "${tmp}"
  return "${rc}"
}

check_helm_repo_egress() {
  if [[ "${CC_EGRESS_CHECK:-strict}" == "off" ]]; then
    log "Egress-Check übersprungen (CC_EGRESS_CHECK=off)"
    return 0
  fi

  local refs_file="${CC_V1_REPO_PATH:-}/core_platform/vars/software_references.yml"
  local rc=0 err_file urls

  # Konfigurationsprobleme (Datei fehlt, yq-Fehler, leere Liste) werden nach
  # CC_EGRESS_CHECK behandelt: strict -> harter Abbruch, warn -> nur Warnung.
  if [[ ! -f "${refs_file}" ]]; then
    if [[ "${CC_EGRESS_CHECK:-strict}" == "strict" ]]; then
      log_error "software_references.yml nicht gefunden: ${refs_file} — Egress-Check kann nicht laufen"
      exit 1
    fi
    log_warn "software_references.yml nicht gefunden: ${refs_file} — Egress-Check übersprungen"
    return 0
  fi

  # Filter: mikefarah-yq (tag == "!!map" statt jq-`objects`). stderr getrennt
  # erfassen, damit ein yq-Fehler nicht durch set -e pipefail verschluckt wird.
  err_file="$(mktemp)"
  urls="$(yq -r '.. | select(tag == "!!map") | select(has("helm_repo_url")) | .helm_repo_url' "${refs_file}" 2>"${err_file}")" || rc=$?
  if (( rc != 0 )); then
    if [[ "${CC_EGRESS_CHECK:-strict}" == "strict" ]]; then
      log_error "yq-Filter fehlgeschlagen (rc=${rc}): $(head -c 300 "${err_file}")"
      rm -f "${err_file}"
      exit 1
    fi
    log_warn "yq-Filter fehlgeschlagen (rc=${rc}): $(head -c 300 "${err_file}")"
    rm -f "${err_file}"
    return 0
  fi
  rm -f "${err_file}"

  # Normalisieren + deduplizieren; grep -v darf bei leerer Eingabe nicht abbrechen.
  urls="$(printf '%s\n' "${urls}" | sed 's#/$##' | { grep -v '^[[:space:]]*$' || true; } | sort -u)"
  if [[ -z "${urls}" ]]; then
    if [[ "${CC_EGRESS_CHECK:-strict}" == "strict" ]]; then
      log_error "Keine helm_repo_url in ${refs_file} gefunden (Schema-/Filterproblem) — Egress-Check kann nicht laufen"
      exit 1
    fi
    log_warn "Keine helm_repo_url in ${refs_file} gefunden — Egress-Check übersprungen"
    return 0
  fi

  if ! command -v helm >/dev/null 2>&1; then
    if [[ "${CC_EGRESS_CHECK:-strict}" == "strict" ]]; then
      log_error "helm nicht gefunden — Egress-Check kann nicht laufen"
      exit 1
    fi
    log_warn "helm nicht gefunden — Egress-Check übersprungen"
    return 0
  fi

  log "Egress-Check für Helm-Repos (CC_EGRESS_CHECK=${CC_EGRESS_CHECK:-strict}) …"
  local url failures=0 warnings=0
  while IFS= read -r url; do
    [[ -n "${url}" ]] || continue
    if _egress_probe_helm "${url}"; then
      log_ok "  ${url}"
    elif [[ "${CC_EGRESS_CHECK:-strict}" == "strict" ]]; then
      log_error "  ${url} — nicht erreichbar"
      failures=$((failures + 1))
    else
      log_warn "  ${url} — nicht erreichbar"
      warnings=$((warnings + 1))
    fi
  done <<< "${urls}"

  if [[ "${failures}" -gt 0 ]]; then
    log_error "${failures} Helm-Repo(s) nicht erreichbar — Egress-Problem."
    log_error "Remediation: IPv4 bevorzugen (NET_PREFER_IPV4=always) oder Netzwerk prüfen."
    log_error "Abbruch vor cc_cli validate/exec."
    exit 1
  fi
  if [[ "${warnings}" -gt 0 ]]; then
    log_warn "${warnings} Helm-Repo(s) nicht erreichbar (nur Warnung, CC_EGRESS_CHECK=warn)."
  else
    log_ok "Egress-Check: alle Helm-Repos erreichbar"
  fi
}


# ── Schritt 2.1: Overlay-Dateien einspielen ───────────────────────────────────
# Kopiert alle Dateien aus overlay_V1s/ in die entsprechende Zielstruktur
# unterhalb von CC_CLI_PLAYBOOK_DIR. Erzeugt vor dem Ueberschreiben ein
# Backup der Originaldatei (.overlay_backup/<relpath>.orig), falls noch
# keines existiert.
apply_overlay() {
  local overlay_src="${SCRIPT_DIR}/overlay_V1s"
  local overlay_dst="${CC_CLI_PLAYBOOK_DIR}"

  if [[ ! -d "${overlay_src}" ]]; then
    log_warn "Overlay-Verzeichnis nicht gefunden: ${overlay_src}"
    return 0
  fi

  log "Wende Overlays an (${overlay_src} -> ${overlay_dst}) …"

  local backup_dir="${overlay_dst}/.overlay_backup"
  local count=0
  local errors=0

  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#"${overlay_src}"/}"
    local dst_file="${overlay_dst}/${rel_path}"
    local dst_dir
    dst_dir="$(dirname "${dst_file}")"

    if [[ ! -d "${dst_dir}" ]]; then
      log_error "Zielverzeichnis existiert nicht: ${dst_dir} — Overlay ${rel_path} kann nicht angewendet werden"
      log_error "  (Strukturaenderung im Upstream-Repo? Ueberpruefe overlay_V1s/${rel_path})"
      (( errors++ )) || true
      continue
    fi

    mkdir -p "${backup_dir}/$(dirname "${rel_path}")"
    local backup_file="${backup_dir}/${rel_path}.orig"
    if [[ -f "${dst_file}" && ! -f "${backup_file}" ]]; then
      cp -a "${dst_file}" "${backup_file}"
    fi

    cp "${src_file}" "${dst_file}"
    (( count++ )) || true
    log_ok "  Overlay angewendet: ${rel_path}"

  done < <(find "${overlay_src}" -type f -print0)

  if [[ ${errors} -gt 0 ]]; then
    log_error "${errors} Overlay(s) konnten nicht angewendet werden — Abbruch"
    exit 1
  fi

  if [[ ${count} -eq 0 ]]; then
    log_ok "Keine Overlay-Dateien gefunden"
  else
    log_ok "${count} Overlay-Datei(en) erfolgreich angewendet"
  fi
}


# ── Schritt 2.1b: Masterportal-Release-Namen patchen (instance_name | lower) ─
# Helm-Release-Namen muessen RFC-1123-konform sein (nur Kleinbuchstaben).
# gd_instance.instance_name aus dem Inventory enthaelt Grossbuchstaben (z. B.
# "Standard"), was zu "Error: release name is invalid" fuehrt.
patch_masterportal_release_name() {
  local task_file="" f
  for f in "${CIVITAS_PATCH_TARGETS[@]}"; do
    [[ "${f}" == *masterportal.yml ]] && task_file="${CC_CLI_PLAYBOOK_DIR}/${f}"
  done
  if [[ -z "${task_file}" || ! -f "${task_file}" ]]; then
    log_error "Masterportal-Task-Datei nicht gefunden (erwartet in CIVITAS_PATCH_TARGETS): ${task_file:-<fehlt>} — Strukturänderung im Upstream-Repo (Tag v1.8.1)?"
    exit 1
  fi

  if grep -q 'gd_instance.instance_name }}-{{ software.stack_gd.masterportal.helm_release_name' "${task_file}" \
     && ! grep -q 'gd_instance.instance_name | lower' "${task_file}"; then
    sed -i 's/gd_instance\.instance_name }}-{{ software\.stack_gd\.masterportal\.helm_release_name/gd_instance.instance_name | lower }}-{{ software.stack_gd.masterportal.helm_release_name/' "${task_file}"
    log_ok "Masterportal helm_release_name gepatcht (instance_name | lower)"
  else
    log_ok "Masterportal-Task bereits gepatcht oder Muster nicht gefunden"
  fi
}


# ── Schritt 2.2: Inventory aus Template erzeugen ──────────────────────────────
# cc_cli erwartet die Datei als cc_cli_inventory.yml im CWD (kein --inventory-Flag).
# Die Datei enthält Secrets im Klartext; der EXIT-Trap im Entry-Point loescht sie.
render_inventory() {
  log "Erzeuge Inventory aus Template …"

  local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local tpl="${script_dir}/templates_V1s/inventory.yml.tpl"
  mkdir -p "${CC_CLI_PLAYBOOK_DIR}"
  local out="${CC_CLI_PLAYBOOK_DIR}/cc_cli_inventory.yml"

  if [[ ! -f "${tpl}" ]]; then
    log_error "Template nicht gefunden: ${tpl}"
    exit 1
  fi

  # Passwörter: ADMIN_PASS ist Pflicht (Prüfung in 01_config.sh).
  # Prüfe Komplexität: ≥12 Zeichen, Ziffer, Groß/Klein, Sonderzeichen
  if ! echo "${ADMIN_PASS}" | grep -qP '(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^a-zA-Z0-9]).{12,}'; then
    log_warn "ADMIN_PASS erfüllt nicht die Keycloak-Passwort-Policy"
    log_warn "Erforderlich: ≥12 Zeichen, min. 1 Ziffer, 1 Groß-, 1 Kleinbuchstabe, 1 Sonderzeichen"
  fi
  # Rohwerte halten (kein vorab-Escaping). Escaped wird erst beim sed-Einsetzen
  # ueber sed_escape_repl + yaml_dq_escape, damit die Credentials-Datei die
  # unverfaelschten Werte enthaelt. Die generierten Passwoerter werden nicht
  # zwischen Laeufen wiederverwendet (kein Persistieren ueber den Lauf hinaus).
  local pw_keycloak; pw_keycloak="${ADMIN_PASS}"
  local pw_pgadmin;            pw_pgadmin="$(gen_policy_password 24 || echo "CHANGEME_pgadmin")"
  local pw_apisix_admin_role;    pw_apisix_admin_role="$(gen_policy_password 24 || echo "CHANGEME_adminrole")"
  local pw_apisix_viewer_role;   pw_apisix_viewer_role="$(gen_policy_password 24 || echo "CHANGEME_viewerrole")"
  local pw_superset_db;        pw_superset_db="$(gen_policy_password 42 || echo "CHANGEME_superset_db")"
  local pw_superset_redis;     pw_superset_redis="$(gen_policy_password 24 || echo "CHANGEME_superset_redis")"
  local pw_superset_admin;     pw_superset_admin="$(gen_policy_password 24 || echo "CHANGEME_superset_admin")"
  local pw_grafana;            pw_grafana="$(gen_policy_password 24 || echo "CHANGEME_grafana")"
  local pw_geoserver;          pw_geoserver="$(gen_policy_password 16 || echo "CHANGEME_geoserver")"
  local pw_pivau;              pw_pivau="$(gen_policy_password 24 || echo "CHANGEME_pivau")"
  local tenant_admin_password
  if [[ -n "${TENANT_ADMIN_PASS:-}" ]]; then
    if ! echo "${TENANT_ADMIN_PASS}" | grep -qP '(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^a-zA-Z0-9]).{12,}'; then
      log_warn "TENANT_ADMIN_PASS erfüllt nicht die Keycloak-Passwort-Policy"
      log_warn "Erforderlich: ≥12 Zeichen, min. 1 Ziffer, 1 Groß-, 1 Kleinbuchstabe, 1 Sonderzeichen"
    fi
    tenant_admin_password="${TENANT_ADMIN_PASS}"
  else
    tenant_admin_password="$(gen_policy_password 24 || echo "CHANGEME_tenantadmin")"
  fi
  local pw_apisix_etcd_root;  pw_apisix_etcd_root="$(gen_policy_password 24 || echo "CHANGEME_etcdroot")"

  # sed-Trennzeichen '|' vermeidet Konflikte mit '/' in URLs und Pfaden.
  # Geordnete Paare <Platzhalter> <Rohwert>. Die Reihenfolge bleibt erhalten;
  # das Escaping passiert erst an der Ersetzungsstelle (sed_escape_repl, ggf.
  # zusaetzlich yaml_dq_escape fuer doppelt gequotete Platzhalter).
  local -a pairs=(
    PLACEHOLDER_DOMAIN                    "${DOMAIN}"
    PLACEHOLDER_ENVIRONMENT               "${CC_ENVIRONMENT:-cc-prd}"
    PLACEHOLDER_K8S_CONTEXT               "${K8S_CONTEXT:-default}"
    PLACEHOLDER_STORAGECLASS_RWO          "${STORAGECLASS_RWO:-local-path}"
    PLACEHOLDER_STORAGECLASS_RWX          "${STORAGECLASS_RWX:-local-path}"
    PLACEHOLDER_STORAGECLASS_LOC          "${STORAGECLASS_LOC:-local-path}"
    PLACEHOLDER_CERTMANAGER_ISSUER        "${CERT_MANAGER_ISSUER:-selfsigned-issuer}"
    PLACEHOLDER_APISIX_DASHBOARD          "${APISIX_DASHBOARD:-false}"
    PLACEHOLDER_INGRESSCLASS              "${INGRESS_CLASS:-nginx}"
    PLACEHOLDER_ADMINEMAIL                "${ADMIN_EMAIL}"
    PLACEHOLDER_SMTP_HOST                 "${SMTP_HOST}"
    PLACEHOLDER_SMTP_USER                 "${SMTP_USER}"
    PLACEHOLDER_SMTP_PASS                 "${SMTP_PASS}"
    PLACEHOLDER_SMTP_FROM                 "${SMTP_FROM:-no-reply@${DOMAIN_NAME}}"
    PLACEHOLDER_KEYCLOAK_ADMIN_PASSWORD   "${pw_keycloak}"
    PLACEHOLDER_TENANT_ADMIN_PASSWORD     "${tenant_admin_password}"
    PLACEHOLDER_APISIX_ETCD_ROOT_PASSWORD "${pw_apisix_etcd_root}"
    PLACEHOLDER_PGADMIN_PASSWORD          "${pw_pgadmin}"
    PLACEHOLDER_APISIX_ADMIN_ROLE_KEY     "${pw_apisix_admin_role}"
    PLACEHOLDER_APISIX_VIEWER_ROLE_KEY    "${pw_apisix_viewer_role}"
    PLACEHOLDER_SUPERSET_DB_SECRET        "${pw_superset_db}"
    PLACEHOLDER_SUPERSET_ADMIN_PASSWORD   "${pw_superset_admin}"
    PLACEHOLDER_SUPERSET_REDIS_PASSWORD   "${pw_superset_redis}"
    PLACEHOLDER_GRAFANA_PASSWORD          "${pw_grafana}"
    PLACEHOLDER_GEOSERVER_PASSWORD        "${pw_geoserver}"
    PLACEHOLDER_PIVAU_PASSWORD            "${pw_pivau}"
    PLACEHOLDER_V1S_IMAGE_REPOSITORY      "${V1S_IMAGE_REF%%:*}"
    PLACEHOLDER_V1S_IMAGE_TAG             "${V1S_IMAGE_REF##*:}"
    PLACEHOLDER_API_MAX_RETRIES           "${CC_API_MAX_RETRIES}"
    PLACEHOLDER_DEPLOYMENT_MAX_RETRIES    "${CC_DEPLOYMENT_MAX_RETRIES}"
    PLACEHOLDER_KUBECONFIG                "config"
  )

  # Blank (ungequotet) im Template gesetzte Platzhalter: deren Werte duerfen
  # keine YAML-/Shell-Sonderzeichen enthalten und werden nicht YAML-escaped.
  local -A plain=(
    [PLACEHOLDER_ENVIRONMENT]=1
    [PLACEHOLDER_KUBECONFIG]=1
    [PLACEHOLDER_APISIX_DASHBOARD]=1
    [PLACEHOLDER_API_MAX_RETRIES]=1
    [PLACEHOLDER_DEPLOYMENT_MAX_RETRIES]=1
  )

  local -a sed_args=() i token value
  for (( i = 0; i < ${#pairs[@]}; i += 2 )); do
    token="${pairs[i]}"
    value="${pairs[i+1]}"
    # Zeilenumbruch frueh ablehnen. NUL kann in Bash-Strings nicht vorkommen
    # (Env-Variablen und Command-Substitution strippen NUL), daher keine
    # separate Pruefung.
    if [[ "${value}" == *$'\n'* ]]; then
      log_error "Wert für ${token} enthält Zeilenumbruch — Abbruch"
      exit 1
    fi
    if [[ -n "${plain[${token}]:-}" ]]; then
      # Blank gesetzt: nur gegen YAML-/Shell-Risiken absichern, nicht escapen.
      if [[ "${value}" =~ [^A-Za-z0-9._:@/+-] ]]; then
        log_error "Wert für ${token} (blank im Template) enthält unzulässige Zeichen: '${value}' — Abbruch"
        exit 1
      fi
      sed_args+=( -e "s|${token}|$(sed_escape_repl "${value}")|g" )
    else
      # Doppelt gequotet: erst YAML-, dann sed-escapen.
      sed_args+=( -e "s|${token}|$(sed_escape_repl "$(yaml_dq_escape "${value}")")|g" )
    fi
  done

  ( umask 077; sed "${sed_args[@]}" "${tpl}" > "${out}" )

  # Sicherheits-Check: keine ungefüllten Platzhalter übrig (Kommentarzeilen ignorieren)
  if grep -v '^#' "${out}" | grep -q "PLACEHOLDER_"; then
    log_warn "Ungefüllte Platzhalter im Inventory – prüfen:"
    grep -v '^#' "${out}" | grep "PLACEHOLDER_" | sed 's/^/    /' >&2
  fi

  # Sicherheits-Check: hostname darf kein http:// enthalten (sonst 308-Redirect)
  if grep -q 'hostname:.*"http://' "${out}"; then
    log_error "Inventory enthaelt http:// statt https:// fuer hostname — Abbruch"
    log_error "  Betroffene Zeile: $(grep 'hostname:.*"http://' "${out}")"
    exit 1
  fi

  # YAML-Parse-Check (ohne Inhaltsausgabe). Nur mit mikefarah-yq (go-yq) zuverlaessig;
  # das Python-yq (3.x) versteht den yq-eval-Aufruf nicht.
  if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q 'mikefarah'; then
    if ! yq eval '.' "${out}" >/dev/null 2>&1; then
      log_error "Inventory ist kein gültiges YAML — Rendering prüfen"
      exit 1
    fi
    log_ok "Inventory YAML-Parse erfolgreich"
  else
    log_warn "mikefarah-yq nicht vorhanden — YAML-Parse des Inventory übersprungen"
  fi

  # Pfad exportieren (Entry-Point liest ihn für die Login-Zusammenfassung).
  # Es gibt keinen automatischen Löschmechanismus; siehe Warnung unten.
  CONFIG_YAML_PATH="${out}"
  export CONFIG_YAML_PATH
  log_ok "Inventory erzeugt: ${out}"
  log_warn "Inventory liegt mit Modus 600 in ${out}; nach erfolgreicher Installation manuell entfernen oder den Zugriff beschraenken"

  # ── Credentials-Datei schreiben ───────────────────────────────────────
  # Enthaelt die automatisch generierten Dienst-Passwoerter (chmod 600).
  # Darf NICHT im CC_CLI_PLAYBOOK_DIR liegen (getrennte Ablage von Inventory
  # und Credentials; das Inventory kann im Fehlerfall mit ins Log gezogen werden).
  mkdir -p "$(dirname "${CREDENTIALS_OUTPUT_PATH}")"
  ( umask 077
    {
      echo "# CIVITAS/CORE V1 — Dienst-Credentials"
      echo "# Erzeugt durch render_inventory() am $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# chmod 600 — nur root lesbar"
      printf 'PGADMIN_EMAIL=%q\n' "${ADMIN_EMAIL}"
      printf 'PGADMIN_PASSWORD=%q\n' "${pw_pgadmin}"
      printf 'GEOSERVER_USER=%q\n' "admin"
      printf 'GEOSERVER_PASSWORD=%q\n' "${pw_geoserver}"
      printf 'SUPERSET_USER=%q\n' "admin"
      printf 'SUPERSET_PASSWORD=%q\n' "${pw_superset_admin}"
      printf 'GRAFANA_PASSWORD=%q\n' "${pw_grafana}"
      printf 'APISIX_ADMIN_ROLE_KEY=%q\n' "${pw_apisix_admin_role}"
      printf 'APISIX_VIEWER_ROLE_KEY=%q\n' "${pw_apisix_viewer_role}"
      printf 'SUPERSET_DB_SECRET=%q\n' "${pw_superset_db}"
      printf 'SUPERSET_REDIS_PASSWORD=%q\n' "${pw_superset_redis}"
      printf 'PIVAU_PASSWORD=%q\n' "${pw_pivau}"
      printf 'TENANT_ADMIN_USER=%q\n' "tenantadmin@${DOMAIN}"
      printf 'TENANT_ADMIN_PASSWORD=%q\n' "${tenant_admin_password}"
      printf 'APISIX_ETCD_ROOT_PASSWORD=%q\n' "${pw_apisix_etcd_root}"
    } > "${CREDENTIALS_OUTPUT_PATH}"
  )
  chmod 600 "${CREDENTIALS_OUTPUT_PATH}"
  log_ok "Credentials gespeichert: ${CREDENTIALS_OUTPUT_PATH}"
}


# ── Schritt 2.3: cc_cli validate ──────────────────────────────────────────────
# cc_cli validate und cc_cli exec lesen ./cc_cli_inventory.yml aus dem CWD.
# CWD ist das Verzeichnis mit playbook.yml (CC_CLI_PLAYBOOK_DIR).
# KUBECONFIG wird als Umgebungsvariable übergeben.
run_cc_cli_validate() {
  log "Führe cc_cli validate aus (aus ${CC_CLI_PLAYBOOK_DIR}) …"
  (
    cd "${CC_CLI_PLAYBOOK_DIR}" \
      || { log_error "Kann nicht nach ${CC_CLI_PLAYBOOK_DIR} wechseln"; exit 1; }
    KUBECONFIG="${KUBECONFIG_PATH}" \
      "${CC_CLI_VENV_PATH}/bin/cc_cli" validate \
      || { log_error "cc_cli validate fehlgeschlagen (Exit ${?})"; exit 1; }
  )
  log_ok "cc_cli validate erfolgreich abgeschlossen"
}


# ── Klassifikation aus dem lokalen Ansible-Log (kein Loginhalt auf der Konsole) ─
# fatal_stats liefert "N M T" für das Versuchs-Log:
#   N = Anzahl nicht-ignorierter fatal:-Einträge
#   M = davon, die das 404-Muster (Festtext) enthalten
#   T = davon, die ein transientes Muster (ERE) enthalten
# Ein fatal:-Eintrag gilt als ignoriert, wenn er bis zum nächsten "fatal: ["
# die Markierung "...ignoring" enthält (Ansible ignore_errors).
fatal_stats() {
  local log_file="$1" notfound="$2" transient="$3"
  [[ -f "${log_file}" ]] || { echo "0 0 0"; return 0; }
  awk -v nf="${notfound}" -v tr="${transient}" '
    BEGIN { n = 0; m = 0; t = 0 }
    /fatal: \[/ {
      if (have && !ignored) {
        n++
        if (index(block, nf) > 0) m++
        if (tolower(block) ~ tr) t++
      }
      have = 1; ignored = 0; block = $0; next
    }
    {
      block = block "\n" $0
      if (/\.\.\.ignoring/) ignored = 1
    }
    END {
      if (have && !ignored) {
        n++
        if (index(block, nf) > 0) m++
        if (tolower(block) ~ tr) t++
      }
      print n, m, t
    }
  ' "${log_file}" 2>/dev/null || { echo "0 0 0"; return 0; }
}

# Prüft, ob der LETZTE nicht-ignorierte fatal:-Block im Ansible-Log Passwort-/Policy-
# Signale enthält (für die DIAGNOSE-Ausgabe). Exit 0 = ja, 1 = nein (oder kein Block).
last_fatal_has_policy_signal() {
  local log_file="$1" last_block
  [[ -f "${log_file}" ]] || return 1
  last_block="$(awk '
    /fatal: \[/ {
      if (have && !ignored) last = block
      have = 1; ignored = 0; block = $0; next
    }
    {
      block = block "\n" $0
      if (/\.\.\.ignoring/) ignored = 1
    }
    END {
      if (have && !ignored) last = block
      print last
    }
  ' "${log_file}" 2>/dev/null)"
  [[ -n "${last_block}" ]] || return 1
  grep -Eiq 'password|policy|credentials|invalid_user_credentials' <<< "${last_block}"
}

# ── Sichtbare Fehlerzusammenfassung aus dem Ansible-Log (Allowlist) ───────────
# Gibt hoechstens 12 Zeilen (je max. 300 Zeichen) ueber log_error aus: Task-Name,
# Host und aus dem letzten nicht-ignorierten fatal:-Block nur die Allowlist-Felder
# (msg, rc, attempts, namespace/pod/container, letzte stderr/stdout-Zeilen).
# Keine Rohausgabe, kein command, kein invocation-JSON, keine Env. Parse-Fehler
# brechen den Installer nicht ab (Fallback: erste Zeilen des Blocks, geschwaerzt).
ansible_failure_summary() {
  local log_file="$1"
  [[ -f "${log_file}" ]] || { log_warn "Ansible-Log nicht vorhanden: ${log_file}"; return 0; }

  local py
  if [[ -x "${CC_CLI_VENV_PATH}/bin/python3" ]]; then
    py="${CC_CLI_VENV_PATH}/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    py="$(command -v python3)"
  else
    log_warn "python3 nicht gefunden – überspringe Fehlerzusammenfassung"
    return 0
  fi

  local py_script
  IFS= read -r -d '' py_script <<'PY' || true
import json
import re
import sys

SECRET_RE = re.compile(
    r'(?i)(pass\w*|token|secret\w*|authorization|api[ _-]?key)(\s*[:=]\s*)([^\s,;}]+)'
)


def redact(value):
    if not isinstance(value, str):
        return value
    return SECRET_RE.sub(r'\1\2****', value)


def emit(raw):
    line = redact(raw)
    if len(line) > 300:
        line = line[:297] + '...'
    return line


def oneline(value):
    if value is None:
        return None
    if isinstance(value, (dict, list)):
        value = json.dumps(value)
    return str(value).replace('\r', ' ').replace('\n', ' ')


FATAL_RE = re.compile(r'fatal: \[([^\]]+)\]: FAILED! => (.*)$')


def main():
    path = sys.argv[1]
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as fh:
            lines = fh.read().splitlines()
    except OSError:
        return

    blocks = []
    i = 0
    n = len(lines)
    while i < n:
        m = FATAL_RE.search(lines[i])
        if not m:
            i += 1
            continue
        host = m.group(1)
        task = None
        for j in range(i - 1, max(i - 40, -1), -1):
            tm = re.search(r'TASK \[([^\]]*)\]', lines[j])
            if tm:
                task = tm.group(1).strip()
                break
        json_lines = [m.group(2)]
        j = i + 1
        block_end = i
        parsed = None
        try:
            parsed = json.loads(m.group(2))
        except Exception:
            parsed = None
        while parsed is None and j < n:
            json_lines.append(lines[j])
            block_end = j
            try:
                parsed = json.loads('\n'.join(json_lines))
            except Exception:
                parsed = None
            j += 1
        ignored = False
        k = block_end + 1
        while k < n and not FATAL_RE.search(lines[k]):
            if '...ignoring' in lines[k]:
                ignored = True
                break
            k += 1
        blocks.append({
            'host': host,
            'task': task,
            'json': '\n'.join(json_lines),
            'raw': json_lines,
            'ignored': ignored,
        })
        i = block_end + 1

    target = None
    for b in blocks:
        if not b['ignored']:
            target = b
    if target is None:
        return

    data = None
    try:
        data = json.loads(target['json'])
    except Exception:
        data = None

    out = []
    if data is None:
        for ln in target['raw'][:3]:
            s = ln.strip()
            if s and s not in ('{', '}'):
                out.append(s)
    else:
        if target['task']:
            out.append('Task: ' + target['task'])
        out.append('Host: ' + target['host'])
        if data.get('msg') is not None:
            out.append('msg: ' + oneline(data.get('msg')))
        if data.get('rc') is not None:
            out.append('rc: ' + oneline(data.get('rc')))
        if data.get('attempts') is not None:
            out.append('attempts: ' + oneline(data.get('attempts')))
        ma = data.get('invocation', {}).get('module_args', {})
        if isinstance(ma, dict):
            for key in ('namespace', 'pod', 'container'):
                if ma.get(key):
                    out.append(key + ': ' + oneline(ma.get(key)))
        for key in ('module_stderr', 'stderr', 'module_stdout', 'stdout'):
            v = data.get(key)
            if isinstance(v, str):
                sub = [ln for ln in v.splitlines() if ln.strip()]
                for ln in sub[-4:]:
                    out.append(key + ': ' + ln.strip())

    printed = []
    for raw in out:
        if raw is None:
            continue
        printed.append(emit(raw))
        if len(printed) >= 12:
            break
    if printed:
        sys.stdout.write('\n'.join(printed) + '\n')


main()
PY
  printf '%s' "${py_script}" | "${py}" - "${log_file}" 2>/dev/null | while IFS= read -r line; do
    [[ -n "${line}" ]] && log_error "  ${line}"
  done || true
}

log_ansible_log_metadata() {
  local log_file="$1" lines
  [[ -f "${log_file}" ]] || { log_warn "Ansible-Log nicht vorhanden: ${log_file}"; return 0; }
  lines="$(wc -l < "${log_file}" | tr -d '[:space:]')"
  log "Ansible-Log lokal vorhanden: ${log_file} (${lines} Zeilen)"
}

# Letzte nicht-leere Zeile eines Logs, geschwaerzt und auf 300 Zeichen gekuerzt.
_local_cause_line() {
  local file="$1" line
  [[ -f "${file}" ]] || return 0
  line="$(grep -Ev '^[[:space:]]*$' "${file}" 2>/dev/null | tail -1 || true)"
  [[ -n "${line}" ]] || return 0
  line="$(printf '%s' "${line}" | sed -E 's#(pass[[:alnum:]_]*|token|secret[[:alnum:]_]*|authorization|api[ _-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:],;}]+#\1=****#gI')"
  printf '%s' "${line}" | cut -c1-300
}

# ── Schritt 2.4: cc_cli exec ─────────────────────────────────────────────────
# Timeout schützt vor unbegrenzt hängenden Deployments.
run_cc_cli_exec() {
  log "Fuehre cc_cli exec aus (Timeout: ${TIMEOUT_CC_CLI_EXEC}s) …"

  # Ansible-Logging aktivieren (pro Versuch ein eigenes Log, hohe Verbosity).
  local ansible_log_dir="${CC_CLI_PLAYBOOK_DIR}/logs"
  local latest_log="${ansible_log_dir}/ansible_run_latest.log"
  mkdir -p "${ansible_log_dir}"
  chmod 700 "${ansible_log_dir}"
  # ANSIBLE_DEBUG NICHT setzen — fuehrt zu "'debug' is not a valid AnsibleEventType"
  export ANSIBLE_VERBOSITY=3

  local attempt=1
  local tolerated_404=false
  local transient_re='status code was 5[0-9][0-9]|temporarily unavailable|connection (refused|reset by peer)|timed out|max retries exceeded|i/o timeout|tls handshake timeout|unexpected eof'
  local notfound_fixed='Status code was 404 and not [204]'
  while :; do
    # Pro Versuch ein eigenes Log; die Klassifikation liest nur dieses.
    local ansible_log_file="${ansible_log_dir}/ansible_attempt_${attempt}.log"
    rm -f "${ansible_log_file}"
    export ANSIBLE_LOG_PATH="${ansible_log_file}"
    ln -sfn "ansible_attempt_${attempt}.log" "${latest_log}"
    log "  Versuch ${attempt}/${CC_EXEC_ATTEMPTS}: Ansible-Log ${ansible_log_file}"

    local raw_file="${ansible_log_dir}/cc_cli_raw_${attempt}.txt"
    rm -f "${raw_file}"

    local rc=0
    # cc_cli im Hintergrund; der volle Output geht ausschließlich in die
    # Rohdatei (0600, eindeutiger Name pro Versuch), nie auf die Konsole.
    ( cd "${CC_CLI_PLAYBOOK_DIR}" || exit 125
      umask 077
      exec > "${raw_file}" 2>&1
      echo "Y" | timeout "${TIMEOUT_CC_CLI_EXEC}" \
        "${CC_CLI_VENV_PATH}/bin/cc_cli" exec
    ) &
    local cc_pid=$!

    # Sicherer Live-Fortschritt (Heartbeat): kein Rohoutput, keine Secrets.
    # Das cc_cli-Statusformat ist nicht belastbar belegbar, daher kein Parsen
    # des Rohoutputs (Ansible-Ausgabe bei Verbosity 3 enthält Inventory-Objekte).
    local heartbeat_interval="${CC_EXEC_HEARTBEAT_INTERVAL:-30}"
    ( local hb_start hb_now hb_lines=0
      hb_start=$(date +%s)
      while kill -0 "${cc_pid}" 2>/dev/null; do
        sleep "${heartbeat_interval}"
        if kill -0 "${cc_pid}" 2>/dev/null; then
          hb_now=$(date +%s)
          hb_lines=0
          [[ -f "${ansible_log_file}" ]] && hb_lines=$(wc -l < "${ansible_log_file}" 2>/dev/null || true)
          log "cc_cli läuft: Versuch ${attempt}/${CC_EXEC_ATTEMPTS}, $(( hb_now - hb_start )) s, Ansible-Log ${hb_lines} Zeilen"
        fi
      done
    ) &
    local heartbeat_pid=$!

    wait "${cc_pid}" && rc=0 || rc=$?
    kill "${heartbeat_pid}" 2>/dev/null || true
    wait "${heartbeat_pid}" 2>/dev/null || true

    [[ -f "${ansible_log_file}" ]] && chmod 600 "${ansible_log_file}"
    log "cc_cli exec beendet (rc=${rc}, Versuch ${attempt}/${CC_EXEC_ATTEMPTS})"
    log_ansible_log_metadata "${ansible_log_file}"
    # Fail-closed: Erfolg nur bei rc==0 und ohne "failed with status: failed".
    local failed=false transient=false
    if (( rc != 0 )); then
      failed=true
    fi
    if grep -qF "failed with status: failed" "${raw_file}"; then
      failed=true
    fi
    if [[ "${failed}" != "true" ]]; then
      rm -f "${raw_file}"
      break
    fi

    # Nicht-ignorierte fatal:-Einträge des aktuellen Versuchs auswerten.
    local -i fatal_count=0 fatal_404=0 fatal_transient=0
    local stats
    stats="$(fatal_stats "${ansible_log_file}" "${notfound_fixed}" "${transient_re}")"
    read -r fatal_count fatal_404 fatal_transient <<< "${stats}" || true

    if (( rc == 124 )); then
      transient=true
    elif (( fatal_count > 0 && fatal_404 == fatal_count )); then
      log_warn "cc_cli exec: Playbook meldet 404 statt 204 beim Loeschen einer Keycloak-Ressource, toleriert (Idempotenz-Fall)."
      tolerated_404=true
      rm -f "${raw_file}"
      break
    elif (( fatal_count > 0 )); then
      # transient nur, wenn ALLE nicht-ignorierten fatal:-Bloecke transient sind.
      # (Die Rohdatei wird bei vorhandenen Fatals nicht ausgewertet — sonst würde
      # ein früheres "RETRYING ... Connection refused" fälschlich als transient gelten.)
      (( fatal_transient == fatal_count )) && transient=true
    else
      # kein auswertbarer fatal-Block (Absturz vor/außerhalb des Playbooks):
      # nur das Ende der Rohdatei prüfen.
      tail -n 200 "${raw_file}" | grep -Eiq "${transient_re}" && transient=true
    fi

    if [[ "${transient}" == "true" && ${attempt} -lt ${CC_EXEC_ATTEMPTS} ]]; then
      local cause
      cause="$(_local_cause_line "${raw_file}")"
      log_warn "cc_cli exec: vorübergehender Fehler (Versuch ${attempt}/${CC_EXEC_ATTEMPTS}, rc=${rc}) — wiederhole in ${CC_EXEC_RETRY_DELAY}s mit demselben Inventory"
      [[ -n "${cause}" ]] && log_warn "  Ursache: ${cause}"
      sleep "${CC_EXEC_RETRY_DELAY}"
      attempt=$((attempt + 1))
      rm -f "${raw_file}"
      continue
    fi
    ansible_failure_summary "${ansible_log_file}"
    log_error "cc_cli exec: Playbook fehlgeschlagen — Logs pruefen:"
    log_error "  ${ansible_log_file}"
    log_error ""
    log_error "DIAGNOSE: Pruefe Passwort-Integritaet im gerenderten Inventory ..."
    local inventory_intakt=true
    if [[ -n "${CONFIG_YAML_PATH:-}" && -f "${CONFIG_YAML_PATH}" && -n "${CREDENTIALS_OUTPUT_PATH:-}" && -f "${CREDENTIALS_OUTPUT_PATH}" ]]; then
      local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
      local tpl="${script_dir}/templates_V1s/inventory.yml.tpl"
      local -A pw_tokens=(
        [PGADMIN_PASSWORD]=PLACEHOLDER_PGADMIN_PASSWORD
        [GEOSERVER_PASSWORD]=PLACEHOLDER_GEOSERVER_PASSWORD
        [SUPERSET_PASSWORD]=PLACEHOLDER_SUPERSET_ADMIN_PASSWORD
        [SUPERSET_DB_SECRET]=PLACEHOLDER_SUPERSET_DB_SECRET
        [SUPERSET_REDIS_PASSWORD]=PLACEHOLDER_SUPERSET_REDIS_PASSWORD
        [GRAFANA_PASSWORD]=PLACEHOLDER_GRAFANA_PASSWORD
        [APISIX_ADMIN_ROLE_KEY]=PLACEHOLDER_APISIX_ADMIN_ROLE_KEY
        [APISIX_VIEWER_ROLE_KEY]=PLACEHOLDER_APISIX_VIEWER_ROLE_KEY
        [PIVAU_PASSWORD]=PLACEHOLDER_PIVAU_PASSWORD
        [TENANT_ADMIN_PASSWORD]=PLACEHOLDER_TENANT_ADMIN_PASSWORD
        [APISIX_ETCD_ROOT_PASSWORD]=PLACEHOLDER_APISIX_ETCD_ROOT_PASSWORD
      )
      for pw_name in "${!pw_tokens[@]}"; do
        local token="${pw_tokens[${pw_name}]}"
        grep -q "${token}" "${tpl}" 2>/dev/null || continue
        local pw_value
        # Rohwert per source in Subshell lesen (credentials.env ist %q-gequotet,
        # source rekonstruiert den exakten Wert). Kein Grep-Lookbehind auf
        # Sonderzeichen mehr (Werte mit fuehrendem '-' wurden als Option gelesen).
        # shellcheck disable=SC1090
        pw_value="$( source "${CREDENTIALS_OUTPUT_PATH}" 2>/dev/null && printf '%s\n' "${!pw_name:-}" )"
        if [[ -n "${pw_value}" ]]; then
          # Im Inventory steht der YAML-escapte Wert (doppelt gequotet).
          if ! grep -qF -- "$(yaml_dq_escape "${pw_value}")" "${CONFIG_YAML_PATH}" 2>/dev/null; then
            log_error "  ✗ ${pw_name}: NICHT im Inventory gefunden -> Rendering-Fehler (sed)"
            inventory_intakt=false
          fi
        fi
      done
    else
      log_error "  Inventory (${CONFIG_YAML_PATH:-unset}) oder Credentials (${CREDENTIALS_OUTPUT_PATH:-unset}) nicht lesbar"
      inventory_intakt=false
    fi
    if [[ "${inventory_intakt}" == "true" ]]; then
      log_error "DIAGNOSE: Alle Passwoerter korrekt im Inventory vorhanden."
      if last_fatal_has_policy_signal "${ansible_log_file}"; then
        log_error "Fehlerursache liegt vermutlich bei der Ziel-Policy des Dienstes"
        log_error "(z.B. Keycloak password_policy), NICHT beim Passwort-Rendering."
      else
        log_error "Ursache im letzten Fehlerblock pruefen (Netzwerk, Helm-Repo, Chart-Version)."
      fi
      log_error "Ansible-Log zur Analyse: ${ansible_log_file}"
    else
      log_error "DIAGNOSE: Mindestens ein Passwort wurde beim sed-Rendering"
      log_error "veraendert oder ist verschwunden. Charset/sed-Trennzeichen pruefen."
    fi
    log_warn ""
    log_warn "Ein erneuter Skriptlauf erzeugt neue Dienst-Passwoerter; auf einem teilweise installierten Cluster passen sie dann nicht mehr zum vorhandenen Zustand."
    log_warn "Entweder die VM neu aufsetzen oder in der VM im Playbook-Verzeichnis mit dem vorhandenen Inventory erneut starten:"
    log_warn "  cd ${CC_CLI_PLAYBOOK_DIR} && echo Y | KUBECONFIG=${KUBECONFIG_PATH} ${CC_CLI_VENV_PATH}/bin/cc_cli exec"
    log_warn ""
    rm -f "${raw_file}"
    exit 1
  done
  if [[ "${tolerated_404}" == "true" ]]; then
    log_ok "cc_cli exec mit toleriertem 404-Idempotenzfall abgeschlossen"
  else
    log_ok "cc_cli exec erfolgreich abgeschlossen"
  fi

  # Logfile-Pruefung
  if [[ -f "${ansible_log_file}" ]]; then
    log_ok "Ansible-Log gefunden: ${ansible_log_file}"
  else
    log_warn "Ansible-Log NICHT gefunden: ${ansible_log_file}"
  fi
}

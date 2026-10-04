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
  build_geoportal_backend_image   # Schritt 2.0b: V1s — Portal-Backend-Image bauen und in containerd importieren
  apply_overlay
  patch_masterportal_release_name
  install_cc_cli
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

  apply_target_state "${resolved_state}"
  local apply_rc=$?
  if ! ensure_keycloak_admin_user; then
    log_error "CIVITAS/CORE-Cluster ist deployt, aber die Keycloak-Admin-Provisionierung ist unvollständig (betroffene Punkte siehe oben)."
    exit 1
  fi

  if [[ ${apply_rc} -ne 0 ]]; then
    log_error "apply_target_state fehlgeschlagen (Zielzustand: ${resolved_state})"
    exit 1
  fi
  if ! verify_certificates "${resolved_state}"; then
    log_error "verify_certificates: mindestens ein Host ohne gueltigen Nachweis"
    exit 1
  fi

  # LE-Backup schreiben, wenn Produktivzertifikate frisch ausgestellt wurden.
  if [[ "${LE_FRESH_PROD_ISSUED:-false}" == "true" ]]; then
    write_le_backup || log_warn "LE-Backup konnte nicht geschrieben werden"
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
  if [[ -f "${CC_CLI_VENV_PATH}/bin/cc_cli" ]]; then
    local installed_ver
    installed_ver="$(
      "${CC_CLI_VENV_PATH}/bin/pip" show cc-cli 2>/dev/null \
        | grep -oP '(?<=Version: )\S+' \
        || true
    )"
    if [[ "${installed_ver}" == "${CC_CLI_VERSION}" ]]; then
      log_ok "cc_cli ${CC_CLI_VERSION} bereits installiert – überspringe"
      return 0
    else
      log_warn "cc_cli ${installed_ver:-unbekannt} gefunden, erwartet ${CC_CLI_VERSION} – reinstalliere"
      rm -rf "${CC_CLI_VENV_PATH}"
    fi
  fi

  apt-get install -y python3-venv --quiet
  python3 -m venv "${CC_CLI_VENV_PATH}"
  "${CC_CLI_VENV_PATH}/bin/pip" install \
    --quiet \
    --extra-index-url "${CC_CLI_REGISTRY_URL}" \
    "cc-cli==${CC_CLI_VERSION}"
  log "Installiere ansible ${ANSIBLE_VERSION} ins venv ..."
  "${CC_CLI_VENV_PATH}/bin/pip" install --quiet "ansible==${ANSIBLE_VERSION}"
  log_ok "ansible installiert: $("${CC_CLI_VENV_PATH}/bin/ansible" --version | head -1)"

  log "Installiere kubernetes-Python-Bibliothek ins venv ..."
  "${CC_CLI_VENV_PATH}/bin/pip" install --quiet kubernetes
  log_ok "kubernetes-Bibliothek installiert"

  log "Setze Symlinks fuer ansible-playbook und ansible nach /usr/local/bin ..."
  ln -sf "${CC_CLI_VENV_PATH}/bin/ansible-playbook" /usr/local/bin/ansible-playbook
  ln -sf "${CC_CLI_VENV_PATH}/bin/ansible"          /usr/local/bin/ansible
  log_ok "ansible-playbook im System-PATH: $(ansible-playbook --version | head -1)"
  log_ok "cc_cli ${CC_CLI_VERSION} installiert"
}


# ── Schritt 2.0: Repository klonen ────────────────────────────────────────────
clone_civitas_repo() {
  log "Klone CIVITAS/CORE-Repository nach ${CC_V1_REPO_PATH} …"

  if [[ -d "${CC_V1_REPO_PATH}/.git" ]]; then
    log "Repository bereits vorhanden — führe git pull aus …"
    git -C "${CC_V1_REPO_PATH}" pull --ff-only origin "${CC_V1_REPO_BRANCH}" \
      || log_warn "git pull fehlgeschlagen — fahre mit vorhandenem Stand fort"
  else
    git clone \
      --branch "${CC_V1_REPO_BRANCH}" \
      --single-branch \
      "${CC_V1_REPO_URL}" \
      "${CC_V1_REPO_PATH}" \
      || { log_error "git clone fehlgeschlagen: ${CC_V1_REPO_URL}"; return 1; }
  fi

  # Symlink /opt/civitas-core → /opt/civitas-core-v1
  if [[ "$(readlink /opt/civitas-core 2>/dev/null)" != "${CC_V1_REPO_PATH}" ]]; then
    ln -sfn "${CC_V1_REPO_PATH}" /opt/civitas-core
    log "Symlink gesetzt: /opt/civitas-core → ${CC_V1_REPO_PATH}"
  else
    log "Symlink bereits korrekt: /opt/civitas-core → ${CC_V1_REPO_PATH}"
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

  [[ "$(readlink /opt/civitas-core)" == "${CC_V1_REPO_PATH}" ]] \
    || { log_error "Symlink /opt/civitas-core zeigt nicht auf ${CC_V1_REPO_PATH}"; return 1; }

  log_ok "Repository bereit: ${CC_V1_REPO_PATH}"
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
  local task_file="${CC_CLI_PLAYBOOK_DIR}/tasks/geodata/install/components/masterportal.yml"

  if [[ ! -f "${task_file}" ]]; then
    log_warn "Masterportal-Task-Datei nicht gefunden: ${task_file}"
    return 0
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
  # Alle anderen werden frisch generiert – kein Wiederverwenden zwischen Läufen,
  # da das Inventory nach cc_cli exec gelöscht wird.
  local pw_keycloak; pw_keycloak="$(echo "${ADMIN_PASS}" | sed 's/[&|\\$]/\\&/g')"
  local pw_pgadmin;            pw_pgadmin="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_pgadmin")"
  local pw_apisix_admin_role;    pw_apisix_admin_role="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_adminrole")"
  local pw_apisix_viewer_role;   pw_apisix_viewer_role="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_viewerrole")"
  local pw_apisix_dashboard_jwt; pw_apisix_dashboard_jwt="$(openssl rand -base64 12 | tr -d '\n' | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_jwt")"
  local pw_apisix_dashboard_pass;pw_apisix_dashboard_pass="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_dashpass")"
  local pw_superset_db;        pw_superset_db="$(gen_policy_password 42 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_superset_db")"
  local pw_superset_redis;     pw_superset_redis="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_superset_redis")"
  local pw_superset_admin;     pw_superset_admin="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_superset_admin")"
  local pw_grafana;            pw_grafana="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_grafana")"
  local pw_geoserver;          pw_geoserver="$(gen_policy_password 16 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_geoserver")"
  local pw_pivau;              pw_pivau="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_pivau")"
  local tenant_admin_password
  if [[ -n "${TENANT_ADMIN_PASS:-}" ]]; then
    if ! echo "${TENANT_ADMIN_PASS}" | grep -qP '(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[^a-zA-Z0-9]).{12,}'; then
      log_warn "TENANT_ADMIN_PASS erfüllt nicht die Keycloak-Passwort-Policy"
      log_warn "Erforderlich: ≥12 Zeichen, min. 1 Ziffer, 1 Groß-, 1 Kleinbuchstabe, 1 Sonderzeichen"
    fi
    tenant_admin_password="$(echo "${TENANT_ADMIN_PASS}" | sed 's/[&|\\$]/\\&/g')"
  else
    tenant_admin_password="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_tenantadmin")"
  fi
  local pw_apisix_etcd_root;  pw_apisix_etcd_root="$(gen_policy_password 24 | sed 's/[&|\\$]/\\&/g' || echo "CHANGEME_etcdroot")"

  # sed-Trennzeichen '|' vermeidet Konflikte mit '/' in URLs und Pfaden.
  # Reihenfolge: spezifischere Token vor generischeren (kein Überschreiben).
  sed \
    -e "s|PLACEHOLDER_DOMAIN|${DOMAIN}|g" \
    -e "s|PLACEHOLDER_ENVIRONMENT|${CC_ENVIRONMENT:-cc-prd}|g" \
    -e "s|PLACEHOLDER_K8S_CONTEXT|${K8S_CONTEXT:-default}|g" \
    -e "s|PLACEHOLDER_STORAGECLASS_RWO|${STORAGECLASS_RWO:-local-path}|g" \
    -e "s|PLACEHOLDER_STORAGECLASS_RWX|${STORAGECLASS_RWX:-local-path}|g" \
    -e "s|PLACEHOLDER_STORAGECLASS_LOC|${STORAGECLASS_LOC:-local-path}|g" \
    -e "s|PLACEHOLDER_CERTMANAGER_ISSUER|${CERT_MANAGER_ISSUER:-selfsigned-issuer}|g" \
    -e "s|PLACEHOLDER_APISIX_JWT_SECRET|${pw_apisix_dashboard_jwt}|g" \
    -e "s|PLACEHOLDER_APISIX_DASHBOARD_USER|admin@${DOMAIN}|g" \
    -e "s|PLACEHOLDER_APISIX_DASHBOARD_PASS|${pw_apisix_dashboard_pass}|g" \
    -e "s|PLACEHOLDER_APISIX_DASHBOARD|${APISIX_DASHBOARD:-false}|g" \
    -e "s|PLACEHOLDER_INGRESSCLASS|${INGRESS_CLASS:-nginx}|g" \
    -e "s|PLACEHOLDER_ADMINEMAIL|${ADMIN_EMAIL}|g" \
    -e "s|PLACEHOLDER_SMTP_HOST|${SMTP_HOST}|g" \
    -e "s|PLACEHOLDER_SMTP_USER|${SMTP_USER}|g" \
    -e "s|PLACEHOLDER_SMTP_PASS|${SMTP_PASS}|g" \
    -e "s|PLACEHOLDER_SMTP_FROM|${SMTP_FROM:-no-reply@${DOMAIN_NAME}}|g" \
    -e "s|PLACEHOLDER_KEYCLOAK_ADMIN_PASSWORD|${pw_keycloak}|g" \
    -e "s|PLACEHOLDER_TENANT_ADMIN_PASSWORD|${tenant_admin_password}|g" \
    -e "s|PLACEHOLDER_APISIX_ETCD_ROOT_PASSWORD|${pw_apisix_etcd_root}|g" \
    -e "s|PLACEHOLDER_PGADMIN_PASSWORD|${pw_pgadmin}|g" \
    -e "s|PLACEHOLDER_APISIX_ADMIN_ROLE_KEY|${pw_apisix_admin_role}|g" \
    -e "s|PLACEHOLDER_APISIX_VIEWER_ROLE_KEY|${pw_apisix_viewer_role}|g" \
    -e "s|PLACEHOLDER_SUPERSET_DB_SECRET|${pw_superset_db}|g" \
    -e "s|PLACEHOLDER_SUPERSET_ADMIN_PASSWORD|${pw_superset_admin}|g" \
    -e "s|PLACEHOLDER_SUPERSET_REDIS_PASSWORD|${pw_superset_redis}|g" \
    -e "s|PLACEHOLDER_GRAFANA_PASSWORD|${pw_grafana}|g" \
    -e "s|PLACEHOLDER_GEOSERVER_PASSWORD|${pw_geoserver}|g" \
    -e "s|PLACEHOLDER_PIVAU_PASSWORD|${pw_pivau}|g" \
    -e "s|PLACEHOLDER_V1S_IMAGE_REPOSITORY|${V1S_IMAGE_REF%%:*}|g" \
    -e "s|PLACEHOLDER_V1S_IMAGE_TAG|${V1S_IMAGE_REF##*:}|g" \
    -e "s|PLACEHOLDER_API_MAX_RETRIES|${CC_API_MAX_RETRIES}|g" \
    -e "s|PLACEHOLDER_DEPLOYMENT_MAX_RETRIES|${CC_DEPLOYMENT_MAX_RETRIES}|g" \
    -e "s|PLACEHOLDER_KUBECONFIG|config|g" \
    "${tpl}" > "${out}"

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

  # Pfad exportieren damit Entry-Point EXIT-Trap löschen kann
  CONFIG_YAML_PATH="${out}"
  export CONFIG_YAML_PATH
  log_ok "Inventory erzeugt: ${out}"
  log_warn "Inventory enthält Secrets im Klartext – wird nach cc_cli exec gelöscht"

  # ── Credentials-Datei schreiben ───────────────────────────────────────
  # Enthaelt die automatisch generierten Dienst-Passwoerter (chmod 600).
  # Darf NICHT im CC_CLI_PLAYBOOK_DIR liegen (wird dort bereinigt).
  mkdir -p "$(dirname "${CREDENTIALS_OUTPUT_PATH}")"
  cat > "${CREDENTIALS_OUTPUT_PATH}" << CREDENTIALS_EOF
# CIVITAS/CORE V1 — Dienst-Credentials
# Erzeugt durch render_inventory() am $(date '+%Y-%m-%d %H:%M:%S')
# chmod 600 — nur root lesbar
PGADMIN_EMAIL="${ADMIN_EMAIL}"
PGADMIN_PASSWORD="${pw_pgadmin}"
GEOSERVER_USER="admin"
GEOSERVER_PASSWORD="${pw_geoserver}"
SUPERSET_USER="admin"
SUPERSET_PASSWORD="${pw_superset_admin}"
GRAFANA_PASSWORD="${pw_grafana}"
APISIX_DASHBOARD_USER="admin@${DOMAIN}"
APISIX_DASHBOARD_PASSWORD="${pw_apisix_dashboard_pass}"
APISIX_ADMIN_ROLE_KEY="${pw_apisix_admin_role}"
APISIX_VIEWER_ROLE_KEY="${pw_apisix_viewer_role}"
SUPERSET_DB_SECRET="${pw_superset_db}"
SUPERSET_REDIS_PASSWORD="${pw_superset_redis}"
PIVAU_PASSWORD="${pw_pivau}"
TENANT_ADMIN_USER="tenantadmin@${DOMAIN}"
TENANT_ADMIN_PASSWORD="${tenant_admin_password}"
APISIX_ETCD_ROOT_PASSWORD="${pw_apisix_etcd_root}"
CREDENTIALS_EOF
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
        if (block ~ tr) t++
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
        if (block ~ tr) t++
      }
      print n, m, t
    }
  ' "${log_file}" 2>/dev/null || { echo "0 0 0"; return 0; }
}

log_ansible_log_metadata() {
  local log_file="$1" lines
  [[ -f "${log_file}" ]] || { log_warn "Ansible-Log nicht vorhanden: ${log_file}"; return 0; }
  lines="$(wc -l < "${log_file}" | tr -d '[:space:]')"
  log "Ansible-Log lokal vorhanden: ${log_file} (${lines} Zeilen)"
}

# ── Schritt 2.4: cc_cli exec ──────────────────────────────────────────────────
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
  local transient_re='Status code was 5[0-9][0-9]|Temporarily Unavailable|Connection refused|timed out|Max retries exceeded'
  local notfound_fixed='Status code was 404 and not [204]'
  while :; do
    # Pro Versuch ein eigenes Log; die Klassifikation liest nur dieses.
    local ansible_log_file="${ansible_log_dir}/ansible_attempt_${attempt}.log"
    rm -f "${ansible_log_file}"
    export ANSIBLE_LOG_PATH="${ansible_log_file}"
    ln -sfn "ansible_attempt_${attempt}.log" "${latest_log}"
    log "  Versuch ${attempt}/${CC_EXEC_ATTEMPTS}: Ansible-Log ${ansible_log_file}"

    local output rc=0
    output=$(cd "${CC_CLI_PLAYBOOK_DIR}" && \
      umask 077 && \
      echo "Y" | timeout "${TIMEOUT_CC_CLI_EXEC}" \
      "${CC_CLI_VENV_PATH}/bin/cc_cli" exec 2>&1) || rc=$?
    [[ -f "${ansible_log_file}" ]] && chmod 600 "${ansible_log_file}"
    log "cc_cli exec beendet (rc=${rc}, Versuch ${attempt}/${CC_EXEC_ATTEMPTS})"
    log_ansible_log_metadata "${ansible_log_file}"
    # Fail-closed: Erfolg nur bei rc==0 und ohne "failed with status: failed".
    local failed=false transient=false
    if (( rc != 0 )); then
      failed=true
    fi
    if echo "${output}" | grep -qF "failed with status: failed"; then
      failed=true
    fi
    if [[ "${failed}" != "true" ]]; then
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
      break
    elif echo "${output}" | grep -Eq "${transient_re}" || (( fatal_transient > 0 )); then
      transient=true
    fi

    if [[ "${transient}" == "true" && ${attempt} -lt ${CC_EXEC_ATTEMPTS} ]]; then
      log_warn "cc_cli exec: vorübergehender Fehler (Versuch ${attempt}/${CC_EXEC_ATTEMPTS}, rc=${rc}) — wiederhole in ${CC_EXEC_RETRY_DELAY}s mit demselben Inventory"
      sleep "${CC_EXEC_RETRY_DELAY}"
      attempt=$((attempt + 1))
      continue
    fi
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
        [APISIX_DASHBOARD_PASSWORD]=PLACEHOLDER_APISIX_DASHBOARD_PASS
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
        pw_value="$(grep -oP "(?<=^${pw_name}=).*" "${CREDENTIALS_OUTPUT_PATH}" 2>/dev/null || true)"
        if [[ -n "${pw_value}" ]]; then
          if ! grep -qF "${pw_value}" "${CONFIG_YAML_PATH}" 2>/dev/null; then
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
      log_error "Fehlerursache liegt vermutlich bei der Ziel-Policy des Dienstes"
      log_error "(z.B. Keycloak password_policy), NICHT beim Passwort-Rendering."
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

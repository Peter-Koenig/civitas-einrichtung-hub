#!/usr/bin/env bash
# 06_civitas.sh – Phase 2: CIVITAS/CORE-Plattform via cc_cli (V1)
# Siehe skriptarchitektur.md (V1), Modul 06
# Siehe installationsphasen-und-abnahme.md (V1), Phase 2
# Referenz: https://docs.core.civitasconnect.digital/docs/1.5.0/Deployment/Platform-Installation/
#
# Installiert die CIVITAS/CORE-Plattform über cc_cli auf dem in Phase 1
# bereitgestellten k3s-Cluster.
#
# Abhängigkeiten:
#   - Phase 1 vollständig abgeschlossen (04_k3s.sh, 05_addons.sh)
#   - Gültiger kubeconfig unter $KUBECONFIG_PATH
#   - DNS-Einträge für idm.$DOMAIN und portal.$DOMAIN (harte Prüfung hier)
#   - SMTP-Zugangsdaten als Umgebungsvariablen
#   - 01_config.sh: DOMAIN, CC_CLI_VERSION, SMTP_*, K8S_NAMESPACE, …
#   - 02_lib.sh: log_*, wait_pods_ready, dns_resolves
#   - templates_V1/inventory.yml.tpl
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
  apply_overlay
  patch_masterportal_release_name
  install_cc_cli
  render_inventory
  setup_wireguard
  patch_playbook_urls
  cleanup_geodata_ingress
  run_cc_cli_validate
  run_cc_cli_exec

  # Logfile-Prüfung nach cc_cli exec
  local ansible_log="${CC_CLI_PLAYBOOK_DIR}/logs/ansible_run_latest.log"
  if [[ -f "${ansible_log}" ]]; then
    log_ok "Ansible-Log gefunden: ${ansible_log}"
  else
    log_warn "Ansible-Log NICHT gefunden: ${ansible_log}"
  fi

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
  local restore_rc=0
  restore_le_certs || restore_rc=$?
  ensure_keycloak_admin_user

  if [[ ${restore_rc} -eq 0 ]]; then
    log_ok "LE-Zertifikate aus Backup wiederhergestellt — switch_certificate_issuer wird uebersprungen"
  else
    switch_certificate_issuer
  fi
  log_ok "Phase 2 abgeschlossen – CIVITAS/CORE laeuft in Namespaces: ${K8S_NAMESPACES[*]}"
}

# ── Schritt 2.0: DNS hart prüfen ──────────────────────────────────────────────
check_dns_hard() {
  log "Prüfe DNS (harte Prüfung) …"
  local dns_ok=true

  if ! dns_resolves "idm.${DOMAIN}"; then
    log_error "DNS: idm.${DOMAIN} nicht auflösbar – Eintrag in Hetzner-WebGUI setzen"
    dns_ok=false
  fi
  if ! dns_resolves "portal.${DOMAIN}"; then
    log_error "DNS: portal.${DOMAIN} nicht auflösbar – Eintrag in Hetzner-WebGUI setzen"
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
# Kopiert alle Dateien aus overlay_V1/ in die entsprechende Zielstruktur
# unterhalb von CC_CLI_PLAYBOOK_DIR. Erzeugt vor dem Ueberschreiben ein
# Backup der Originaldatei (.overlay_backup/<relpath>.orig), falls noch
# keines existiert.
apply_overlay() {
  local overlay_src="${SCRIPT_DIR}/overlay_V1"
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
      log_error "  (Strukturaenderung im Upstream-Repo? Ueberpruefe overlay_V1/${rel_path})"
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
  local tpl="${script_dir}/templates_V1/inventory.yml.tpl"
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
    -e "s|PLACEHOLDER_APISIX_DASHBOARD|${APISIX_DASHBOARD:-false}|g" \
    -e "s|PLACEHOLDER_APISIX_JWT_SECRET|${pw_apisix_dashboard_jwt}|g" \
    -e "s|PLACEHOLDER_APISIX_DASHBOARD_USER|admin@${DOMAIN}|g" \
    -e "s|PLACEHOLDER_APISIX_DASHBOARD_PASS|${pw_apisix_dashboard_pass}|g" \
    -e "s|PLACEHOLDER_INGRESSCLASS|${INGRESS_CLASS:-nginx}|g" \
    -e "s|PLACEHOLDER_ADMINEMAIL|${ADMIN_EMAIL}|g" \
    -e "s|PLACEHOLDER_SMTP_HOST|${SMTP_HOST}|g" \
    -e "s|PLACEHOLDER_SMTP_USER|${SMTP_USER}|g" \
    -e "s|PLACEHOLDER_SMTP_PASS|${SMTP_PASS}|g" \
    -e "s|PLACEHOLDER_SMTP_FROM|${SMTP_FROM:-no-reply@${DOMAIN_NAME}}|g" \
    -e "s|PLACEHOLDER_KEYCLOAK_ADMIN_PASSWORD|${pw_keycloak}|g" \
    -e "s|PLACEHOLDER_PGADMIN_PASSWORD|${pw_pgadmin}|g" \
    -e "s|PLACEHOLDER_APISIX_ADMIN_ROLE_KEY|${pw_apisix_admin_role}|g" \
    -e "s|PLACEHOLDER_APISIX_VIEWER_ROLE_KEY|${pw_apisix_viewer_role}|g" \
    -e "s|PLACEHOLDER_SUPERSET_DB_SECRET|${pw_superset_db}|g" \
    -e "s|PLACEHOLDER_SUPERSET_ADMIN_PASSWORD|${pw_superset_admin}|g" \
    -e "s|PLACEHOLDER_SUPERSET_REDIS_PASSWORD|${pw_superset_redis}|g" \
    -e "s|PLACEHOLDER_GRAFANA_PASSWORD|${pw_grafana}|g" \
    -e "s|PLACEHOLDER_GEOSERVER_PASSWORD|${pw_geoserver}|g" \
    -e "s|PLACEHOLDER_PIVAU_PASSWORD|${pw_pivau}|g" \
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

# ── Schritt 2.4: cc_cli exec ──────────────────────────────────────────────────
# Timeout schützt vor unbegrenzt hängenden Deployments.
run_cc_cli_exec() {
  log "Fuehre cc_cli exec aus (Timeout: ${TIMEOUT_CC_CLI_EXEC}s) …"

  # Ansible-Logging aktivieren (globaler Log-Pfad, hohe Verbosity)
  local ansible_log_dir="${CC_CLI_PLAYBOOK_DIR}/logs"
  local ansible_log_file="${ansible_log_dir}/ansible_run_latest.log"
  mkdir -p "${ansible_log_dir}"
  export ANSIBLE_LOG_PATH="${ansible_log_file}"
  # ANSIBLE_DEBUG NICHT setzen — fuehrt zu "'debug' is not a valid AnsibleEventType"
  export ANSIBLE_VERBOSITY=3
  log "  Ansible-Log: ${ANSIBLE_LOG_PATH}"
  log "  ANSIBLE_VERBOSITY=3"
  log "  Arbeitsverzeichnis: $(pwd)"
  log "  Inhalt: $(ls -la)"
  log "  Log-Verzeichnis: $(ls -la "${ansible_log_dir}" 2>/dev/null || echo 'leer')"

  local output rc=0
  output=$(cd "${CC_CLI_PLAYBOOK_DIR}" && \
    echo "Y" | timeout "${TIMEOUT_CC_CLI_EXEC}" \
    "${CC_CLI_VENV_PATH}/bin/cc_cli" exec 2>&1) || rc=$?
  echo "${output}"
  local cc_cli_rc="${rc}"
  echo "cc_cli rc=${cc_cli_rc}"
  ls -la "${ansible_log_dir}"
  test -f "${ansible_log_file}" && tail -n 80 "${ansible_log_file}" || echo "kein ansible_log_file vorhanden"
  # Nur echte Infrastrukturfehler abbrechen, 404-Idempotenzfaelle tolerieren
  if echo "${output}" | grep -q "failed with status: failed"; then
    if echo "${output}" | grep -q "Status code was 404 and not \[204\]"; then
      log_warn "cc_cli exec: Playbook meldet 404 statt 204 beim Loeschen einer Keycloak-Ressource, toleriert (Idempotenz-Fall)."
    else
      log_error "cc_cli exec: Playbook fehlgeschlagen — Logs pruefen:"
      log_error "  ${ansible_log_file}"
      log_warn ""
      log_warn "Moegliche Ursache: Eine Passwort-Validierung (z. B. 'Ensure PGAdmin password')"
      log_warn "hat sporadisch nicht bestanden. Das ist kein Infrastrukturfehler –"
      log_warn "einfach den Build neu starten, dann wird ein neues, gueltiges Passwort generiert."
      log_warn "Bei wiederholtem Auftreten: Passwort-Laenge in 06_civitas.sh erhoehen."
      log_warn ""
      exit 1
    fi
  fi
  log_ok "cc_cli exec erfolgreich abgeschlossen (oder nur mit toleriertem 404)"

  # Logfile-Pruefung
  if [[ -f "${ansible_log_file}" ]]; then
    log_ok "Ansible-Log gefunden: ${ansible_log_file}"
  else
    log_warn "Ansible-Log NICHT gefunden: ${ansible_log_file}"
  fi
}



# ── Schritt 2.4c: WireGuard konfigurieren und Tunnel aktivieren ──────────────
# Idempotenz: Tunnel bereits aktiv → return 0.
# Leerer WG_PRESHARED_KEY → PresharedKey-Zeile wird weggelassen
# (WireGuard wirft Fehler bei leerem Wert).
setup_wireguard() {
  log "Konfiguriere WireGuard (Schritt 2.4c) …"

  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    log_ok "WireGuard-Tunnel ${WG_INTERFACE} bereits aktiv – überspringe"
    return 0
  fi

  local tpl="${SCRIPT_DIR}/templates_V1/wg0.conf.tpl"
  if [[ ! -f "${tpl}" ]]; then
    log_error "WireGuard-Template nicht gefunden: ${tpl}"
    exit 1
  fi

  # Config-Verzeichnis anlegen
  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard

  # PreSharedKey-Zeile nur einfügen wenn gesetzt
  local psk_line=""
  if [[ -n "${WG_PRESHARED_KEY:-}" ]]; then
    psk_line="PreSharedKey = ${WG_PRESHARED_KEY}"
  fi

  sed \
    -e "s|WG_VM_PRIVATE_KEY|${WG_VM_PRIVATE_KEY}|g" \
    -e "s|WG_VM_IP|${WG_VM_IP}|g" \
    -e "s|WG_LISTEN_PORT|${WG_LISTEN_PORT:-51820}|g" \
    -e "s|WG_OPN_PUBLIC_KEY|${WG_OPN_PUBLIC_KEY}|g" \
    -e "s|WG_PRESHARED_KEY|${psk_line}|g" \
    -e "s|WG_OPN_ENDPOINT|${WG_OPN_ENDPOINT}|g" \
    -e "s|WG_ALLOWED_IPS|${WG_ALLOWED_IPS:-10.10.10.0/24}|g" \
    "${tpl}" > "${WG_CONF_PATH}"

  chmod 600 "${WG_CONF_PATH}"
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
  log_ok "WireGuard-Tunnel ${WG_INTERFACE} gestartet und aktiviert"

  # Konnektivität zu OPNsense prüfen
  log "Prüfe WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) …"
  local attempts=0
  until ping -c1 -W2 "${WG_OPN_IP}" >/dev/null 2>&1; do
    sleep 3
    (( attempts++ )) || true
    if [[ ${attempts} -ge 10 ]]; then
      log_error "OPNsense ${WG_OPN_IP} nach 30s nicht erreichbar."
      log_error "WireGuard-Konfiguration auf OPNsense-Seite prüfen."
      exit 1
    fi
  done
  log_ok "WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) bestätigt"
}

# ── Playbook-URLs patchen ────────────────────────────────────────────────
# Ansible's uri-Modul folgt bei POST keine Redirects. Die Keycloak-Admin-API
# verwendet URLs ohne /auth-Prefix und redirectet auf die korrekte URL.
# Ohne diesen Patch scheitern POST-Rollenzuweisungen mit 404.
patch_playbook_urls() {
  log "Patch: follow_redirects in Ansible-Playbooks …"
  local files=(
    "tasks/geodata/configure/integrated_keycloak.yml"
    "tasks/geodata/install/geoserver_setup_role_service.yml"
    "tasks/access/keycloak/idm-config/keycloak_8_users.yml"
    "tasks/access/keycloak/idm-config/keycloak_5_clients.yml"
    "tasks/dashboard/superset.yml"
    "tasks/datacatalog/piveau.yml"
  )
  local patched=0
  for f in "${files[@]}"; do
    local fullpath="${CC_CLI_PLAYBOOK_DIR}/${f}"
    if [[ ! -f "${fullpath}" ]]; then
      continue
    fi
    # follow_redirects in role-mappings-Blöcken einfügen
    sed -i '/role-mappings\/clients/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    # follow_redirects in admin/realms/*/users-Blöcken
    sed -i '/admin\/realms\/.*\/users$/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    # follow_redirects in admin/realms/*/clients-Blöcken
    sed -i '/admin\/realms\/.*\/clients$/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    (( patched++ )) || true
  done
  log_ok "Playbook-URLs in ${patched} Dateien gepatcht"
}

# ── GeoData-Ingress bereinigen ──────────────────────────────────────────
# Entfernt doppelten GeoData-Ingress (geostack vs. geostack-geostack).
cleanup_geodata_ingress() {
  local ns="${CC_ENVIRONMENT}-geodata-stack"

  if ! kubectl get namespace "${ns}" &>/dev/null; then
    log "Namespace ${ns} nicht gefunden — überspringe Ingress-Bereinigung"
    return 0
  fi

  if kubectl get ingress geostack -n "${ns}" &>/dev/null; then
    kubectl delete ingress geostack -n "${ns}" --ignore-not-found
    log_ok "Doppelten GeoData-Ingress (geostack) in ${ns} entfernt"
  else
    log "Kein doppelter GeoData-Ingress in ${ns} gefunden"
  fi
}

# ── LE-Zertifikate aus Backup wiederherstellen ──────────────────────────
restore_le_certs() {
  local backup_file="${VM_REMOTE_INSTALL_DIR}/le-certs-backup.yaml"
  if [[ ! -f "${backup_file}" ]]; then
    log "Kein LE-Zertifikats-Backup gefunden (${backup_file}) — ueberspringe"
    return 1
  fi

  log "Stelle LE-Zertifikate aus Backup wieder her …"

  # ── Schritt 1: ClusterIssuer letsencrypt-prod sicherstellen ────────────────
  if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
    log "Lege ClusterIssuer letsencrypt-prod an …"
    kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
    log_ok "ClusterIssuer letsencrypt-prod angelegt"
  else
    log_ok "ClusterIssuer letsencrypt-prod bereits vorhanden"
  fi

  # ── Schritt 2: Ingress-Annotationen ZUERST auf letsencrypt-prod setzen ───
  # Dies MUSS vor dem Loeschen der Certificate-Ressourcen passieren, sonst
  # erzeugt ingress-shim beim Neuanlegen eine Certificate-Ressource mit dem
  # noch alten/fehlenden Issuer (Race Condition).
  log "Setze Issuer-Annotationen auf letsencrypt-prod (vor Certificate-Loeschung) …"
  local annotated=0
  while IFS=$'\t' read -r ns name; do
    kubectl annotate ingress "${name}" -n "${ns}" \
      cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite \
      >/dev/null 2>&1 || true
    (( annotated++ )) || true
  done < <(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${annotated} Ingress(es) auf letsencrypt-prod annotiert"

  # ── Schritt 3: Certificate-Ressourcen loeschen ────────────────────────────
  # ingress-shim erzeugt sie sofort neu — jetzt aber korrekt mit issuerRef
  # letsencrypt-prod (weil Schritt 2 die Annotation bereits gesetzt hat).
  log "Entferne alte Certificate-Ressourcen …"
  local certs=0
  while IFS=$'\t' read -r ns name; do
    kubectl delete certificate "${name}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
    (( certs++ )) || true
  done < <(kubectl get certificate --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name != "civitas-core-ca") | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${certs} Certificate-Ressourcen entfernt"

  # Kurze Wartezeit, bis ingress-shim die neuen Certificate-Ressourcen
  # (mit issuerRef letsencrypt-prod) angelegt hat
  sleep 5

  # ── Schritt 4: Secrets aus Backup einspielen ──────────────────────────────
  # cert-manager erkennt: Secret bereits vorhanden + Certificate zeigt auf
  # letsencrypt-prod + Zertifikat noch gueltig → keine Neuausstellung.
  if ! kubectl apply -f "${backup_file}" >/dev/null 2>&1; then
    log_warn "LE-Zertifikats-Backup konnte nicht eingespielt werden"
    log_warn "  Zertifikate muessen neu bei Let's Encrypt beantragt werden"
    return 1
  fi
  log_ok "LE-Zertifikats-Secrets aus Backup wiederhergestellt"

  # ── Schritt 5: Verifikation ──────────────────────────────────────────────
  # Warten auf Reconcile-Zyklus von cert-manager
  sleep 10
  log "Verifiziere wiederhergestellte Zertifikate …"
  local verify_ns="${CC_ENVIRONMENT}-access-stack"
  local verify_secret="idm.${DOMAIN}-tls"
  if kubectl get secret "${verify_secret}" -n "${verify_ns}" &>/dev/null; then
    local issuer
    issuer=$(kubectl get secret "${verify_secret}" -n "${verify_ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
    if echo "${issuer}" | grep -qi "STAGING\|civitas-core-ca"; then
      log_warn "Wiederhergestelltes Zertifikat ist kein LE-Production-Zertifikat: ${issuer}"
      log_warn "  Zertifikate muessen neu bei Let's Encrypt beantragt werden"
      return 1
    fi
    log_ok "Zertifikat-Verifikation erfolgreich: issuer=${issuer}"
  else
    log_warn "Secret ${verify_secret} in ${verify_ns} nach Restore nicht gefunden"
    return 1
  fi

  log_ok "LE-Zertifikate erfolgreich aus Backup wiederhergestellt"
  return 0
}

# ── Admin-User im Realm erzwingen ───────────────────────────────────────
# Stellt sicher, dass der Admin-User (ADMIN_EMAIL) im Ziel-Realm existiert.
ensure_keycloak_admin_user() {
  local ns="${CC_ENVIRONMENT}-access-stack"
  local secret_name="${CC_ENVIRONMENT}-keycloak-admin"
  local realm="${CC_ENVIRONMENT}"
  local idm_base="https://idm.${DOMAIN}"

  # Prüfen ob Namespace + Secret existieren
  if ! kubectl get namespace "${ns}" &>/dev/null; then
    log_warn "Namespace ${ns} nicht gefunden — überspringe Admin-User-Prüfung"
    return 0
  fi
  if ! kubectl get secret "${secret_name}" -n "${ns}" &>/dev/null; then
    log_warn "Secret ${secret_name} in ${ns} nicht gefunden — überspringe Admin-User-Prüfung"
    return 0
  fi

  local master_user master_pass token
  master_user=$(kubectl get secret "${secret_name}" -n "${ns}" \
    -o jsonpath='{.data.MASTER_USERNAME}' | base64 -d 2>/dev/null || true)
  master_pass=$(kubectl get secret "${secret_name}" -n "${ns}" \
    -o jsonpath='{.data.MASTER_PASSWORD}' | base64 -d 2>/dev/null || true)

  if [[ -z "${master_user}" || -z "${master_pass}" ]]; then
    log_warn "Keycloak-Admin-Credentials nicht lesbar — überspringe Admin-User-Prüfung"
    return 0
  fi

  # Master-Token holen
  token=$(curl -sk --max-time 10 \
    "${idm_base}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${master_user}" \
    -d "password=${master_pass}" \
    -d "grant_type=password" 2>/dev/null | jq -r '.access_token' 2>/dev/null || true)

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log_warn "Keycloak-Master-Token nicht erhalten — überspringe Admin-User-Prüfung"
    log_warn "  (Keycloak möglicherweise noch nicht vollständig gestartet)"
    return 0
  fi

  # Prüfen ob Admin im Ziel-Realm existiert
  local admin_id
  admin_id=$(curl -sk --max-time 10 \
    "${idm_base}/admin/realms/${realm}/users" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    2>/dev/null | jq -r ".[] | select(.email==\"${ADMIN_EMAIL}\") | .id" 2>/dev/null || true)

  if [[ -n "${admin_id}" ]]; then
    log_ok "Admin-User ${ADMIN_EMAIL} existiert bereits in Realm ${realm}"
    return 0
  fi

  # Admin-User anlegen
  log "Lege Admin-User ${ADMIN_EMAIL} in Realm ${realm} an …"
  local http_code
  http_code=$(curl -sk --max-time 10 -w "%{http_code}" -o /dev/null \
    "${idm_base}/admin/realms/${realm}/users" \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"username\":\"${ADMIN_EMAIL}\",\"enabled\":true}" 2>/dev/null || true)

  if [[ "${http_code}" == "201" ]]; then
    log_ok "Admin-User ${ADMIN_EMAIL} in Realm ${realm} angelegt"
  else
    log_warn "Admin-User ${ADMIN_EMAIL} konnte nicht angelegt werden (HTTP ${http_code})"
    log_warn "  User manuell in Keycloak anlegen: ${idm_base}/admin/master/console/#/realms/${realm}/users"
  fi
}

# ── switch_certificate_issuer: Wechsel zwischen LE-Staging und -Production ──
# Steuert den Wechsel von Let's-Encrypt-Staging auf -Production fuer alle
# Ingress-Ressourcen per Annotation cert-manager.io/cluster-issuer.
# (Siehe Spec: netzwerk-dns-tls.md, Variante E)
#
# Aufruf: switch_certificate_issuer
#
# Ablauf:
#   1. Ingress-Liste mit tls-Block ermitteln (Namespaces cc-prd-*)
#   2. Annotation auf letsencrypt-staging setzen
#   3. Warten auf READY + issuer-Prüfung (muss (STAGING) enthalten)
#   4. Nur wenn alle Staging bestanden: Annotation auf letsencrypt-prod
#   5. Production-Zertifikate verifizieren (kein (STAGING) mehr)
#   6. Report mit Erfolg/Fehler pro Host
# ── switch_certificate_issuer: Wechsel zwischen LE-Staging und -Production ──
# Steuert den Wechsel von Let's-Encrypt-Staging auf -Production fuer alle
# Ingress-Ressourcen per Annotation cert-manager.io/cluster-issuer.
# (Siehe Spec: netzwerk-dns-tls.md, Variante E)
#
# Wird am Ende des Installationsdurchlaufs (install_civitas) automatisch
# ausgefuehrt. Kann auch manuell aufgerufen werden.
#
# Ablauf:
#   1. Pruefung ob bereits LE-Production aktiv → ueberspringen
#   2. ClusterIssuer letsencrypt-staging anlegen (falls nicht vorhanden)
#   3. Annotation auf letsencrypt-staging setzen (alle Ingresses)
#   4. Warten auf READY + issuer-Prüfung (muss (STAGING) enthalten)
#   5. ClusterIssuer letsencrypt-prod anlegen (falls nicht vorhanden)
#   6. Nur wenn alle Staging bestanden: Annotation auf letsencrypt-prod
#   7. Production-Zertifikate verifizieren (kein (STAGING) mehr)
#   8. Report mit Erfolg/Fehler pro Host
switch_certificate_issuer() {
  log "=== switch_certificate_issuer: LE-Staging -> Production ==="

  local le_email="${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"

  # ── 0. Idempotenz: Bereits auf LE-Production? ─────────────────────────────
  log "Pruefe aktuelle Issuer-Annotationen …"
  local all_prod=true
  local any_annotated=false
  for ingress_entry in $(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true); do
    local ns_name=(${ingress_entry/\// })
    local ns="${ns_name[0]}"
    local name="${ns_name[1]}"
    local cur
    cur=$(kubectl get ingress "${name}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true)
    if [[ -n "${cur}" ]]; then
      any_annotated=true
    fi
    if [[ "${cur}" != "letsencrypt-prod" ]]; then
      all_prod=false
    fi
  done

  if [[ "${all_prod}" == "true" && "${any_annotated}" == "true" ]]; then
    log_ok "Alle Ingresses bereits auf letsencrypt-prod – nichts zu tun"
    return 0
  fi

  local staging_success=0 staging_failed=0 prod_success=0 prod_failed=0
  local total=0

  # ── 1. Ingress-Liste ermitteln (nur mit tls-Block) ───────────────────────
  log "Ermittle Ingress-Ressourcen mit tls-Block …"

  local ingress_list
  ingress_list=$(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.tls[0].secretName)"' 2>/dev/null || true)

  if [[ -z "${ingress_list}" ]]; then
    log_warn "Keine Ingresses mit tls-Block gefunden"
    return 0
  fi

  total=$(echo "${ingress_list}" | wc -l)
  log_ok "${total} Ingress(es) mit tls-Block gefunden"

  # ── 1a. ClusterIssuer sicherstellen ───────────────────────────────────────
  if ! kubectl get clusterissuer letsencrypt-staging &>/dev/null; then
    log "Lege ClusterIssuer letsencrypt-staging an …"
    kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${le_email}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
    log_ok "ClusterIssuer letsencrypt-staging angelegt"
  else
    log_ok "ClusterIssuer letsencrypt-staging bereits vorhanden"
  fi

  # ── 2. Staging-Phase ─────────────────────────────────────────────────────
  log ""
  log "=== Phase 1: Staging (letsencrypt-staging) ==="

  while IFS=$'\t' read -r ns name secret; do
    log "  Pruefe Ingress ${ns}/${name} …"

    local current_issuer
    current_issuer=$(kubectl get ingress "${name}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true)

    if [[ "${current_issuer}" == "letsencrypt-staging" ]]; then
      log_ok "  Bereits auf letsencrypt-staging – ueberspringe"
      staging_success=$((staging_success + 1))
      continue
    fi

    kubectl annotate ingress "${name}" -n "${ns}" \
      cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite \
      >/dev/null 2>&1 || {
      log_error "  Annotation fehlgeschlagen fuer ${ns}/${name}"
      staging_failed=$((staging_failed + 1))
      continue
    }
    log_ok "  Annotation gesetzt: letsencrypt-staging auf ${ns}/${name}"

    # Warten auf READY
    if kubectl wait "certificate/${secret}" -n "${ns}" \
      --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
      staging_success=$((staging_success + 1))
    else
      log_error "  Certificate ${secret} in ${ns} wurde nicht READY (Timeout 180s)"
      staging_failed=$((staging_failed + 1))
    fi

    # issuer prüfen (muss (STAGING) enthalten)
    local issuer
    issuer=$(kubectl get secret "${secret}" -n "${ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)

    if echo "${issuer}" | grep -qi "STAGING"; then
      log_ok "  Staging-Zertifikat bestaetigt (issuer enthaelt STAGING)"
    else
      log_warn "  Staging-Zertifikat NICHT bestaetigt – issuer: ${issuer:-leer}"
    fi
  done <<< "${ingress_list}"

  # ── 3. LE_CERT-Schalter auswerten ──────────────────────────────────────
  if [[ ${staging_failed} -gt 0 ]]; then
    log_error "Staging-Phase: ${staging_success} OK, ${staging_failed} fehlgeschlagen"
    log_error "Production-Phase wird NICHT gestartet – Fehler beheben und erneut ausfuehren"
    staging_ok=0
  elif [[ "${LE_CERT:-false}" != "true" ]]; then
    log_ok "Staging-Phase: ALLE ${staging_success} Ingresses erfolgreich"
    log_warn "LE_CERT=false — Production-Phase wird uebersprungen"
    log_warn "  Setze LE_CERT=true in .env.local fuer Production-Zertifikate"
    staging_ok=0  # Ueberspringt Production
  else
    log_ok "Staging-Phase: ALLE ${staging_success} Ingresses erfolgreich"
    staging_ok=1
  fi

  # ── 3a. ClusterIssuer letsencrypt-prod sicherstellen ──────────────────────
  if [[ ${staging_ok} -eq 1 ]]; then
    if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
      log "Lege ClusterIssuer letsencrypt-prod an …"
      kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
      log_ok "ClusterIssuer letsencrypt-prod angelegt"
    else
      log_ok "ClusterIssuer letsencrypt-prod bereits vorhanden"
    fi

    # ── 4. Production-Phase ────────────────────────────────────────────────
    log ""
    log "=== Phase 2: Production (letsencrypt-prod) ==="
    log_warn "Let's-Encrypt-Rate-Limit: max. 50 Zertifikate pro Domain/Woche"
    log_warn "  ${total} Zertifikat(e) werden jetzt angefordert"

    while IFS=$'\t' read -r ns name secret; do
      log "  Setze Production auf ${ns}/${name} …"

      kubectl annotate ingress "${name}" -n "${ns}" \
        cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite \
        >/dev/null 2>&1 || {
        log_error "  Annotation fehlgeschlagen fuer ${ns}/${name}"
        prod_failed=$((prod_failed + 1))
        continue
      }
      log_ok "  Annotation gesetzt: letsencrypt-prod auf ${ns}/${name}"

      # Warten auf READY
      if kubectl wait "certificate/${secret}" -n "${ns}" \
        --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
        prod_success=$((prod_success + 1))
      else
        log_error "  Certificate ${secret} in ${ns} wurde nicht READY (Timeout 180s)"
        prod_failed=$((prod_failed + 1))
      fi

      # issuer prüfen (darf kein STAGING enthalten)
      local issuer
      issuer=$(kubectl get secret "${secret}" -n "${ns}" \
        -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
        | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)

      if echo "${issuer}" | grep -qi "STAGING"; then
        log_warn "  Zertifikat enthaelt noch STAGING – warte auf Aktualisierung"
      else
        log_ok "  Production-Zertifikat bestaetigt (kein STAGING)"
      fi
    done <<< "${ingress_list}"
  fi

  # ── 5. Report ────────────────────────────────────────────────────────────
  log ""
  log "============================================"
  log "  REPORT: switch_certificate_issuer"
  log "============================================"
  log "  Ingresses gesamt:       ${total}"
  log "  Staging OK:             ${staging_success}"
  log "  Staging FAIL:           ${staging_failed}"
  if [[ ${staging_ok} -eq 1 ]]; then
    log "  Production OK:          ${prod_success}"
    log "  Production FAIL:        ${prod_failed}"
  else
    log "  Production:             NICHT GESTARTET (Staging-Fehler)"
  fi
  log ""
  log_warn "  Let's-Encrypt-Rate-Limit: 50 Zertifikate/Woche/Domain"
  log "============================================"

  # Exit-Code: 0 = alles OK, 1 = Staging-Probleme, 2 = Production-Probleme
  if [[ ${staging_failed} -gt 0 ]]; then
    return 1
  elif [[ ${prod_failed} -gt 0 ]]; then
    return 2
  fi
  return 0
}

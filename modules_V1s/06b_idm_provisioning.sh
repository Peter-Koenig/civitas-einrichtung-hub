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
# 06b_idm_provisioning.sh — IDM/Keycloak-Provisionierung (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 06b
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 2
#
# Enthält Funktionen zur Provisionierung von Benutzern und Rollen in
# Keycloak (idm) nach dem CIVITAS/CORE-Deployment.
#
# Aus 06_civitas.sh ausgegliedert, um die Modulverantwortlichkeiten
# zu trennen.
#
# Abhängigkeiten:
#   - 01_config.sh: DOMAIN, CC_ENVIRONMENT, ADMIN_EMAIL, ADMIN_PASS, …
#   - 02_lib.sh: log_*, dns_resolves, gen_policy_password
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)
#   - curl, jq

set -euo pipefail


# ── Admin-User im Realm erzwingen ───────────────────────────────────────
# Stellt sicher, dass der Admin-User (ADMIN_EMAIL) im Ziel-Realm existiert,
# ein initiales Passwort gesetzt hat und die notwendigen Admin-Rollen
# zugewiesen bekommt.
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
    # Passwort und Rollen trotzdem sicherstellen (für Idempotenz)
    set_user_password "${idm_base}" "${token}" "${realm}" "${admin_id}"
    assign_admin_roles "${idm_base}" "${token}" "${realm}" "${admin_id}"
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

    # User-ID nach dem Anlegen ermitteln
    local new_user_id
    new_user_id=$(curl -sk --max-time 10 \
      "${idm_base}/admin/realms/${realm}/users" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      2>/dev/null | jq -r ".[] | select(.email==\"${ADMIN_EMAIL}\") | .id" 2>/dev/null || true)

    if [[ -n "${new_user_id}" ]]; then
      set_user_password "${idm_base}" "${token}" "${realm}" "${new_user_id}"
      assign_admin_roles "${idm_base}" "${token}" "${realm}" "${new_user_id}"
    else
      log_warn "Konnte User-ID für ${ADMIN_EMAIL} nicht ermitteln"
      log_warn "  Passwort und Rollen müssen manuell gesetzt werden:"
      log_warn "  ${idm_base}/admin/master/console/#/realms/${realm}/users"
    fi
  else
    log_warn "Admin-User ${ADMIN_EMAIL} konnte nicht angelegt werden (HTTP ${http_code})"
    log_warn "  User manuell in Keycloak anlegen: ${idm_base}/admin/master/console/#/realms/${realm}/users"
  fi
}


# ── Passwort für Admin-User setzen ──────────────────────────────────────
# Setzt das initiale Passwort auf ADMIN_PASS (nicht temporär).
set_user_password() {
  local idm_base="$1" token="$2" realm="$3" user_id="$4"

  log "Setze Passwort für User ${user_id} in Realm ${realm} …"
  local http_code
  http_code=$(curl -sk --max-time 10 -w "%{http_code}" -o /dev/null \
    "${idm_base}/admin/realms/${realm}/users/${user_id}/reset-password" \
    -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"${ADMIN_PASS}\",\"temporary\":false}" 2>/dev/null || true)

  if [[ "${http_code}" == "204" ]]; then
    log_ok "Passwort für ${ADMIN_EMAIL} gesetzt (nicht temporär)"
  else
    log_warn "Passwort setzen fehlgeschlagen (HTTP ${http_code})"
  fi
}


# ── Admin-Rollen zuweisen ───────────────────────────────────────────────
# Weist dem Admin-User die wichtigsten Rollen zu: geoAdmin, supersetAdmin,
# grafanaAdmin, operator. Idempotent: bereits zugewiesene Rollen werden
# nicht doppelt gebucht.
assign_admin_roles() {
  local idm_base="$1" token="$2" realm="$3" user_id="$4"

  local target_roles=("geoAdmin" "supersetAdmin" "grafanaAdmin" "operator")
  log "Prüfe Admin-Rollen für User ${user_id} in Realm ${realm} …"

  # Verfügbare Realm-Rollen abrufen
  local available_roles
  available_roles=$(curl -sk --max-time 10 \
    "${idm_base}/admin/realms/${realm}/roles" \
    -H "Authorization: Bearer ${token}" \
    2>/dev/null || echo "[]")

  # Bereits zugewiesene Rollen abrufen
  local assigned_roles
  assigned_roles=$(curl -sk --max-time 10 \
    "${idm_base}/admin/realms/${realm}/users/${user_id}/role-mappings/realm" \
    -H "Authorization: Bearer ${token}" \
    2>/dev/null || echo "[]")

  # Zu vergebende Rollen sammeln
  local to_assign=()
  local new_count=0
  local skip_count=0

  for role in "${target_roles[@]}"; do
    # Prüfen ob bereits zugewiesen (Idempotenz)
    if echo "${assigned_roles}" | jq -e ".[] | select(.name==\"${role}\")" >/dev/null 2>&1; then
      log_ok "Rolle ${role} bereits zugewiesen — überspringe"
      (( skip_count++ )) || true
      continue
    fi

    # Rollen-ID in verfügbaren Rollen suchen
    local role_id
    role_id=$(echo "${available_roles}" | jq -r ".[] | select(.name==\"${role}\") | .id" 2>/dev/null || true)
    if [[ -z "${role_id}" ]]; then
      log_warn "Rolle ${role} im Realm nicht gefunden — überspringe"
      continue
    fi

    to_assign+=("{\"id\":\"${role_id}\",\"name\":\"${role}\"}")
    (( new_count++ )) || true
  done

  # Keine neuen Rollen → fertig
  if [[ ${#to_assign[@]} -eq 0 ]]; then
    log_ok "${skip_count} Rolle(n) bereits vorhanden, keine neuen zuzuweisen"
    return 0
  fi

  # JSON-Array aus den zu vergebenden Rollen bauen
  local payload
  payload=$(printf ',%s' "${to_assign[@]}")
  payload="[${payload:1}]"

  log "Weise ${new_count} neue Rolle(n) zu: $(echo "${payload}" | jq -r '.[].name' | tr '\n' ' ' | sed 's/ $//')"
  local http_code
  http_code=$(curl -sk --max-time 10 -w "%{http_code}" -o /dev/null \
    "${idm_base}/admin/realms/${realm}/users/${user_id}/role-mappings/realm" \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null || true)

  if [[ "${http_code}" == "204" ]]; then
    log_ok "${new_count} Admin-Rolle(n) erfolgreich zugewiesen"
  else
    log_warn "Rollen-Zuweisung fehlgeschlagen (HTTP ${http_code})"
    log_warn "  Payload: ${payload}"
    log_warn "  Manuell nachholen: ${idm_base}/admin/master/console/#/realms/${realm}/users"
  fi
}


# ── pgAdmin-CA-Trust konfigurieren ───────────────────────────────────────────
# Stellt sicher, dass der pgAdmin-Container die TLS-Zertifikatskette fuer
# die OIDC-Verbindung zu Keycloak (idm) vertraut.
#
# Der ca-importer init-Container im pgAdmin-Pod importiert die CA aus
# der ConfigMap 'cacert' im operation-stack-Namespace. Diese Funktion
# aktualisiert die ConfigMap mit der aktuellen Zertifikatskette aus dem
# idm-TLS-Secret und startet den pgAdmin-Pod neu, damit der ca-importer
# die neue Chain importiert.
#
# Idempotenz: Hash-Vergleich zwischen alter und neuer ConfigMap — Pod-Neustart
# nur bei tatsaechlicher Aenderung der Zertifikatskette.
#
# TODO: #<Platzhalter> — Reconcile-Loop oder Kubernetes CronJob noetig, der bei
# Certificate-Renewal (alle 60–90 Tage bei LE) automatisch erneut die ConfigMap
# aktualisiert und den Pod restartet. Ohne diesen Mechanismus ist die ConfigMap
# nach der ersten LE-Renewal veraltet und pgAdmin verliert die OIDC-Verbindung.
# Loesungsansatz: cert-manager-Certificate mit Event-Trigger (stash/relay) oder
# k8s-CronJob, der taetig wird, sobald das Secret updated_at-Timestamp sich
# aendert.
configure_pgadmin_ca_trust() {
  local pgadmin_ns="${CC_ENVIRONMENT}-operation-stack"
  local tls_secret="idm.${DOMAIN}-tls"
  local tls_secret_ns="${CC_ENVIRONMENT}-access-stack"
  local configmap_name="cacert"
  local cert_name="idm.${DOMAIN}-tls"
  local ca_file="/tmp/pgadmin-ca-bundle.pem"
  local rc=0

  log "Konfiguriere pgAdmin-CA-Trust …"

  # Pruefen ob pgAdmin-Namespace existiert
  if ! kubectl get namespace "${pgadmin_ns}" &>/dev/null; then
    log_warn "Namespace ${pgadmin_ns} nicht gefunden — pgAdmin-CA-Trust uebersprungen"
    return 0
  fi

  # Pruefen ob das idm-Certificate READY ist (P1: Race-Condition-Vermeidung)
  # request_fresh_prod_certificates() und restore_backup_and_switch_to_prod() garantieren nicht in
  # jedem Fall, dass cert-manager den Secret-Inhalt bereits propagiert hat.
  if ! kubectl wait --for=condition=Ready \
       certificate/"${cert_name}" -n "${tls_secret_ns}" --timeout=120s 2>/dev/null; then
    log_error "Certificate ${cert_name} in ${tls_secret_ns} nicht READY nach 120s — Abbruch"
    return 1
  fi
  log_ok "Certificate ${cert_name} ist READY"

  # TLS-Secret-Pfad aus dem Certificate ableiten (Secret heisst wie das Certificate)
  if ! kubectl get secret "${tls_secret}" -n "${tls_secret_ns}" &>/dev/null; then
    log_error "TLS-Secret ${tls_secret} in ${tls_secret_ns} nicht gefunden — Abbruch"
    return 1
  fi

  # Full Chain aus dem TLS-Secret extrahieren
  local secret_data
  secret_data=$(kubectl get secret "${tls_secret}" -n "${tls_secret_ns}" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
  if [[ -z "${secret_data}" ]]; then
    log_error "Keine Daten aus Secret ${tls_secret} extrahiert — Abbruch"
    rm -f "${ca_file}"
    return 1
  fi
  printf '%s' "${secret_data}" | base64 -d > "${ca_file}"

  if [[ ! -s "${ca_file}" ]]; then
    log_error "Leere Chain aus Secret ${tls_secret} extrahiert — Abbruch"
    rm -f "${ca_file}"
    return 1
  fi

  # Gesamte Chain (Leaf + Intermediate + Cross-Sign) als CA-Bundle verwenden.
  # Das Leaf-Zertifikat im Bundle ist harmlos: Python/OpenSSL nutzen nur
  # die CA-Zertifikate daraus fuer die Chain-Verifikation.
  local ca_chain="${ca_file}"

  # P2: Hash-Vergleich fuer echte Idempotenz
  # Nur bei geaenderter Chain wird die ConfigMap aktualisiert und der
  # Pod neugestartet. Dadurch vermeiden wir unnötige Pod-Neustarts bei
  # wiederholtem Skript-Durchlauf.
  local old_hash new_hash
  local existing_cacert
  existing_cacert=$(kubectl get configmap "${configmap_name}" -n "${pgadmin_ns}" \
    -o jsonpath='{.data.cacert\.crt}' 2>/dev/null || echo "")
  old_hash=$(printf '%s' "${existing_cacert}" | sha256sum | awk '{print $1}')
  new_hash=$(sha256sum "${ca_chain}" | awk '{print $1}')

  if [[ -n "${old_hash}" && "${old_hash}" == "${new_hash}" ]]; then
    log_ok "ConfigMap ${configmap_name} bereits aktuell — kein Neustart noetig"
    rm -f "${ca_file}"
    return 0
  fi

  # P3: Fehlerausgabe erfassen und loggen — kein /dev/null
  local apply_output
  if ! apply_output=$(kubectl create configmap "${configmap_name}" \
       -n "${pgadmin_ns}" \
       --from-file="cacert.crt=${ca_chain}" \
       --dry-run=client -o yaml 2>&1 | kubectl apply -f - 2>&1); then
    log_error "ConfigMap-Update fehlgeschlagen: ${apply_output}"
    rm -f "${ca_file}"
    return 1
  fi
  log_ok "ConfigMap ${configmap_name} in ${pgadmin_ns} aktualisiert"

  # pgAdmin-Pod neustarten, damit der ca-importer die neue Chain importiert
  local pgadmin_pod
  pgadmin_pod=$(kubectl get pod -n "${pgadmin_ns}" \
    -l app.kubernetes.io/name=pgadmin4 -o name 2>/dev/null | head -1 || true)

  if [[ -n "${pgadmin_pod}" ]]; then
    local delete_output
    delete_output=$(kubectl delete pod -n "${pgadmin_ns}" \
      -l app.kubernetes.io/name=pgadmin4 2>&1)
    log "pgAdmin-Pod geloescht: $(echo "${delete_output}" | head -1)"
  else
    log_warn "Kein pgAdmin-Pod in ${pgadmin_ns} gefunden — Neustart uebersprungen"
    rm -f "${ca_file}"
    return 0
  fi

  # P4: Verifikation — auf Pod-Ready warten und Trust-Store pruefen
  if ! kubectl wait pod -n "${pgadmin_ns}" \
       -l app.kubernetes.io/name=pgadmin4 \
       --for=condition=Ready --timeout=90s 2>/dev/null; then
    log_error "pgAdmin-Pod nach Neustart nicht Ready innerhalb 90s"
    rm -f "${ca_file}"
    return 1
  fi
  log_ok "pgAdmin-Pod Ready nach Neustart"

  local new_pod
  new_pod=$(kubectl get pod -n "${pgadmin_ns}" \
    -l app.kubernetes.io/name=pgadmin4 -o name 2>/dev/null | head -1 || true)

  if [[ -n "${new_pod}" ]]; then
    local cert_count
    cert_count=$(kubectl exec -n "${pgadmin_ns}" "${new_pod}" -- \
      sh -c 'grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt' \
      2>/dev/null || echo 0)

    if [[ "${cert_count}" -lt 1 ]]; then
      log_warn "ca-importer hat keine Zertifikate importiert (Trust-Store: ${cert_count} Certs)"
      log_warn "  pgAdmin-OIDC-Login koennte weiterhin fehlschlagen"
      rc=1
    else
      log_ok "pgAdmin-Trust-Store enthaelt ${cert_count} Zertifikate — ca-importer aktiv"
    fi
  fi

  # Aufraeumen
  rm -f "${ca_file}"

  if [[ "${rc}" -eq 0 ]]; then
    log_ok "pgAdmin-CA-Trust konfiguriert"
  else
    log_warn "pgAdmin-CA-Trust mit Warnungen abgeschlossen"
  fi
  return "${rc}"
}

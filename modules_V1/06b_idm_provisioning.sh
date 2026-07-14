#!/usr/bin/env bash
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
#   - 01_config.sh: DOMAIN, CC_ENVIRONMENT, ADMIN_EMAIL, …
#   - 02_lib.sh: log_*, dns_resolves, gen_policy_password
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)
#   - curl, jq

set -euo pipefail


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

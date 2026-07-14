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

#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_25_iam.sh — p2d2-AddOn: IAM/Keycloak-Provisionierung (V1s)
#
# Legt im bestehenden Keycloak (Realm cc-prd) die p2d2-Integration an:
#   OIDC-Client (confidential, 5 Redirect-URIs + lokale Dev-URI), 6 Client-Rollen,
#   Rollen-Token-Mapper (resource_access.<client_id>.roles auch im ID-Token),
#   OSM-IdP-Broker (generischer OAuth2) und 6 Demo-Accounts mit Rollen-Grants.
#
# Admin-Zugriff analog modules_V1s/06b_idm_provisioning.sh: Master-Token via
# admin-cli-Password-Grant gegen https://idm.<DOMAIN>, Credentials aus dem K8s-Secret
# <env>-keycloak-admin (Keys MASTER_USERNAME/MASTER_PASSWORD) im Namespace
# <env>-access-stack. KEINE neuen Secrets — nur Lesen des bestehenden Admin-Secrets.
#
# Kontext: wird von p2d2-civitas-addon-v1s.sh gesourct (log/log_ok/log_warn/log_error,
# ADDON_NS/ADDON_DOMAIN/KUBECONFIG sind dort bereits exportiert).

# Fail-Fast: ohne ADDON_DOMAIN sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_DOMAIN nicht gesetzt — addon_25_iam.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

# ── Config ─────────────────────────────────────────────────────────────────────
ADDON_IAM_REALM="${ADDON_IAM_REALM:-cc-prd}"                       # Keycloak-Realm (= Environment)
ADDON_IAM_NS="${ADDON_IAM_NS:-cc-prd-access-stack}"                # Namespace des Keycloak-Admin-Secrets
ADDON_IAM_ADMIN_SECRET="${ADDON_IAM_ADMIN_SECRET:-cc-prd-keycloak-admin}"
ADDON_IAM_CLIENT_ID="${ADDON_IAM_CLIENT_ID:-p2d2}"                 # == OIDC_CLIENT_ID (P2D2_BASE_OIDC_CLIENT_ID)
ADDON_IAM_IDM_BASE="https://idm.${ADDON_DOMAIN}"                   # Keycloak-Basis (idm.udp.data-dna.eu)
# TLS: idm.<DOMAIN> nutzt ein Zertifikat aus cert-manager selfsigned-issuer (interne CA),
# das curl's Default-Trust-Store nicht kennt -> daher unten curl -sk, analog zu
# modules_V1s/06b_idm_provisioning.sh. Sauberere Variante: --cacert mit der CA aus dem
# Secret idm.<DOMAIN>-tls (Namespace <env>-access-stack, Key tls.crt).
# Ausgabedatei für das generierte Client-Secret (chmod 600), analog credentials.env.
ADDON_IAM_CREDENTIALS_FILE="${ADDON_IAM_CREDENTIALS_FILE:-/root/civitas-install/p2d2-addon-credentials.env}"

# Redirect-/Logout-Hosts je Stage (aus VARIABLES.md Stage-Mapping, Domain = ADDON_DOMAIN).
ADDON_IAM_HOSTS=(
  "www.${ADDON_DOMAIN}"      # main
  "dev.${ADDON_DOMAIN}"      # develop
  "f-de1.${ADDON_DOMAIN}"    # de1
  "f-de2.${ADDON_DOMAIN}"    # de2
  "f-fv.${ADDON_DOMAIN}"     # fv
)
ADDON_IAM_DEV_ORIGIN="http://localhost:4321"

# 6 Demo-Accounts (Turn 43; username|email|vorname|nachname|rollen space-getrennt).
ADDON_IAM_DEMO_USERS=(
  "hans|hans.muster@nospam.scanea.de|Hans|Meier|editor verwaltung"
  "jule|jule.kovalenko@nospam.scanea.de|Jule|Kovalenko|verwaltung osm"
  "Chisom|chisom.eze@nospam.scanea.de|Chisom|Eze|verwaltung"
  "arman|arman.ekov@nospam.scanea.de|Arman|Ekov|verwaltung"
  "meera|meera.pillai@nospam.scanea.de|Meera|Pillai|osm qs1_reviewer"
  "valentina|valentina.cruz@nospam.scanea.de|Valentina|Cruz|qs2_reviewer qs1_reviewer osm export_admin"
)

# ── Helfer ─────────────────────────────────────────────────────────────────────
# Master-Token holen (admin-cli Password Grant). Gibt das Token auf stdout aus.
_iam_get_token() {
  local master_user master_pass token
  if ! kubectl get secret "${ADDON_IAM_ADMIN_SECRET}" -n "${ADDON_IAM_NS}" &>/dev/null; then
    log_error "Keycloak-Admin-Secret ${ADDON_IAM_ADMIN_SECRET} in ${ADDON_IAM_NS} nicht gefunden"
    return 1
  fi
  master_user=$(kubectl get secret "${ADDON_IAM_ADMIN_SECRET}" -n "${ADDON_IAM_NS}" \
    -o jsonpath='{.data.MASTER_USERNAME}' | base64 -d 2>/dev/null || true)
  master_pass=$(kubectl get secret "${ADDON_IAM_ADMIN_SECRET}" -n "${ADDON_IAM_NS}" \
    -o jsonpath='{.data.MASTER_PASSWORD}' | base64 -d 2>/dev/null || true)
  if [[ -z "${master_user}" || -z "${master_pass}" ]]; then
    log_error "Keycloak-Admin-Credentials nicht lesbar (MASTER_USERNAME/MASTER_PASSWORD)"
    return 1
  fi
  token=$(curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/realms/master/protocol/openid-connect/token" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${master_user}" \
    --data-urlencode "password=${master_pass}" \
    --data-urlencode "grant_type=password" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  if [[ -z "${token}" ]]; then
    log_error "Keycloak-Master-Token nicht erhalten (Keycloak evtl. noch nicht bereit)"
    return 1
  fi
  printf '%s' "${token}"
}

# Client-UID zuverlässig ermitteln. Der clientId-Query-Filter filtert je nach
# Keycloak-Version nicht zuverlässig, daher volle Liste + clientseitig filtern.
_iam_get_client_uid() {
  local token="$1"
  curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients" \
    -H "Authorization: Bearer ${token}" 2>/dev/null \
    | jq -r ".[] | select(.clientId==\"${ADDON_IAM_CLIENT_ID}\") | .id" 2>/dev/null | head -1 || true
}

# Keycloak-HTTP-Fehlercode in Klartext uebersetzen (fuer klare Log-Meldungen).
_iam_http_hint() {
  case "$1" in
    400) printf 'ungueltige Anfrage (z. B. Passwort erfuellt Policy nicht)' ;;
    401) printf 'nicht autorisiert (Token abgelaufen?)' ;;
    403) printf 'fehlende Berechtigung' ;;
    404) printf 'nicht gefunden' ;;
    409) printf 'Konflikt (z. B. E-Mail/Username bereits vergeben)' ;;
    *)   printf 'unbekannter Fehler' ;;
  esac
}

# HTTP-Helfer fuer die Keycloak-Admin-API. $1=Token, $2=Method, $3=URL,
# $4=optionaler JSON-Body. Ergebnis in den globalen Variablen IAM_HTTP_CODE
# (Statuscode) und IAM_HTTP_BODY (Body). Timeout 15 s; ein curl-Fehler fuehrt zu
# leerem Code/Body, niemals zum Skript-Abbruch.
_iam_req() {
  local token="$1" method="$2" url="$3" body="${4:-}"
  local args=(-sk --max-time 15 -w $'\n%{http_code}' -X "${method}" -H "Authorization: Bearer ${token}")
  [[ -n "${body}" ]] && args+=(-H "Content-Type: application/json" -d "${body}")
  local resp
  resp=$(curl "${args[@]}" "${url}" 2>/dev/null || true)
  IAM_HTTP_CODE="$(printf '%s' "${resp}" | tail -1)"
  IAM_HTTP_BODY="$(printf '%s' "${resp}" | sed '$d')"
}

# ── 1. OIDC-Client ─────────────────────────────────────────────────────────────
ensure_p2d2_oidc_client() {
  log "=== AddOn 25: Keycloak OIDC-Client ${ADDON_IAM_CLIENT_ID} (Realm ${ADDON_IAM_REALM}) ==="
  local token client_id_json client_uid http_code create_resp create_code create_body
  token=$(_iam_get_token) || return 1

  client_uid=$(_iam_get_client_uid "${token}")

  if [[ -n "${client_uid}" ]]; then
    log_ok "OIDC-Client ${ADDON_IAM_CLIENT_ID} existiert bereits (id ${client_uid})"
  else
    local redirects post_logout web_origins payload
    redirects=$(jq -nc \
      --arg main "https://www.${ADDON_DOMAIN}/api/auth/callback" \
      --arg dev "https://dev.${ADDON_DOMAIN}/api/auth/callback" \
      --arg de1 "https://f-de1.${ADDON_DOMAIN}/api/auth/callback" \
      --arg de2 "https://f-de2.${ADDON_DOMAIN}/api/auth/callback" \
      --arg fv "https://f-fv.${ADDON_DOMAIN}/api/auth/callback" \
      --arg devlocal "${ADDON_IAM_DEV_ORIGIN}/api/auth/callback" \
      '[$main,$dev,$de1,$de2,$fv,$devlocal]')
    # Mehrere Werte in post.logout.redirect.uris werden mit '##' getrennt (Turn 75),
    # NICHT mit Leerzeichen — sonst validiert Keycloak den ganzen String als EINE
    # URI und liefert HTTP 400 ("A post-logout redirect URI is not a valid URI").
    # Analog zu redirectUris/webOrigins ist auch die lokale Dev-Origin enthalten.
    post_logout="https://www.${ADDON_DOMAIN}/##https://dev.${ADDON_DOMAIN}/##https://f-de1.${ADDON_DOMAIN}/##https://f-de2.${ADDON_DOMAIN}/##https://f-fv.${ADDON_DOMAIN}/##${ADDON_IAM_DEV_ORIGIN}/"
    web_origins=$(jq -nc \
      --arg main "https://www.${ADDON_DOMAIN}" \
      --arg dev "https://dev.${ADDON_DOMAIN}" \
      --arg de1 "https://f-de1.${ADDON_DOMAIN}" \
      --arg de2 "https://f-de2.${ADDON_DOMAIN}" \
      --arg fv "https://f-fv.${ADDON_DOMAIN}" \
      --arg devlocal "${ADDON_IAM_DEV_ORIGIN}" \
      '[$main,$dev,$de1,$de2,$fv,$devlocal]')
    payload=$(jq -nc \
      --arg clientId "${ADDON_IAM_CLIENT_ID}" \
      --argjson redirectUris "${redirects}" \
      --argjson webOrigins "${web_origins}" \
      --arg postLogout "${post_logout}" \
      '{clientId:$clientId,enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,redirectUris:$redirectUris,webOrigins:$webOrigins,attributes:{"post.logout.redirect.uris":$postLogout}}')

    create_resp=$(curl -sk --max-time 15 -w $'\n%{http_code}' \
      -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${payload}" 2>/dev/null || true)
    create_code=$(printf '%s' "${create_resp}" | tail -1)
    create_body=$(printf '%s' "${create_resp}" | sed '$d')
    if [[ "${create_code}" == "201" ]]; then
      log_ok "OIDC-Client ${ADDON_IAM_CLIENT_ID} angelegt"
      client_uid=$(_iam_get_client_uid "${token}")
    else
      log_warn "OIDC-Client anlegen fehlgeschlagen (HTTP ${create_code}): ${create_body}"
    fi
  fi

  # Client-Secret auslesen und in Credentials-Datei ablegen (chmod 600).
  if [[ -n "${client_uid}" ]]; then
    local secret
    secret=$(curl -sk --max-time 15 \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/client-secret" \
      -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.value // empty' 2>/dev/null || true)
    if [[ -n "${secret}" ]]; then
      umask 077
      # Elternverzeichnis existiert u. U. nicht (Default /root/civitas-install) —
      # sicher anlegen statt still zu scheitern (Turn 8, Robustheitsfix).
      mkdir -p "$(dirname "${ADDON_IAM_CREDENTIALS_FILE}")" \
        || { log_error "Credentials-Verzeichnis konnte nicht angelegt werden: $(dirname "${ADDON_IAM_CREDENTIALS_FILE}")"; return 1; }
      {
        echo "# p2d2-AddOn Keycloak-Client (generiert)"
        echo "P2D2_BASE_OIDC_CLIENT_ID=${ADDON_IAM_CLIENT_ID}"
        echo "P2D2_BASE_OIDC_CLIENT_SECRET=${secret}"
      } > "${ADDON_IAM_CREDENTIALS_FILE}" \
        || { log_error "Credentials-Datei konnte nicht geschrieben werden: ${ADDON_IAM_CREDENTIALS_FILE}"; return 1; }
      log_ok "Client-Secret nach ${ADDON_IAM_CREDENTIALS_FILE} geschrieben (chmod 600)"
    else
      log_warn "Client-Secret nicht auslesbar — manuell pruefen"
    fi
  fi
}

# ── 2. Client-Rollen ───────────────────────────────────────────────────────────
ensure_p2d2_client_roles() {
  log "=== AddOn 25: Keycloak Client-Rollen (6) ==="
  local token client_uid roles_json
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}")
  if [[ -z "${client_uid}" ]]; then
    log_error "OIDC-Client ${ADDON_IAM_CLIENT_ID} nicht gefunden — zuerst ensure_p2d2_oidc_client"
    return 1
  fi

  roles_json=$(curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/roles" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")

  local role
  for role in editor export_admin qs1_reviewer qs2_reviewer osm verwaltung; do
    if printf '%s' "${roles_json}" | jq -e ".[] | select(.name==\"${role}\")" >/dev/null 2>&1; then
      log_ok "Rolle ${role} existiert bereits"
      continue
    fi
    local http_code
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
      -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/roles" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${role}\"}" 2>/dev/null || true)
    if [[ "${http_code}" == "201" ]]; then
      log_ok "Rolle ${role} angelegt"
    else
      log_warn "Rolle ${role} anlegen fehlgeschlagen (HTTP ${http_code})"
    fi
  done
}

# ── 3. Rollen-Token-Mapper (resource_access.<client_id>.roles im ID- + Access-Token) ──
ensure_p2d2_role_token_mapper() {
  log "=== AddOn 25: Rollen-Token-Mapper (ID-Token) ==="
  local token client_uid mappers_json
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}")
  if [[ -z "${client_uid}" ]]; then
    log_error "OIDC-Client ${ADDON_IAM_CLIENT_ID} nicht gefunden"
    return 1
  fi

  mappers_json=$(curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/protocol-mappers/models" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")

  # Keycloak legt Client-Rollen standardmaessig unter resource_access.<client_id>.roles ab.
  # Entscheidend (Turn 39): der Mapper muss auch in den ID-Token schreiben, da callback.ts
  # ausschliesslich das ID-Token dekodiert.
  if printf '%s' "${mappers_json}" | jq -e '.[] | select(.name=="client roles")' >/dev/null 2>&1; then
    log_ok "Rollen-Mapper 'client roles' existiert bereits"
    # TODO(verify): sicherstellen, dass "Add to ID token" aktiv ist (ggf. PUT auf den Mapper).
  else
    local http_code
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
      -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/protocol-mappers/models" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"client roles\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-client-role-mapper\",\"config\":{\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"resource_access.${ADDON_IAM_CLIENT_ID}.roles\",\"multivalued\":\"true\",\"usermodel.clientRoleMapping.clientId\":\"${ADDON_IAM_CLIENT_ID}\"}}" 2>/dev/null || true)
    if [[ "${http_code}" == "201" ]]; then
      log_ok "Rollen-Mapper 'client roles' angelegt (ID- + Access-Token)"
    else
      log_warn "Rollen-Mapper anlegen fehlgeschlagen (HTTP ${http_code}) — manuell pruefen"
    fi
  fi
}

# ── 3b. User-Profile-Definitionen (p2d2-Metadaten, Zitadel-kompatibel) ────────
# Ergänzt die zwei verwalteten Attribute im Realm-User-Profile, ohne bestehende
# Definitionen zu überschreiben oder unmanaged attributes global freizuschalten.
ensure_metadata_profile() {
  log "=== AddOn 25: User-Profile-Definitionen (p2d2-Metadaten) ==="
  local token
  token=$(_iam_get_token) || return 1
  local profile_url="${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/profile"

  local def_memberships def_home
  def_memberships=$(jq -nc '{name:"p2d2.memberships",displayName:"p2d2 memberships (JSON)",permissions:{view:["admin"],edit:["admin"]},multivalued:false,validations:{length:{max:4096}}}')
  def_home=$(jq -nc '{name:"p2d2.preferences.home_region_key",displayName:"Bevorzugte p2d2-Startregion",permissions:{view:["admin","user"],edit:["admin","user"]},multivalued:false,validations:{length:{max:200}}}')

  _iam_req "${token}" GET "${profile_url}"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "User-Profile-Konfiguration nicht lesbar (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  local profile_json="${IAM_HTTP_BODY}"

  local changed=false def name
  for def in "${def_memberships}" "${def_home}"; do
    name="$(printf '%s' "${def}" | jq -r '.name')"
    if ! printf '%s' "${profile_json}" | jq -e ".attributes[] | select(.name==\"${name}\")" >/dev/null 2>&1; then
      profile_json="$(printf '%s' "${profile_json}" | jq -c --argjson d "${def}" '.attributes += [$d]')"
      changed=true
      continue
    fi
    # Vorhanden: sicherheitsrelevante Abweichung fail-closed. p2d2.memberships darf
    # NICHT user-editierbar sein; sonst koennte ein Endnutzer seine Zuordnungen fälschen.
    if [[ "${name}" == "p2d2.memberships" ]] \
       && printf '%s' "${profile_json}" | jq -e ".attributes[] | select(.name==\"${name}\") | .permissions.edit | index(\"user\")" >/dev/null 2>&1; then
      log_error "User-Profile '${name}' erlaubt User-Edits (Sicherheitsabweichung) — nicht automatisch überschreiben"
      return 1
    fi
    log_ok "User-Profile '${name}' existiert bereits"
  done

  if [[ "${changed}" == "true" ]]; then
    _iam_req "${token}" PUT "${profile_url}" "${profile_json}"
    if [[ "${IAM_HTTP_CODE}" != "200" && "${IAM_HTTP_CODE}" != "204" ]]; then
      log_error "User-Profile-Konfiguration aktualisieren fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
      return 1
    fi
    # Read-back: beide verwalteten Namen muessen vorhanden sein.
    _iam_req "${token}" GET "${profile_url}"
    if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
      log_error "User-Profile Read-back fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
      return 1
    fi
  fi
  log_ok "User-Profile-Definitionen sichergestellt"
}

# ── 3c. Metadaten-Protocol-Mapper am Client ───────────────────────────────────
# Zwei oidc-usermodel-attribute-mapper, die die Attribute in das verschachtelte
# Claim user_metadata.p2d2.* schreiben (ausschliesslich ins ID-Token).
_iam_ensure_client_mapper() {
  local token="$1" client_uid="$2" name="$3" attr="$4" claim="$5"
  local base_url="${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/protocol-mappers/models"

  _iam_req "${token}" GET "${base_url}"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "Protocol-Mapper nicht lesbar (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  local mappers_json="${IAM_HTTP_BODY}"

  local payload
  payload=$(jq -nc \
    --arg name "${name}" --arg attr "${attr}" --arg claim "${claim}" \
    '{name:$name,protocol:"openid-connect",protocolMapper:"oidc-usermodel-attribute-mapper",consentRequired:false,config:{"jsonType.label":"String",multivalued:"false","aggregate.attrs":"false","id.token.claim":"true","access.token.claim":"false","userinfo.token.claim":"false","user.attribute":$attr,"claim.name":$claim}}')

  # Konflikte: fremder Typ bei gleichem Namen, Duplikat, konkurrierendes Claim-Ziel.
  if printf '%s' "${mappers_json}" | jq -e ".[] | select(.name==\"${name}\" and .protocolMapper!=\"oidc-usermodel-attribute-mapper\")" >/dev/null 2>&1; then
    log_error "Mapper '${name}' existiert mit anderem Typ — nicht überschreiben"
    return 1
  fi
  if printf '%s' "${mappers_json}" | jq -e ".[] | select(.name!=\"${name}\" and .config[\"claim.name\"]==\"${claim}\")" >/dev/null 2>&1; then
    log_error "Claim '${claim}' wird bereits von einem anderen Mapper belegt"
    return 1
  fi
  if (( $(printf '%s' "${mappers_json}" | jq '[.[] | select(.name=="'"${name}"'")] | length') > 1 )); then
    log_error "Mehrere Mapper mit Name '${name}' — bitte manuell bereinigen"
    return 1
  fi

  local existing
  existing=$(printf '%s' "${mappers_json}" | jq -c ".[] | select(.name==\"${name}\")" 2>/dev/null || true)

  if [[ -n "${existing}" ]]; then
    local managed_ok
    managed_ok=$(printf '%s' "${existing}" | jq -r \
      --arg attr "${attr}" --arg claim "${claim}" \
      'if (.protocolMapper=="oidc-usermodel-attribute-mapper" and .config["user.attribute"]==$attr and .config["claim.name"]==$claim and .config["id.token.claim"]=="true") then "ok" else "drift" end')
    if [[ "${managed_ok}" == "ok" ]]; then
      log_ok "Mapper '${name}' existiert bereits korrekt"
      return 0
    fi
    # Drift: nur die verwalteten Felder angleichen, fremde Felder erhalten.
    local mapper_id merged
    mapper_id=$(printf '%s' "${existing}" | jq -r '.id')
    merged=$(printf '%s' "${existing}" | jq -c --argjson p "${payload}" '.protocolMapper = $p.protocolMapper | .consentRequired = $p.consentRequired | .config = (.config * $p.config)')
    _iam_req "${token}" PUT "${base_url}/${mapper_id}" "${merged}"
    if [[ "${IAM_HTTP_CODE}" != "200" && "${IAM_HTTP_CODE}" != "204" ]]; then
      log_error "Mapper '${name}' aktualisieren fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
      return 1
    fi
  else
    _iam_req "${token}" POST "${base_url}" "${payload}"
    if [[ "${IAM_HTTP_CODE}" != "201" && "${IAM_HTTP_CODE}" != "200" ]]; then
      log_error "Mapper '${name}' anlegen fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
      return 1
    fi
  fi

  # Read-back der verwalteten Felder.
  _iam_req "${token}" GET "${base_url}"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "Mapper Read-back fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  if ! printf '%s' "${IAM_HTTP_BODY}" | jq -e ".[] | select(.name==\"${name}\" and .config[\"user.attribute\"]==\"${attr}\" and .config[\"claim.name\"]==\"${claim}\" and .config[\"id.token.claim\"]==\"true\")" >/dev/null 2>&1; then
    log_error "Mapper Read-back '${name}' entspricht nicht den verwalteten Feldern"
    return 1
  fi
  log_ok "Mapper '${name}' sichergestellt"
}

ensure_metadata_mappers() {
  log "=== AddOn 25: Metadaten-Protocol-Mapper (2) ==="
  local token client_uid
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}")
  if [[ -z "${client_uid}" ]]; then
    log_error "OIDC-Client ${ADDON_IAM_CLIENT_ID} nicht gefunden"
    return 1
  fi
  _iam_ensure_client_mapper "${token}" "${client_uid}" "p2d2 memberships" "p2d2.memberships" "user_metadata.p2d2.memberships" || return 1
  _iam_ensure_client_mapper "${token}" "${client_uid}" "p2d2 home region" "p2d2.preferences.home_region_key" "user_metadata.p2d2.preferences.home_region_key" || return 1
}

# ── Helfer: IdP-Mapper idempotent anlegen ───────────────────────────────────────
_iam_ensure_idp_mapper() {
  local token="$1" alias="$2" name="$3" payload="$4"
  local mappers_json
  mappers_json=$(curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances/${alias}/mappers" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")
  if printf '%s' "${mappers_json}" | jq -e ".[] | select(.name==\"${name}\")" >/dev/null 2>&1; then
    log_ok "IdP-Mapper ${name} existiert bereits"
    return 0
  fi
  local http_code
  http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances/${alias}/mappers" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null || true)
  if [[ "${http_code}" == "201" ]]; then
    log_ok "IdP-Mapper ${name} angelegt"
  else
    log_warn "IdP-Mapper ${name} anlegen fehlgeschlagen (HTTP ${http_code}) — Mapper-Typ/Feldnamen gegen Keycloak-Version pruefen"
  fi
}

# ── 4. OSM-IdP-Broker ──────────────────────────────────────────────────────────
ensure_osm_identity_provider() {
  log "=== AddOn 25: OSM-IdP-Broker (Alias osm) ==="
  local token
  token=$(_iam_get_token) || return 1

  local osm_client_id osm_client_secret
  osm_client_id="${P2D2_OSM_IDP_CLIENT_ID:-}"
  osm_client_secret="${P2D2_OSM_IDP_CLIENT_SECRET:-}"
  if [[ -z "${osm_client_id}" || -z "${osm_client_secret}" ]]; then
    log_error "P2D2_OSM_IDP_CLIENT_ID / P2D2_OSM_IDP_CLIENT_SECRET nicht gesetzt — OSM-IdP wird NICHT eingerichtet"
    return 1
  fi

  local http_code
  http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances/osm" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)
  if [[ "${http_code}" == "200" ]]; then
    log_ok "OSM-IdP (osm) existiert bereits"
  else
    # OSM ist reines OAuth2 (kein OIDC). Userinfo als JSON: /api/0.6/user/details.json
    # (liefert user.id / user.display_name, kein Standard sub/email -> Mapper noetig, s.u.).
    local payload
    payload=$(jq -nc \
      --arg alias "osm" \
      --arg clientId "${osm_client_id}" \
      --arg clientSecret "${osm_client_secret}" \
      '{alias:$alias,providerId:"oauth2",enabled:true,storeToken:false,addReadTokenRoleOnCreate:false,config:{
        clientId:$clientId,clientSecret:$clientSecret,
        authorizationUrl:"https://www.openstreetmap.org/oauth2/authorize",
        tokenUrl:"https://www.openstreetmap.org/oauth2/token",
        userInfoUrl:"https://api.openstreetmap.org/api/0.6/user/details.json",
        defaultScope:"read_prefs"}}')
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
      -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${payload}" 2>/dev/null || true)
    if [[ "${http_code}" == "201" ]]; then
      log_ok "OSM-IdP (osm) angelegt"
    else
      log_warn "OSM-IdP anlegen fehlgeschlagen (HTTP ${http_code})"
      return 1
    fi
  fi

  # Mapper: eindeutige Kennung user.id (Username-Template) + Anzeigename user.display_name
  # (Attribute-Importer). Punktnotation auf verschachteltes user.* (OSM-Userinfo).
  local username_payload display_payload
  username_payload=$(jq -nc --arg name "OSM username" --arg tpl '${CLAIM.user.id}' \
    '{name:$name,identityProviderMapper:"oidc-username-idp-mapper",identityProviderAlias:"osm",config:{template:$tpl}}')
  display_payload=$(jq -nc --arg name "OSM display_name" --arg claim "user.display_name" --arg attr "displayName" \
    '{name:$name,identityProviderMapper:"oidc-user-attribute-idp-mapper",identityProviderAlias:"osm",config:{claim:$claim,"user.attribute":$attr,jsonType:"String",syncMode:"INHERIT"}}')
  _iam_ensure_idp_mapper "${token}" "osm" "OSM username" "${username_payload}"
  _iam_ensure_idp_mapper "${token}" "osm" "OSM display_name" "${display_payload}"
}

# ── 5. Demo-Accounts ───────────────────────────────────────────────────────────
ensure_p2d2_demo_accounts() {
  log "=== AddOn 25: Demo-Accounts (6) ==="
  local token client_uid demo_pass
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}")

  demo_pass="${P2D2_DEMO_PASSWORD:-}"
  if [[ -z "${demo_pass}" ]]; then
    log_error "P2D2_DEMO_PASSWORD nicht gesetzt — Demo-Accounts koennen kein Passwort erhalten"
    return 1
  fi

  # Mindestkriterium vorab pruefen, damit ein Policy-Verstoss (z. B. fehlender
  # Grossbuchstabe) nicht erst still beim reset-password auffaellt.
  if [[ ${#demo_pass} -lt 8 ]] \
     || [[ ! "${demo_pass}" =~ [A-Z] ]] \
     || [[ ! "${demo_pass}" =~ [a-z] ]] \
     || [[ ! "${demo_pass}" =~ [0-9] ]]; then
    log_error "P2D2_DEMO_PASSWORD erfuellt die Mindestanforderungen nicht (>= 8 Zeichen, Gross-/Kleinbuchstabe, Ziffer)"
    return 1
  fi

  local entry username email first_name last_name roles email_enc user_id
  for entry in "${ADDON_IAM_DEMO_USERS[@]}"; do
    IFS='|' read -r username email first_name last_name roles <<< "${entry}"
    # Realm erzwingt "E-Mail als Username" -> der stabile Lookup-Schluessel ist die
    # E-Mail (nicht der Kurzname aus dem Array). @uri-codiert, damit '@' sauber bleibt.
    email_enc=$(jq -rn --arg e "${email}" '$e|@uri')

    user_id=$(curl -sk --max-time 15 \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.[0].id // empty')

    if [[ -z "${user_id}" ]]; then
      local create_payload create_resp create_body create_code
      # emailVerified=true + requiredActions=[] + Vor-/Nachname direkt beim Anlegen,
      # damit der erste Login ohne E-Mail-Verifikation und ohne Profil-Ergaenzung klappt.
      create_payload=$(jq -nc --arg u "${username}" --arg e "${email}" \
        --arg fn "${first_name}" --arg ln "${last_name}" \
        '{username:$u,email:$e,enabled:true,emailVerified:true,requiredActions:[],firstName:$fn,lastName:$ln}')
      create_resp=$(curl -sk --max-time 15 -w $'\n%{http_code}' \
        -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${create_payload}" 2>/dev/null || true)
      create_code=$(printf '%s' "${create_resp}" | tail -1)
      create_body=$(printf '%s' "${create_resp}" | sed '$d')
      if [[ "${create_code}" != "201" ]]; then
        log_warn "User ${username} anlegen fehlgeschlagen (HTTP ${create_code} — $(_iam_http_hint "${create_code}")): ${create_body}"
      fi
      user_id=$(curl -sk --max-time 15 \
        "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" \
        -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.[0].id // empty')
    fi

    if [[ -z "${user_id}" ]]; then
      log_warn "User ${username} konnte nicht angelegt/gefunden werden"
      continue
    fi

    # Profil idempotent sicherstellen (auch fuer bereits existierende Accounts, damit
    # frueher angelegte mit emailVerified=false auf den korrekten Zustand konvergieren).
    local profile_payload profile_code
    profile_payload=$(jq -nc --arg fn "${first_name}" --arg ln "${last_name}" \
      '{emailVerified:true,requiredActions:[],firstName:$fn,lastName:$ln}')
    profile_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
      -X PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${profile_payload}" 2>/dev/null || true)
    if [[ "${profile_code}" != "204" && "${profile_code}" != "200" ]]; then
      log_warn "Profil (${username}) aktualisieren fehlgeschlagen (HTTP ${profile_code})"
    fi

    # Passwort setzen (nicht temporaer). JSON via jq, damit Sonderzeichen im Passwort
    # korrekt escaped werden (nicht roh in -d interpolieren).
    local pw_payload pw_resp pw_code pw_body
    pw_payload=$(jq -nc --arg pw "${demo_pass}" '{type:"password",value:$pw,temporary:false}')
    pw_resp=$(curl -sk --max-time 15 -w $'\n%{http_code}' \
      -X PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}/reset-password" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${pw_payload}" 2>/dev/null || true)
    pw_code=$(printf '%s' "${pw_resp}" | tail -1)
    pw_body=$(printf '%s' "${pw_resp}" | sed '$d')
    if [[ "${pw_code}" != "204" && "${pw_code}" != "200" ]]; then
      if [[ "${pw_body}" == *invalidPasswordHistoryMessage* ]]; then
        log_ok "Passwort (${username}) unveraendert (bereits gesetzt, Passwort-Historie)"
      else
        log_warn "Passwort setzen (${username}) fehlgeschlagen (HTTP ${pw_code} — $(_iam_http_hint "${pw_code}")): ${pw_body}"
      fi
    fi

    # Client-Rollen zuweisen (idempotent).
    if [[ -n "${client_uid}" ]]; then
      local role_payload role_id
      role_payload="[]"
      for role in ${roles}; do
        role_id=$(curl -sk --max-time 15 \
          "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/roles/${role}" \
          -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.id // empty')
        if [[ -n "${role_id}" ]]; then
          role_payload=$(printf '%s' "${role_payload}" | jq -c --arg id "${role_id}" --arg name "${role}" '. + [{"id":$id,"name":$name}]')
        fi
      done
      curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
        -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}/role-mappings/clients/${client_uid}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${role_payload}" >/dev/null 2>&1 || true
    fi

    log_ok "Demo-User ${username} (id ${user_id}) — Rollen: ${roles}"
  done

  # Jule-Metadaten seeden (nachdem Jule sicher existiert); nur fehlende Werte.
  seed_jule_metadata "${token}"
}

# ── 5b. Demo-Metadaten fuer Jule (nur seeden, nie überschreiben) ──────────────
seed_jule_metadata() {
  local token="$1"
  local jule_email="jule.kovalenko@nospam.scanea.de"
  local email_enc
  email_enc=$(jq -rn --arg e "${jule_email}" '$e|@uri')

  # Exakt einen Benutzer aufloesen; 0/mehrere Treffer sind ein Fehler.
  _iam_req "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "Jule-Lookup fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  local user_count user_id
  user_count=$(printf '%s' "${IAM_HTTP_BODY}" | jq 'length')
  if [[ "${user_count}" != "1" ]]; then
    log_error "Jule-Lookup erwartete genau 1 Treffer, fand ${user_count}"
    return 1
  fi
  user_id=$(printf '%s' "${IAM_HTTP_BODY}" | jq -r '.[0].id')

  _iam_req "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "Jule-Benutzer nicht lesbar (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  local user_json="${IAM_HTTP_BODY}"

  # Kanonische Seed-Werte (jeweils Attribut = Liste mit EINEM String).
  local memberships_array memberships_seed home_seed
  memberships_array='[{"type":"kommune","key":"koeln","role":"verwaltung","wp_name":"de-Köln"},{"type":"community","key":"osm","role":"osm"}]'
  memberships_seed=$(jq -nc --argjson arr "${memberships_array}" '[$arr|tojson]')
  home_seed=$(jq -nc '["de-Bonn"]')

  local memberships_present home_present
  memberships_present=$(printf '%s' "${user_json}" | jq -r 'if (.attributes // {}) | has("p2d2.memberships") then "yes" else "no" end')
  home_present=$(printf '%s' "${user_json}" | jq -r 'if (.attributes // {}) | has("p2d2.preferences.home_region_key") then "yes" else "no" end')

  # Vorhandene Werte nie ueberschreiben (insbesondere die vom Benutzer geaenderte
  # Startregion). Nur wirklich fehlende Schluessel initialisieren.
  local delta="{}"
  if [[ "${memberships_present}" == "no" ]]; then
    delta=$(printf '%s' "${delta}" | jq -c --argjson m "${memberships_seed}" '. + {"p2d2.memberships": $m}')
  else
    local cur
    cur=$(printf '%s' "${user_json}" | jq -c '.attributes["p2d2.memberships"]')
    if [[ "${cur}" == "${memberships_seed}" ]]; then
      log_ok "Jule: p2d2.memberships bereits korrekt"
    else
      log_warn "Jule: p2d2.memberships vorhanden (abweichend/leer) — nicht automatisch überschrieben"
    fi
  fi
  if [[ "${home_present}" == "no" ]]; then
    delta=$(printf '%s' "${delta}" | jq -c --argjson h "${home_seed}" '. + {"p2d2.preferences.home_region_key": $h}')
  else
    local cur
    cur=$(printf '%s' "${user_json}" | jq -c '.attributes["p2d2.preferences.home_region_key"]')
    if [[ "${cur}" == "${home_seed}" ]]; then
      log_ok "Jule: p2d2.preferences.home_region_key bereits korrekt"
    else
      log_warn "Jule: p2d2.preferences.home_region_key vorhanden (abweichend) — nicht automatisch überschrieben"
    fi
  fi

  if [[ "${delta}" == "{}" ]]; then
    return 0
  fi

  local merged
  merged=$(printf '%s' "${user_json}" | jq -c --argjson d "${delta}" '.attributes = ((.attributes // {}) + $d)')
  _iam_req "${token}" PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" "${merged}"
  if [[ "${IAM_HTTP_CODE}" != "200" && "${IAM_HTTP_CODE}" != "204" ]]; then
    log_error "Jule-Metadaten schreiben fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi

  # Read-back.
  _iam_req "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}"
  if [[ "${IAM_HTTP_CODE}" != "200" ]]; then
    log_error "Jule-Metadaten Read-back fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"
    return 1
  fi
  log_ok "Jule-Metadaten gesetzt (memberships + home_region_key)"
}

# ── Orchestrierung ─────────────────────────────────────────────────────────────
install_addon_iam() {
  log "=== AddOn 25: IAM/Keycloak-Provisionierung ==="
  ensure_p2d2_oidc_client
  ensure_p2d2_client_roles
  ensure_p2d2_role_token_mapper
  ensure_metadata_profile
  ensure_metadata_mappers
  ensure_osm_identity_provider
  ensure_p2d2_demo_accounts
  log_ok "AddOn 25 IAM abgeschlossen"
}

# uninstall_addon_iam — Rückbau (Turn 65): entfernt die vom AddOn angelegten
# Keycloak-Realm-Objekte. Umgekehrte Reihenfolge zur Install-Seite:
#   Demo-User (Rollen-Grants hängen an den Usern) → OSM-IdP-Broker (inkl. IdP-Mapper)
#   → OIDC-Client p2d2 (entfernt Client-Rollen + Token-Mapper mit).
# Die realmweiten User-Profile-Definitionen (p2d2.memberships,
# p2d2.preferences.home_region_key) werden bewusst NICHT gelöscht — andere
# Nutzer/Clients im Realm können sie verwenden.
# Es existieren KEINE Realm-Groups (das AddOn legt keine an) — nichts zu entfernen.
uninstall_addon_iam() {
  log "=== Uninstall AddOn 25: IAM/Keycloak-Rückbau ==="
  local token client_uid http_code
  token=$(_iam_get_token) || return 1

  # 1) Demo-Accounts (6) — Lookup per E-Mail (Realm erzwingt E-Mail-als-Username).
  local entry username email email_enc user_id
  for entry in "${ADDON_IAM_DEMO_USERS[@]}"; do
    IFS='|' read -r username email _ _ _ <<< "${entry}"
    email_enc=$(jq -rn --arg e "${email}" '$e|@uri')
    user_id=$(curl -sk --max-time 15 \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.[0].id // empty')
    if [[ -z "${user_id}" ]]; then
      log_ok "Demo-User ${email} nicht vorhanden — übersprungen"
      continue
    fi
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" -X DELETE \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)
    if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
      log_ok "Demo-User ${email} gelöscht"
    else
      log_warn "Demo-User ${email} löschen fehlgeschlagen (HTTP ${http_code} — $(_iam_http_hint "${http_code}"))"
    fi
  done

  # 2) OSM-IdP-Broker osm (entfernt zugehörige IdP-Mapper mit).
  http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances/osm" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)
  if [[ "${http_code}" == "200" ]]; then
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" -X DELETE \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/identity-provider/instances/osm" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)
    if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
      log_ok "OSM-IdP-Broker osm gelöscht"
    else
      log_warn "OSM-IdP-Broker osm löschen fehlgeschlagen (HTTP ${http_code})"
    fi
  else
    log_ok "OSM-IdP-Broker osm nicht vorhanden — übersprungen"
  fi

  # 3) OIDC-Client p2d2 (entfernt Client-Rollen + Token-Mapper mit).
  client_uid=$(_iam_get_client_uid "${token}")
  if [[ -n "${client_uid}" ]]; then
    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" -X DELETE \
      "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)
    if [[ "${http_code}" == "204" || "${http_code}" == "200" ]]; then
      log_ok "OIDC-Client ${ADDON_IAM_CLIENT_ID} gelöscht"
    else
      log_warn "OIDC-Client ${ADDON_IAM_CLIENT_ID} löschen fehlgeschlagen (HTTP ${http_code})"
    fi
  else
    log_ok "OIDC-Client ${ADDON_IAM_CLIENT_ID} nicht vorhanden — übersprungen"
  fi

  # 4) Generierte Credentials-Datei (Client-Secret) entfernen — wird beim Reinstall neu erzeugt.
  if [[ -f "${ADDON_IAM_CREDENTIALS_FILE}" ]]; then
    rm -f "${ADDON_IAM_CREDENTIALS_FILE}" \
      && log_ok "Credentials-Datei ${ADDON_IAM_CREDENTIALS_FILE} entfernt" \
      || log_warn "Credentials-Datei ${ADDON_IAM_CREDENTIALS_FILE} konnte nicht entfernt werden"
  fi

  log_ok "Uninstall AddOn 25 IAM abgeschlossen"
}

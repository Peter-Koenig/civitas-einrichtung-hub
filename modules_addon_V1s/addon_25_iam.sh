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

# ── 1. OIDC-Client ─────────────────────────────────────────────────────────────
ensure_p2d2_oidc_client() {
  log "=== AddOn 25: Keycloak OIDC-Client ${ADDON_IAM_CLIENT_ID} (Realm ${ADDON_IAM_REALM}) ==="
  local token client_id_json client_uid http_code
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
    post_logout="https://www.${ADDON_DOMAIN}/ https://dev.${ADDON_DOMAIN}/ https://f-de1.${ADDON_DOMAIN}/ https://f-de2.${ADDON_DOMAIN}/ https://f-fv.${ADDON_DOMAIN}/"
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

    http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
      -X POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${payload}" 2>/dev/null || true)
    if [[ "${http_code}" == "201" ]]; then
      log_ok "OIDC-Client ${ADDON_IAM_CLIENT_ID} angelegt"
      client_uid=$(_iam_get_client_uid "${token}")
    else
      log_warn "OIDC-Client anlegen fehlgeschlagen (HTTP ${http_code})"
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
      {
        echo "# p2d2-AddOn Keycloak-Client (generiert)"
        echo "P2D2_BASE_OIDC_CLIENT_ID=${ADDON_IAM_CLIENT_ID}"
        echo "P2D2_BASE_OIDC_CLIENT_SECRET=${secret}"
      } > "${ADDON_IAM_CREDENTIALS_FILE}"
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
}

# ── Orchestrierung ─────────────────────────────────────────────────────────────
install_addon_iam() {
  log "=== AddOn 25: IAM/Keycloak-Provisionierung ==="
  ensure_p2d2_oidc_client
  ensure_p2d2_client_roles
  ensure_p2d2_role_token_mapper
  ensure_osm_identity_provider
  ensure_p2d2_demo_accounts
  log_ok "AddOn 25 IAM abgeschlossen"
}

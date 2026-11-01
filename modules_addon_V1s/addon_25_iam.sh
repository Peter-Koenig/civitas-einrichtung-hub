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

# Gemeinsame Client-Rollen (eine Quelle für ensure_p2d2_client_roles und die
# Demo-Account-Validierung). Demo-Accounts selbst kommen aus supplement/demo-accounts.md.
ADDON_IAM_CLIENT_ROLES=(editor export_admin qs1_reviewer qs2_reviewer osm verwaltung)

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
# 0 Treffer -> leer (Aufrufer meldet "nicht gefunden"); mehr als 1 -> Fehler.
_iam_get_client_uid() {
  local token="$1"
  local count
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients" || return 2
  _iam_body_is 'type=="array"' || { log_error "OIDC-Client-Liste: unerwartete JSON-Form"; return 2; }
  count=$(printf '%s' "${IAM_HTTP_BODY}" | jq "[.[] | select(.clientId==\"${ADDON_IAM_CLIENT_ID}\")] | length" 2>/dev/null || echo 0)
  if [[ "${count}" == "0" ]]; then
    return 0
  fi
  if [[ "${count}" != "1" ]]; then
    log_error "OIDC-Client ${ADDON_IAM_CLIENT_ID} mehrdeutig (${count} Treffer)"
    return 1
  fi
  printf '%s' "${IAM_HTTP_BODY}" | jq -r ".[] | select(.clientId==\"${ADDON_IAM_CLIENT_ID}\") | .id" 2>/dev/null
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

# Antwortpruefung: Statuscode in der erlaubten Menge; Transportfehler unterscheiden.
# $1=Token, $2=Method, $3=URL, $4=optionaler Body, $5=erlaubte Codes (Default "200").
_iam_call() {
  local ok="${5:-200}"
  _iam_req "$1" "$2" "$3" "${4:-}"
  if ! [[ "${IAM_HTTP_CODE}" =~ ^[0-9]{3}$ ]]; then
    log_error "${2}: Transportfehler (kein HTTP-Status)"
    return 1
  fi
  case " ${ok} " in
    *" ${IAM_HTTP_CODE} "*) return 0 ;;
  esac
  log_error "${2}: unerwarteter HTTP-Status ${IAM_HTTP_CODE}"
  return 1
}

# Formpruefung der letzten Antwort per jq-Ausdruck; ungueltiges JSON = nicht erfuellt.
_iam_body_is() {
  printf '%s' "${IAM_HTTP_BODY}" | jq -e "$1" >/dev/null 2>&1
}

# ── 1. OIDC-Client ─────────────────────────────────────────────────────────────
ensure_p2d2_oidc_client() {
  log "=== AddOn 25: Keycloak OIDC-Client ${ADDON_IAM_CLIENT_ID} (Realm ${ADDON_IAM_REALM}) ==="
  local token client_id_json client_uid http_code create_resp create_code create_body
  token=$(_iam_get_token) || return 1

  client_uid=$(_iam_get_client_uid "${token}") || return 1

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
      client_uid=$(_iam_get_client_uid "${token}") || return 1
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
  client_uid=$(_iam_get_client_uid "${token}") || return 1
  if [[ -z "${client_uid}" ]]; then
    log_error "OIDC-Client ${ADDON_IAM_CLIENT_ID} nicht gefunden — zuerst ensure_p2d2_oidc_client"
    return 1
  fi

  roles_json=$(curl -sk --max-time 15 \
    "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/roles" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")

  local role
  for role in "${ADDON_IAM_CLIENT_ROLES[@]}"; do
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
  client_uid=$(_iam_get_client_uid "${token}") || return 1
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
# Prueft eine vorhandene Profil-Definition gegen den Sollwert (Mengenvergleich fuer Rechte,
# multivalued und validations.length.max). Genau eine Definition pro Name.
_iam_profile_def_conforms() {
  jq -e --argjson want "$2" '
    def same_set(a; b): ((a // []) | sort) == ((b // []) | sort);
    [.attributes[] | select(.name == $want.name)] as $m
    | ($m | length) == 1
      and ($m[0] | same_set(.permissions.view; $want.permissions.view)
                and same_set(.permissions.edit; $want.permissions.edit)
                and ((.multivalued // false) == $want.multivalued)
                and (.validations.length.max == $want.validations.length.max))
  ' <<<"$1" >/dev/null 2>&1
}

ensure_metadata_profile() {
  log "=== AddOn 25: User-Profile-Definitionen (p2d2-Metadaten) ==="
  local token
  token=$(_iam_get_token) || return 1
  local profile_url="${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/profile"

  local def_memberships def_home
  def_memberships=$(jq -nc '{name:"p2d2.memberships",displayName:"p2d2 memberships (JSON)",permissions:{view:["admin"],edit:["admin"]},multivalued:false,validations:{length:{max:4096}}}')
  def_home=$(jq -nc '{name:"p2d2.preferences.home_region_key",displayName:"Bevorzugte p2d2-Startregion",permissions:{view:["admin","user"],edit:["admin","user"]},multivalued:false,validations:{length:{max:200}}}')

  _iam_call "${token}" GET "${profile_url}" || return 1
  _iam_body_is 'type=="object" and (.attributes|type)=="array"' \
    || { log_error "User-Profile: unerwartete JSON-Form"; return 1; }
  local before="${IAM_HTTP_BODY}"

  local to_add="[]" def name count
  for def in "${def_memberships}" "${def_home}"; do
    name="$(printf '%s' "${def}" | jq -r '.name')"
    count=$(printf '%s' "${before}" | jq '[.attributes[] | select(.name == $name)] | length' --arg name "${name}")
    if (( count > 1 )); then
      log_error "User-Profile '${name}' ist doppelt definiert"
      return 1
    fi
    if (( count == 0 )); then
      to_add="$(printf '%s' "${to_add}" | jq -c --argjson d "${def}" '. + [$d]')"
      continue
    fi
    # Vorhanden: unsichere Membership-Edits fail-closed (User darf memberships nicht editieren).
    if [[ "${name}" == "p2d2.memberships" ]] \
       && printf '%s' "${before}" | jq -e ".attributes[] | select(.name==\"${name}\") | .permissions.edit | index(\"user\")" >/dev/null 2>&1; then
      log_error "User-Profile '${name}' erlaubt User-Edits (Sicherheitsabweichung) — nicht automatisch überschreiben"
      return 1
    fi
    if _iam_profile_def_conforms "${before}" "${def}"; then
      log_ok "User-Profile '${name}' existiert bereits korrekt"
    else
      log_error "User-Profile '${name}' weicht ab (multivalued/validations.length.max/Rechte) — nicht automatisch überschreiben"
      return 1
    fi
  done

  if [[ "$(printf '%s' "${to_add}" | jq 'length')" == "0" ]]; then
    log_ok "User-Profile-Definitionen sichergestellt"
    return 0
  fi

  local updated
  updated=$(printf '%s' "${before}" | jq -c --argjson add "${to_add}" '.attributes += $add')
  _iam_call "${token}" PUT "${profile_url}" "${updated}" "200 204" || return 1

  _iam_call "${token}" GET "${profile_url}" || return 1
  _iam_body_is 'type=="object" and (.attributes|type)=="array"' \
    || { log_error "User-Profile Read-back: unerwartete JSON-Form"; return 1; }
  local after="${IAM_HTTP_BODY}"

  # Read-back (1): beide Definitionen konform.
  for def in "${def_memberships}" "${def_home}"; do
    _iam_profile_def_conforms "${after}" "${def}" \
      || { log_error "User-Profile Read-back: Definition nicht konform"; return 1; }
  done
  # Read-back (2)+(3): kein Attributname verloren, Top-Level-Einstellungen unveraendert.
  if ! jq -en --argjson b "${before}" --argjson a "${after}" '
    ((($b.attributes | map(.name)) - ($a.attributes | map(.name))) | length) == 0
    and (($a | del(.attributes)) == ($b | del(.attributes)))
  ' >/dev/null 2>&1; then
    log_error "User-Profile Read-back: Bestand verloren oder Top-Level-Einstellungen verändert"
    return 1
  fi

  log_ok "User-Profile-Definitionen sichergestellt"
}

# ── 3c. Metadaten-Protocol-Mapper am Client ───────────────────────────────────
# Zwei oidc-usermodel-attribute-mapper, die die Attribute in das verschachtelte
# Claim user_metadata.p2d2.* schreiben (ausschliesslich ins ID-Token).
# Prueft einen vorhandenen Mapper gegen alle Sollfelder; zusaetzliche Server-Schluessel sind keine Drift.
_iam_mapper_conforms() {
  jq -e --argjson p "$2" '
    . as $m
    | ($m.protocol == $p.protocol)
      and ($m.protocolMapper == $p.protocolMapper)
      and (($m.consentRequired // false) == $p.consentRequired)
      and all(($p.config | to_entries[]); $m.config[.key] == .value)
  ' <<<"$1" >/dev/null 2>&1
}

_iam_ensure_client_mapper() {
  local token="$1" client_uid="$2" name="$3" attr="$4" claim="$5"
  local base_url="${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/protocol-mappers/models"

  _iam_call "${token}" GET "${base_url}" || return 1
  _iam_body_is 'type=="array"' || { log_error "Mapper-Liste: unerwartete JSON-Form"; return 1; }
  local mappers_json="${IAM_HTTP_BODY}"

  local payload
  payload=$(jq -nc \
    --arg name "${name}" --arg attr "${attr}" --arg claim "${claim}" \
    '{name:$name,protocol:"openid-connect",protocolMapper:"oidc-usermodel-attribute-mapper",consentRequired:false,config:{"jsonType.label":"String",multivalued:"false","aggregate.attrs":"false","id.token.claim":"true","access.token.claim":"false","userinfo.token.claim":"false","user.attribute":$attr,"claim.name":$claim}}')

  local same_name_count other_claim_count
  same_name_count=$(printf '%s' "${mappers_json}" | jq '[.[] | select(.name == $name)] | length' --arg name "${name}")
  other_claim_count=$(printf '%s' "${mappers_json}" | jq '[.[] | select(.name != $name and .config["claim.name"] == $claim)] | length' --arg name "${name}" --arg claim "${claim}")

  if (( same_name_count > 1 )); then
    log_error "Mehrere Mapper mit Name '${name}' — bitte manuell bereinigen"
    return 1
  fi
  if (( other_claim_count > 0 )); then
    log_error "Claim '${claim}' wird bereits von einem anderen Mapper belegt"
    return 1
  fi

  local existing existing_type
  existing=$(printf '%s' "${mappers_json}" | jq -c ".[] | select(.name==\"${name}\")" 2>/dev/null || true)

  if [[ -n "${existing}" ]]; then
    existing_type=$(printf '%s' "${existing}" | jq -r '.protocolMapper // empty')
    if [[ "${existing_type}" != "oidc-usermodel-attribute-mapper" ]]; then
      log_error "Mapper '${name}' existiert mit anderem Typ (${existing_type}) — nicht überschreiben"
      return 1
    fi
    if _iam_mapper_conforms "${existing}" "${payload}"; then
      log_ok "Mapper '${name}' existiert bereits korrekt"
      return 0
    fi
    # Drift: nur verwaltete Felder angleichen, fremde Config-Schluessel erhalten.
    local mapper_id merged
    mapper_id=$(printf '%s' "${existing}" | jq -r '.id')
    merged=$(printf '%s' "${existing}" | jq -c --argjson p "${payload}" '.protocol = $p.protocol | .protocolMapper = $p.protocolMapper | .consentRequired = $p.consentRequired | .config = (.config * $p.config)')
    _iam_call "${token}" PUT "${base_url}/${mapper_id}" "${merged}" "200 204" || return 1
  else
    _iam_call "${token}" POST "${base_url}" "${payload}" "201 200" || return 1
  fi

  # Read-back: genau ein Mapper mit dem Namen und alle Sollfelder konform.
  _iam_call "${token}" GET "${base_url}" || return 1
  _iam_body_is 'type=="array"' || { log_error "Mapper Read-back: unerwartete JSON-Form"; return 1; }
  local rb_count rb_mapper
  rb_count=$(printf '%s' "${IAM_HTTP_BODY}" | jq '[.[] | select(.name == $name)] | length' --arg name "${name}")
  if (( rb_count != 1 )); then
    log_error "Mapper Read-back '${name}': ${rb_count} Treffer (erwartet 1)"
    return 1
  fi
  rb_mapper=$(printf '%s' "${IAM_HTTP_BODY}" | jq -c ".[] | select(.name==\"${name}\")")
  _iam_mapper_conforms "${rb_mapper}" "${payload}" \
    || { log_error "Mapper Read-back '${name}' entspricht nicht den Sollfeldern"; return 1; }

  log_ok "Mapper '${name}' sichergestellt"
}

ensure_metadata_mappers() {
  log "=== AddOn 25: Metadaten-Protocol-Mapper (2) ==="
  local token client_uid
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}") || return 1
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

# ── Demo-Accounts: Datei + Loader + Validierung ────────────────────────────────
# Extrahiert den ersten YAML-Block (ohne Fences) der Demo-Account-Datei.
_iam_demo_extract_yaml() {
  local fence='```'
  awk -v f="${fence}" '
    $0 ~ "^" f "yaml[[:space:]]*$" { in_block=1; next }
    in_block && $0 ~ "^" f "[[:space:]]*$" { exit }
    in_block { print }
  ' "$1"
}

# Validiert das geparste JSON; je Verstoß eine Fehlerzeile. 0 nur ohne Verstoß.
_iam_demo_validate() {
  local doc="$1" roles_json errors
  roles_json=$(printf '%s\n' "${ADDON_IAM_CLIENT_ROLES[@]}" | jq -R . | jq -sc .)
  errors=$(jq -r --argjson allowed "${roles_json}" '
    def bad_str($n): (type != "string") or (length == 0) or (length > $n);
    def opt_str($n): (type != "null") and ((type != "string") or (length == 0) or (length > $n));
    (if .version != 1 then "version: erwartet 1" else empty end),
    (if (.accounts | type) != "array" then "accounts: Liste erwartet" else empty end),
    ((.accounts // [])[]? | . as $a
      | (if ($a.username | bad_str(64)) then "\($a.username // "?"): username ungültig" else empty end),
        (if ($a.email | bad_str(200)) then "\($a.username): email ungültig" else empty end),
        (if ($a.first_name | bad_str(200)) then "\($a.username): first_name ungültig" else empty end),
        (if ($a.last_name | bad_str(200)) then "\($a.username): last_name ungültig" else empty end),
        (($a.roles // [])[]? | select(. as $r | ($allowed | index($r)) == null) | "\($a.username): unbekannte Rolle \(.)"),
        (if ($a.home_region_key // null) != null and ($a.home_region_key | opt_str(200)) then "\($a.username): home_region_key ungültig" else empty end),
        (if (($a.memberships // []) | length) > 50 then "\($a.username): mehr als 50 memberships" else empty end),
        (($a.memberships // [])[]? | . as $m
          | (if ($m.type | IN("kommune","community")) | not then "\($a.username): membership-type ungültig" else empty end),
            (if ($m.key | bad_str(200)) then "\($a.username): membership-key ungültig" else empty end),
            (if ($m.role // null) != null and ($m.role | opt_str(200)) then "\($a.username): membership-role ungültig" else empty end),
            (if ($m.wp_name // null) != null and ($m.wp_name | opt_str(200)) then "\($a.username): membership-wp_name ungültig" else empty end)),
        (if (($a.memberships // []) | tojson | length) > 4096 then "\($a.username): memberships zu lang" else empty end)),
    ([(.accounts // [])[]?.username | ascii_downcase] | group_by(.) | map(select(length > 1) | .[0])[] | "doppelter username \(.)"),
    ([(.accounts // [])[]?.email | ascii_downcase] | group_by(.) | map(select(length > 1) | .[0])[] | "doppelte email \(.)")
  ' <<<"${doc}")
  if [[ -n "${errors}" ]]; then
    while IFS= read -r l; do log_error "demo-accounts: ${l}"; done <<<"${errors}"
    return 1
  fi
  # Warnung (kein Fehler): Rolle verwaltung ohne kommune-Membership.
  while IFS= read -r l; do
    log_warn "demo-accounts: ${l}"
  done < <(jq -r '(.accounts // [])[]? | select((.roles // []) | index("verwaltung") != null) | select(((.memberships // []) | map(select(.type == "kommune")) | length) == 0) | "\(.username): Rolle verwaltung ohne kommune-Membership"' <<<"${doc}")
  return 0
}

# Laedt die Datei; setzt ADDON_IAM_DEMO_JSON (kompaktes JSON). Rückgabe 0/1.
_iam_demo_load() {
  local file raw doc
  file="$(addon_demo_accounts_file)" || return 1
  if [[ ! -f "${file}" ]]; then
    log "Demo-Accounts: keine (Datei fehlt: ${file})"
    ADDON_IAM_DEMO_JSON='{"version":1,"accounts":[]}'
    return 0
  fi
  if [[ ! -r "${file}" ]]; then
    log_error "Demo-Accounts: Datei nicht lesbar: ${file}"
    return 1
  fi
  raw="$(_iam_demo_extract_yaml "${file}")"
  [[ -n "${raw}" ]] || { log_error "Demo-Accounts: kein YAML-Block in ${file}"; return 1; }
  doc="$(printf '%s' "${raw}" | yq -o=json '.' 2>/dev/null)" \
    || { log_error "Demo-Accounts: YAML nicht lesbar (yq -o=json fehlgeschlagen)"; return 1; }
  printf '%s' "${doc}" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { log_error "Demo-Accounts: YAML erzeugt kein gültiges Objekt-JSON"; return 1; }
  _iam_demo_validate "${doc}" || return 1
  ADDON_IAM_DEMO_JSON="${doc}"
  return 0
}

# ── 5. Demo-Accounts ───────────────────────────────────────────────────────────
_iam_demo_account() {
  local token="$1" client_uid="$2" demo_pass="$3" username="$4" email="$5" first_name="$6" last_name="$7" roles="$8"
  local email_enc user_id
  email_enc=$(jq -rn --arg e "${email}" '$e|@uri')

  # Lookup (Antwort-/Formprüfung; Fehler = Account-Fehler, nicht "fehlt").
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" \
    || { log_error "Demo-User ${email}: Lookup fehlgeschlagen"; return 1; }
  _iam_body_is 'type=="array"' || { log_error "Demo-User ${email}: Lookup unerwartete JSON-Form"; return 1; }
  user_id=$(printf '%s' "${IAM_HTTP_BODY}" | jq -r '.[0].id // empty')

  if [[ -z "${user_id}" ]]; then
    local create_payload
    create_payload=$(jq -nc --arg u "${username}" --arg e "${email}" --arg fn "${first_name}" --arg ln "${last_name}" \
      '{username:$u,email:$e,enabled:true,emailVerified:true,requiredActions:[],firstName:$fn,lastName:$ln}')
    _iam_call "${token}" POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users" "${create_payload}" "201 409 200" \
      || { log_error "Demo-User ${email}: Anlegen fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"; return 1; }
    _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" \
      || { log_error "Demo-User ${email}: Re-Lookup fehlgeschlagen"; return 1; }
    _iam_body_is 'type=="array"' || { log_error "Demo-User ${email}: Re-Lookup unerwartete JSON-Form"; return 1; }
    user_id=$(printf '%s' "${IAM_HTTP_BODY}" | jq -r '.[0].id // empty')
  fi

  [[ -n "${user_id}" ]] || { log_error "Demo-User ${email}: konnte nicht angelegt/gefunden werden"; return 1; }

  # Profil idempotent (GET->Merge->PUT, nur bei Änderung).
  local profile_patch profile_body user_json
  profile_patch=$(jq -nc --arg fn "${first_name}" --arg ln "${last_name}" \
    '{emailVerified:true,requiredActions:[],firstName:$fn,lastName:$ln}')
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" \
    || { log_error "Demo-User ${email}: Profil-GET fehlgeschlagen"; return 1; }
  _iam_body_is 'type=="object"' || { log_error "Demo-User ${email}: Profil-GET unerwartete JSON-Form"; return 1; }
  user_json="${IAM_HTTP_BODY}"
  profile_body=$(printf '%s' "${user_json}" | jq -c --argjson p "${profile_patch}" '. * $p')
  if [[ "${profile_body}" != "${user_json}" ]]; then
    _iam_call "${token}" PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" "${profile_body}" "200 204" \
      || { log_error "Demo-User ${email}: Profil-PUT fehlgeschlagen (HTTP ${IAM_HTTP_CODE})"; return 1; }
  fi

  # Passwort setzen (Historie ist kein Fehler).
  local pw_payload pw_body
  pw_payload=$(jq -nc --arg pw "${demo_pass}" '{type:"password",value:$pw,temporary:false}')
  _iam_req "${token}" PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}/reset-password" "${pw_payload}"
  if [[ "${IAM_HTTP_CODE}" != "204" && "${IAM_HTTP_CODE}" != "200" ]]; then
    pw_body=$(printf '%s' "${IAM_HTTP_BODY}" | cut -c1-120)
    if [[ "${IAM_HTTP_BODY}" == *invalidPasswordHistoryMessage* ]]; then
      log_ok "Demo-User ${email}: Passwort unveraendert (Historie)"
    else
      log_warn "Demo-User ${email}: Passwort fehlgeschlagen (HTTP ${IAM_HTTP_CODE}): ${pw_body}"
    fi
  fi

  # Rollen additiv zuweisen + Read-back.
  local role_payload="[]" role role_id
  for role in ${roles}; do
    _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/clients/${client_uid}/roles/${role}" \
      || { log_error "Demo-User ${email}: Rolle ${role} nicht lesbar"; return 1; }
    role_id=$(printf '%s' "${IAM_HTTP_BODY}" | jq -r '.id // empty')
    [[ -n "${role_id}" ]] && role_payload=$(printf '%s' "${role_payload}" | jq -c --arg id "${role_id}" --arg name "${role}" '. + [{"id":$id,"name":$name}]')
  done
  if [[ "${role_payload}" != "[]" ]]; then
    _iam_call "${token}" POST "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}/role-mappings/clients/${client_uid}" "${role_payload}" "204 200" \
      || { log_error "Demo-User ${email}: Rollenzuweisung fehlgeschlagen"; return 1; }
  fi
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}/role-mappings/clients/${client_uid}" \
    || { log_error "Demo-User ${email}: Rollen-Read-back fehlgeschlagen"; return 1; }
  _iam_body_is 'type=="array"' || { log_error "Demo-User ${email}: Rollen-Read-back unerwartete JSON-Form"; return 1; }
  for role in ${roles}; do
    printf '%s' "${IAM_HTTP_BODY}" | jq -e ".[] | select(.name==\"${role}\")" >/dev/null 2>&1 \
      || { log_error "Demo-User ${email}: Rolle ${role} fehlt nach Zuweisung"; return 1; }
  done

  log_ok "Demo-User ${username} (id ${user_id}) — Rollen: ${roles}"
  return 0
}

ensure_p2d2_demo_accounts() {
  log "=== AddOn 25: Demo-Accounts ==="
  _iam_demo_load || return 1
  local n
  n=$(printf '%s' "${ADDON_IAM_DEMO_JSON}" | jq '(.accounts // []) | length')
  if [[ "${n}" == "0" ]]; then
    log "Demo-Accounts: keine"
    return 0
  fi

  local token client_uid demo_pass
  token=$(_iam_get_token) || return 1
  client_uid=$(_iam_get_client_uid "${token}") || { log_error "AddOn 25: OIDC-Client-Auflösung fehlgeschlagen"; return 1; }

  demo_pass="${P2D2_DEMO_PASSWORD:-}"
  if [[ -z "${demo_pass}" ]]; then
    log_error "P2D2_DEMO_PASSWORD nicht gesetzt — Demo-Accounts koennen kein Passwort erhalten"
    return 1
  fi
  if [[ ${#demo_pass} -lt 8 ]] || [[ ! "${demo_pass}" =~ [A-Z] ]] || [[ ! "${demo_pass}" =~ [a-z] ]] || [[ ! "${demo_pass}" =~ [0-9] ]]; then
    log_error "P2D2_DEMO_PASSWORD erfuellt die Mindestanforderungen nicht (>= 8 Zeichen, Gross-/Kleinbuchstabe, Ziffer)"
    return 1
  fi

  local failures=0 account username email first_name last_name roles
  while IFS= read -r account; do
    username=$(printf '%s' "${account}" | jq -r '.username')
    email=$(printf '%s' "${account}" | jq -r '.email')
    first_name=$(printf '%s' "${account}" | jq -r '.first_name')
    last_name=$(printf '%s' "${account}" | jq -r '.last_name')
    roles=$(printf '%s' "${account}" | jq -r '(.roles // []) | join(" ")')
    _iam_demo_account "${token}" "${client_uid}" "${demo_pass}" "${username}" "${email}" "${first_name}" "${last_name}" "${roles}" \
      || failures=$((failures+1))
    seed_user_metadata "${token}" "${account}" || failures=$((failures+1))
  done < <(printf '%s' "${ADDON_IAM_DEMO_JSON}" | jq -c '(.accounts // [])[]')

  if (( failures > 0 )); then
    log_error "${failures} Demo-Account(s) fehlgeschlagen"
    return 1
  fi
  return 0
}

# ── 5b. Demo-Metadaten (generischer Seed, nie überschreiben) ──────────────
# Zustand eines User-Attributs gegen den Seed-Wert: absent|same|different|invalid.
_iam_attr_state() {
  jq -r --arg k "$2" --argjson seed "$3" '
    (.attributes // {}) as $a
    | if ($a | has($k) | not) then "absent"
      elif $a[$k] == $seed then "same"
      elif (($a[$k] | type) == "array" and ($a[$k] | length) == 1
            and ($a[$k][0] | type) == "string" and ($a[$k][0] | length) > 0) then "different"
      else "invalid" end' <<<"$1"
}

seed_user_metadata() {
  local token="$1" account="$2"
  local email email_enc
  email=$(printf '%s' "${account}" | jq -r '.email')
  email_enc=$(jq -rn --arg e "${email}" '$e|@uri')

  # Kanonische Seed-Werte (jeweils Attribut = Liste mit EINEM String).
  local memberships_json memberships_seed home_seed
  memberships_json=$(printf '%s' "${account}" | jq -c '(.memberships // []) | map({type, key, role, wp_name} | with_entries(select(.value != null)))')
  memberships_seed=$(printf '%s' "${memberships_json}" | jq -c 'if length > 0 then [tojson] else empty end')
  home_seed=$(printf '%s' "${account}" | jq -c 'if (.home_region_key // "") != "" then [.home_region_key] else empty end')

  # Keine definierten Werte -> nichts zu tun (keine leeren Attribute).
  if [[ -z "${memberships_seed}" && -z "${home_seed}" ]]; then
    return 0
  fi

  # Exakt einen Benutzer aufloesen; 0/mehrere Treffer sind ein Fehler.
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users?email=${email_enc}&exact=true" || return 1
  _iam_body_is 'type=="array"' || { log_error "Demo-User ${email}: Lookup unerwartete JSON-Form"; return 1; }
  local user_count user_id
  user_count=$(printf '%s' "${IAM_HTTP_BODY}" | jq 'length')
  if [[ "${user_count}" != "1" ]]; then
    log_error "Demo-User ${email}: Lookup erwartete genau 1 Treffer, fand ${user_count}"
    return 1
  fi
  user_id=$(printf '%s' "${IAM_HTTP_BODY}" | jq -r '.[0].id // empty')
  [[ -n "${user_id}" ]] || { log_error "Demo-User ${email}: id fehlt"; return 1; }

  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" || return 1
  _iam_body_is 'type=="object"' || { log_error "Demo-User ${email}: GET unerwartete JSON-Form"; return 1; }
  local user_json="${IAM_HTTP_BODY}"

  # Vor jedem PUT id und E-Mail des gelesenen Benutzers pruefen.
  local got_id got_email
  got_id=$(printf '%s' "${user_json}" | jq -r '.id // empty')
  got_email=$(printf '%s' "${user_json}" | jq -r '.email // empty' | tr '[:upper:]' '[:lower:]')
  if [[ "${got_id}" != "${user_id}" || "${got_email}" != "${email}" ]]; then
    log_error "Demo-User ${email}: id/E-Mail-Abweichung vor PUT"
    return 1
  fi

  # Matrix absent/same/different/invalid; vorhandene Werte nie ueberschreiben.
  local delta="{}" state
  if [[ -n "${memberships_seed}" ]]; then
    state=$(_iam_attr_state "${user_json}" "p2d2.memberships" "${memberships_seed}")
    case "${state}" in
      absent)    delta=$(printf '%s' "${delta}" | jq -c --argjson m "${memberships_seed}" '. + {"p2d2.memberships": $m}') ;;
      same)      log_ok "Demo-User ${email}: p2d2.memberships bereits korrekt" ;;
      different) log_warn "Demo-User ${email}: p2d2.memberships weicht ab — manuelle Pruefung" ;;
      invalid)   log_warn "Demo-User ${email}: p2d2.memberships ungültig/mehrwertig — manuelle Pruefung" ;;
    esac
  fi
  if [[ -n "${home_seed}" ]]; then
    state=$(_iam_attr_state "${user_json}" "p2d2.preferences.home_region_key" "${home_seed}")
    case "${state}" in
      absent)    delta=$(printf '%s' "${delta}" | jq -c --argjson h "${home_seed}" '. + {"p2d2.preferences.home_region_key": $h}') ;;
      same)      log_ok "Demo-User ${email}: home_region_key bereits korrekt" ;;
      different) log_warn "Demo-User ${email}: home_region_key weicht ab — manuelle Pruefung" ;;
      invalid)   log_warn "Demo-User ${email}: home_region_key ungültig/mehrwertig — manuelle Pruefung" ;;
    esac
  fi

  if [[ "${delta}" == "{}" ]]; then
    return 0
  fi

  local merged
  merged=$(printf '%s' "${user_json}" | jq -c --argjson d "${delta}" '.attributes = ((.attributes // {}) + $d)')
  _iam_call "${token}" PUT "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" "${merged}" "200 204" || return 1

  # Read-back: gesetzte Werte UND unberuehrte Attribute pruefen.
  _iam_call "${token}" GET "${ADDON_IAM_IDM_BASE}/admin/realms/${ADDON_IAM_REALM}/users/${user_id}" || return 1
  local after="${IAM_HTTP_BODY}"
  _iam_body_is 'type=="object"' || { log_error "Demo-User ${email}: Read-back unerwartete JSON-Form"; return 1; }
  if ! jq -en --argjson b "${user_json}" --argjson a "${after}" --argjson d "${delta}" '
    def attrs(x): (x.attributes // {});
    all($d | keys[]; . as $k | attrs($a)[$k] == $d[$k])
    and all(attrs($b) | keys[]; . as $k | ($d | has($k)) or (attrs($a)[$k] == attrs($b)[$k]))
  ' >/dev/null 2>&1; then
    log_error "Demo-User ${email}: Read-back Attribute weichen ab"
    return 1
  fi

  log_ok "Demo-User ${email}: Metadaten gesetzt"
}

# ── Orchestrierung ─────────────────────────────────────────────────────────────
install_addon_iam() {
  log "=== AddOn 25: IAM/Keycloak-Provisionierung ==="
  ensure_p2d2_oidc_client
  ensure_p2d2_client_roles
  ensure_p2d2_role_token_mapper
  ensure_metadata_profile || { log_error "AddOn 25: Metadaten-Profil fehlgeschlagen"; return 1; }
  ensure_metadata_mappers || { log_error "AddOn 25: Metadaten-Mapper fehlgeschlagen"; return 1; }
  ensure_osm_identity_provider
  ensure_p2d2_demo_accounts || return 1
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

  # 1) Demo-Accounts (nur die der gültigen Datei); ohne Datei keine Löschung.
  _iam_demo_load || return 1
  local n account email email_enc user_id
  n=$(printf '%s' "${ADDON_IAM_DEMO_JSON}" | jq '(.accounts // []) | length')
  if [[ "${n}" == "0" ]]; then
    log "Uninstall: keine Demo-Accounts in demo-accounts.md — manuelle Bereinigung im Realm prüfen"
  else
    while IFS= read -r account; do
      email=$(printf '%s' "${account}" | jq -r '.email')
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
    done < <(printf '%s' "${ADDON_IAM_DEMO_JSON}" | jq -c '(.accounts // [])[]')
  fi

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
  client_uid=$(_iam_get_client_uid "${token}") || return 1
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

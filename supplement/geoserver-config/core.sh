#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
# core.sh - Logging, How-To, Environment, Secrets, HTTP, Bestand, Preflight.
# Wird vom Einstieg genau einmal gesourct; kein eigenstaendig ausfuehrbares Programm.

log()      { printf '%s\n' "$*"; }

log_ok()   { printf 'OK   %s\n' "$*"; }

log_warn() { printf 'WARN %s\n' "$*" >&2; }

log_error(){ printf 'FEHLER %s\n' "$*" >&2; }

log_gs_error() {
  if [[ -n "${_GS_ERR_BODY:-}" ]]; then
    log_error "$1 — ${_GS_ERR_BODY}"
  else
    log_error "$1"
  fi
}

warn_legacy_vars() {
  local var
  while IFS= read -r var; do
    case "$var" in
      P2D2_*_WFST_PASSWORD|WFST_PW_*|WFS_RO_PW|WFS_PW)
        log_warn "Legacy-Variable $var gesetzt — wird ignoriert (Secret ist Single Source of Truth)"
        ;;
    esac
  done < <(compgen -v | sort)
}

howto() {
  [[ -n "$HOWTO_FILE" ]] || return 0
  printf '%s\n' "$*" >&"$HOWTO_FD"
}

howto_step() {
  howto "$1 (erwartet $2, erhalten $3)${4:+ — $4}"
}

_env_get() {
  local file="$1" key="$2" line re
  [[ -f "$file" ]] || return 1
  re='^[[:space:]]*(export[[:space:]]+)?'"${key}"'=("[^"]*"|[^[:space:]#]*)'
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[2]//\"/}"
      return 0
    fi
  done < "$file"
  return 1
}

_env_resolve() {
  local key="$1" val=""
  val="${!key:-}"
  [[ -n "$val" ]] && { printf '%s' "$val"; return 0; }
  local f
  for f in "./.env.p2d2-addon" "../.env.p2d2-addon" "../../.env.p2d2-addon"; do
    if val="$(_env_get "$f" "$key")" && [[ -n "$val" ]]; then
      printf '%s' "$val"; return 0
    fi
  done
  return 1
}

_cfg_ok() {
  local v="$1"
  [[ -n "$v" && "$v" != "CHANGEME" && "$v" != "changeme" ]]
}

load_ds_config() {
  local key ws ds schema uservar secret u rc=0
  _DB_HOST="$(_env_resolve P2D2_BASE_DB_HOST || true)"
  _DB_PORT="$(_env_resolve P2D2_BASE_DB_PORT || true)"
  _DB_NAME="$(_env_resolve P2D2_BASE_DB_NAME || true)"
  _cfg_ok "$_DB_HOST" || { log_error "P2D2_BASE_DB_HOST fehlt oder ist CHANGEME"; rc=2; }
  _cfg_ok "$_DB_PORT" || { log_error "P2D2_BASE_DB_PORT fehlt oder ist CHANGEME"; rc=2; }
  _cfg_ok "$_DB_NAME" || { log_error "P2D2_BASE_DB_NAME fehlt oder ist CHANGEME"; rc=2; }
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    u="$(_env_resolve "$uservar" || true)"
    _cfg_ok "$u" || { log_error "$uservar fehlt oder ist CHANGEME"; rc=2; }
  done <<< "$DS_TABLE"
  return "$rc"
}

_secret_get() {
  local ns="$1" name="$2" key="$3"
  kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

_secret_apply() {
  local ns="$1" name="$2"; shift 2
  local manifest json kv k v tmpv err
  manifest="$(mktemp)"
  json="$(kubectl -n "$ns" get secret "$name" -o json 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    json="$(printf '%s' "$json" | jq -c --arg n "$name" --arg ns "$ns" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:$ns},type:(.type // "Opaque"),data:(.data // {})}' 2>/dev/null || true)"
  fi
  [[ -n "$json" ]] || json="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name\",\"namespace\":\"$ns\"},\"type\":\"Opaque\",\"data\":{}}"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    tmpv="$(mktemp)"; chmod 600 "$tmpv"
    printf '%s' "$v" | base64 -w0 > "$tmpv"
    json="$(printf '%s' "$json" | jq -c --arg k "$k" --rawfile v "$tmpv" '.data[$k] = $v')"
    rm -f "$tmpv"
  done
  printf '%s\n' "$json" > "$manifest"
  if ! err="$(kubectl apply -f "$manifest" 2>&1 >/dev/null)"; then
    log_error "Secret ${name}: $(printf '%s' "$err" | head -1 | cut -c1-200)"
    rm -f "$manifest"
    return 1
  fi
  rm -f "$manifest"
  return 0
}

_wait_gs_ready() {
  local tries=$(( (${GS_WAIT_SECONDS:-120} + 4) / 5 )) code i
  [ "$tries" -ge 1 ] || tries=1
  for (( i=1 ; i<=tries ; i++ )) ; do
    code="$(_gs_http_code GET 'security/roles.json')"
    case "$code" in
      200) return 0 ;;
      000|502|503|504) ;;
      *) return 1 ;;
    esac
    (( i < tries )) && { log "  GeoServer noch nicht bereit (HTTP $code) - warte 5 s"; sleep 5; }
  done
  return 1
}

_pw_gen() { openssl rand -hex 24; }

_pw_is_valid() {
  local v="$1"
  [[ "${#v}" -ge 16 && ! "$v" =~ [^A-Za-z0-9._~@%+=:,/-] ]]
}

_curl_user_cfg() {
  local s="${1}:${2}"
  case "$s" in *$'\n'*|*$'\r'*) log_error "Zugangsdaten enthalten Zeilenumbruch"; return 1 ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf 'user = "%s"\n' "$s"
}

# Zentrale Timeouts fuer alle GeoServer-curl-Aufrufe (GS_CURL_MAX_TIME ueberschreibbar).
GS_CURL_TMO=(--connect-timeout 10 --max-time "${GS_CURL_MAX_TIME:-60}")

_gs_http_code() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" code
  if [[ -n "$payload" ]]; then
    code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || code="000"
  else
    code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X "$method" -H "Content-Type: $ctype" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || code="000"
  fi
  printf '%s' "$code"
}

_gs_write_body() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" tmp
  _GS_ERR_BODY=""
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if [[ -n "$payload" ]]; then
    _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" -o "$tmp" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
  else
    _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X "$method" -H "Content-Type: $ctype" -o "$tmp" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
  fi
  _GS_ERR_BODY="$(head -1 "$tmp" 2>/dev/null | cut -c1-200)"
  rm -f "$tmp"
}

preflight() {
  local cmd rc=0
  for cmd in kubectl jq curl openssl yq; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Voraussetzung fehlt: $cmd"; rc=2; }
  done
  [[ "$rc" -eq 0 ]] || exit "$rc"

  # yq muss mikefarah v4 sein (der YAML-Parser der Metadaten-Datei).
  yq --version 2>&1 | grep -q mikefarah || { log_error 'yq: mikefarah v4 erforderlich'; exit 2; }

  # GS_BASE muss gesetzt sein (K4): --url oder ADDON_DOMAIN/DOMAIN_NAME (.env.p2d2-addon)
  [[ -n "$GS_BASE" ]] || { log_error "GS_BASE leer — bitte --url BASE oder ADDON_DOMAIN (bzw. DOMAIN_NAME) setzen"; exit 2; }

  kubectl -n "$NAMESPACE" get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || { log_error "Namespace existiert nicht: $NAMESPACE"; exit 2; }

  # Admin-Zugang: Secret zuerst, Env-Override GS_ADMIN_USER/GS_ADMIN_PW gewinnt.
  # Das Admin-Passwort wird nie ausgegeben.
  local secret_user secret_pw pw_src
  secret_user="$(kubectl -n "$NAMESPACE" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  secret_pw="$(kubectl -n "$NAMESPACE" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  # Quelle festhalten, bevor die Defaults greifen (für aussagekräftige Fehlermeldung).
  [[ -n "${GS_ADMIN_PW+x}" ]] && pw_src="Umgebung" || pw_src="Secret"
  GS_ADMIN_USER="${GS_ADMIN_USER:-$secret_user}"
  GS_ADMIN_PW="${GS_ADMIN_PW:-$secret_pw}"
  [[ -n "$GS_ADMIN_USER" && -n "$GS_ADMIN_PW" ]] \
    || { log_error "Admin-Zugang (Secret geoserver-geoserver) nicht lesbar"; exit 2; }
  check_never_touch || exit 2
  check_ws_table || exit 2
  check_ds_table || exit 2
  load_ds_config || exit 2
  check_styles || exit 2

  if ! _wait_gs_ready; then
    log_error "GeoServer nicht erreichbar (GET security/roles.json, Benutzer $GS_ADMIN_USER, Passwort aus $pw_src): $GS_REST"
    exit 2
  fi
  log_ok "Preflight ok (Namespace ${NAMESPACE}, GeoServer ${GS_BASE})"
}

_gs_get() {
  local path="$1"
  _GS_BODY_FILE="$(mktemp)"; chmod 600 "$_GS_BODY_FILE"
  _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X GET -H "Content-Type: application/json" -o "$_GS_BODY_FILE" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
}

read_users() {
  _gs_get 'security/usergroup/users.json'
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen security/usergroup/users.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -e '.users | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { rm -f "$_GS_BODY_FILE"; log_error "security/usergroup/users.json: unerwartete JSON-Form"; return 1; }
  jq -r '.users[]?.userName // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  rm -f "$_GS_BODY_FILE"
}

read_roles() {
  _gs_get 'security/roles.json'
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen security/roles.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -e '.roles | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { rm -f "$_GS_BODY_FILE"; log_error "security/roles.json: unerwartete JSON-Form"; return 1; }
  jq -r '.roles[]? // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  rm -f "$_GS_BODY_FILE"
}

read_user_roles() {
  local user="$1"
  _gs_get "security/roles/user/${user}.json"
  case "$_GS_CODE" in
    200) ;;
    404) rm -f "$_GS_BODY_FILE"; return 0 ;;
    *) log_error "Lesen security/roles/user/${user}.json fehlgeschlagen (HTTP $_GS_CODE)"; rm -f "$_GS_BODY_FILE"; return 1 ;;
  esac
  jq -e '.roles | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { log_error "security/roles/user/${user}.json: unerwartete JSON-Form"; rm -f "$_GS_BODY_FILE"; return 1; }
  jq -r '.roles[]? // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  rm -f "$_GS_BODY_FILE"
}

read_workspaces() {
  _gs_get 'workspaces.json'
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen workspaces.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  if jq -e '.workspaces.workspace | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    jq -r '.workspaces.workspace[]?.name // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  elif jq -e '(.workspaces.workspace == "" or .workspaces.workspace == null)' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    :
  else
    rm -f "$_GS_BODY_FILE"; log_error "workspaces.json: unerwartete JSON-Form"; return 1
  fi
  rm -f "$_GS_BODY_FILE"
}

read_namespace_uri() {
  local ws="$1"
  _gs_get "namespaces/${ws}.json"
  case "$_GS_CODE" in
    200) ;;
    *) rm -f "$_GS_BODY_FILE"; log_error "Lesen namespaces/${ws}.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1 ;;
  esac
  jq -e '.namespace.uri | type == "string"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { rm -f "$_GS_BODY_FILE"; log_error "namespaces/${ws}.json: unerwartete JSON-Form"; return 1; }
  jq -r '.namespace.uri // empty' "$_GS_BODY_FILE" 2>/dev/null
  rm -f "$_GS_BODY_FILE"
}

read_available_natives() {
  local ws="$1" ds="$2"
  _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes.json?list=available"
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "list=available für ${ws}/${ds} fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -r '.list.string[]? // empty' "$_GS_BODY_FILE" 2>/dev/null
  rm -f "$_GS_BODY_FILE"
}

read_featuretypes() {
  local ws="$1" ds="$2"
  _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes.json"
  case "$_GS_CODE" in
    200) ;;
    404) rm -f "$_GS_BODY_FILE"; return 0 ;;
    *) rm -f "$_GS_BODY_FILE"; log_error "Lesen workspaces/${ws}/datastores/${ds}/featuretypes.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1 ;;
  esac
  if jq -e '.featureTypes.featureType | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    jq -r '.featureTypes.featureType[]?.name // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  elif jq -e '(.featureTypes == "" or .featureTypes == null)' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    :
  else
    rm -f "$_GS_BODY_FILE"; log_error "workspaces/${ws}/datastores/${ds}/featuretypes.json: unerwartete JSON-Form"; return 1
  fi
  rm -f "$_GS_BODY_FILE"
}

read_datastores() {
  local ws="$1"
  _gs_get "workspaces/${ws}/datastores.json"
  case "$_GS_CODE" in
    200) ;;
    404) rm -f "$_GS_BODY_FILE"; return 0 ;;
    *) rm -f "$_GS_BODY_FILE"; log_error "Lesen workspaces/${ws}/datastores.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1 ;;
  esac
  if jq -e '.dataStores.dataStore | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    jq -r '.dataStores.dataStore[]?.name // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  elif jq -e '(.dataStores == "" or .dataStores == null)' "$_GS_BODY_FILE" >/dev/null 2>&1; then
    :
  else
    rm -f "$_GS_BODY_FILE"; log_error "workspaces/${ws}/datastores.json: unerwartete JSON-Form"; return 1
  fi
  rm -f "$_GS_BODY_FILE"
}

_ds_present() {
  local ws="$1" ds="$2" tmp
  local -a dl
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_datastores "$ws" > "$tmp"; then rm -f "$tmp"; return 2; fi
  mapfile -t dl < "$tmp"
  rm -f "$tmp"
  _has "$ds" "${dl[@]}" && return 0
  return 1
}

_http_code_url() {
  local url="$1" code
  code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -o /dev/null -w '%{http_code}' "$url" 2>/dev/null )" || code="000"
  printf '%s' "$code"
}

_gs_get_url() {
  local url="$1"
  _GS_BODY_FILE="$(mktemp)"; chmod 600 "$_GS_BODY_FILE"
  _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - "${GS_CURL_TMO[@]}" -X GET -o "$_GS_BODY_FILE" -w '%{http_code}' "$url" 2>/dev/null )" || _GS_CODE="000"
}

_read_user_roles_into() {
  local user="$1" tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_user_roles "$user" > "$tmp"; then rm -f "$tmp"; return 1; fi
  mapfile -t _USER_ROLES < "$tmp"
  rm -f "$tmp"
  return 0
}

_load_inventory() {
  local tmp rc=0
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if read_users > "$tmp"; then mapfile -t _INV_USERS < "$tmp"; else rc=2; fi
  if read_roles > "$tmp"; then mapfile -t _INV_ROLES < "$tmp"; else rc=2; fi
  rm -f "$tmp"
  [[ "$rc" -eq 0 ]] || return 2
  _inventory_plausible _INV_USERS _INV_ROLES || return 2
  return 0
}

_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

_inventory_plausible() {
  local -n users="$1" roles="$2"
  _has "$GS_ADMIN_USER" "${users[@]}" || { log_error "Benutzerliste enthält nicht den Admin-Benutzer $GS_ADMIN_USER"; return 1; }
  _has "ADMIN" "${roles[@]}" || { log_error "Rollenliste enthält nicht die Rolle ADMIN"; return 1; }
  return 0
}

check_never_touch() {
  local line key _ user roles secret n
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for n in $NEVER_TOUCH_USERS; do
      [[ "$user" == "$n" ]] && { log_error "Soll-Tabelle enthält verbotenen Benutzer: $user"; return 1; }
    done
  done <<< "$SOL_TABLE"
  return 0
}

check_ws_table() {
  local key ws user w want
  while IFS='|' read -r key ws user _ _; do
    [[ -n "$key" ]] || continue
    [[ "$ws" == "-" ]] && continue
    want=0
    while IFS='|' read -r w _; do
      [[ "$w" == "$ws" ]] && { want=1; break; }
    done <<< "$WS_TABLE"
    [[ "$want" -eq 1 ]] || { log_error "Soll-Workspace $ws fehlt in WS_TABLE"; return 1; }
  done <<< "$SOL_TABLE"
  return 0
}

_ws_uri() {
  local want="$1" w uri
  while IFS='|' read -r w uri; do
    [[ -n "$w" ]] || continue
    [[ "$w" == "$want" ]] && { printf '%s' "$uri"; return 0; }
  done <<< "$WS_TABLE"
  return 1
}

check_ds_table() {
  local key ws ds schema uservar secret w want
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    want=0
    while IFS='|' read -r k _; do
      [[ "$k" == "$key" ]] && { want=1; break; }
    done <<< "$SOL_TABLE"
    [[ "$want" -eq 1 ]] || { log_error "Datastore-KEY $key fehlt in SOL_TABLE"; return 1; }
    want=0
    while IFS='|' read -r w _; do
      [[ "$w" == "$ws" ]] && { want=1; break; }
    done <<< "$WS_TABLE"
    [[ "$want" -eq 1 ]] || { log_error "Datastore-Workspace $ws fehlt in WS_TABLE"; return 1; }
  done <<< "$DS_TABLE"
  return 0
}

check_styles() {
  local style code
  for style in polygon generic; do
    code="$(_gs_http_code GET "styles/${style}.json")"
    [[ "$code" == "200" ]] || { log_error "Stil $style nicht vorhanden (GET styles/$style.json -> $code)"; return 1; }
  done
  return 0
}

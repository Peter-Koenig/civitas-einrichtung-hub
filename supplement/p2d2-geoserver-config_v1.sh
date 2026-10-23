#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-geoserver-config_v1.sh — GeoServer-Konfiguration (CIVITAS/CORE-AddOn).
# Schritt 1: WFS-T-/WFS-Benutzer, Rollen und Kubernetes-Secrets.
# Schritt 2: Workspaces (Name + Namespace-URI) analog zum Standalone.
# Schritt 3: Datastores (PostGIS-Verbindung) analog zum Standalone.
# Schritt 4: FeatureTypes und Default-Styles analog zum Standalone.
#
# Läuft in der CIVITAS/CORE-VM (root, kubectl vorhanden). Legt die fünf
# WFS-T-Benutzer und den WFS-Lese-Benutzer samt Rollen an bzw. setzt deren
# Passwort, erzeugt die Passwörter und speichert sie als Kubernetes-Secrets
# (das Secret ist Single Source of Truth). Legt außerdem die sechs Workspaces,
# die fünf PostGIS-Datastores und die FeatureTypes samt Default-Styles an.
# --uninstall entfernt genau diese Objekte wieder.
#
# Bewusst klein und flach: keine Statusbericht-/-Authz-/k8s-Diagnose.
#
# Aufruf:  bash ./p2d2-geoserver-config_v1.sh [--dry-run] [--uninstall]
#          [--url BASE] [--ns NAMESPACE] [--help|-h]
# Exit:    0 = ok, 1 = Fehler, 2 = Aufruf-/Voraussetzungsfehler.

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Soll-Tabelle (eine Stelle). Spalten:
#   KEY | Workspace | GeoServer-User | Rollen (Komma-getrennt) | Secret
#
# Hinweis DEVELOP: Das Secret heißt laut VARIABLES.md `p2d2-geoserver-wfst-develop`
# (nicht `-dev`); siehe Rückfrage im Bericht.
# ═══════════════════════════════════════════════════════════════════════════
SOL_TABLE='MAIN|main|p2d2_wfst_main|P2D2_WFST_MAIN,P2D2_IMPORT_ROLE|p2d2-geoserver-wfst-main
DEVELOP|dev|p2d2_wfst_develop|P2D2_WFST_DEVELOP|p2d2-geoserver-wfst-develop
DE1|de1|p2d2_wfst_de1|P2D2_WFST_DE1|p2d2-geoserver-wfst-de1
DE2|de2|p2d2_wfst_de2|P2D2_WFST_DE2|p2d2-geoserver-wfst-de2
FV|fv|p2d2_wfst_fv|P2D2_WFST_FV|p2d2-geoserver-wfst-fv
RO|-|p2d2_wfs_user|WFS-USER|p2d2-geoserver-wfs-user'

# Benutzer/Rollen, die dieses Skript NIE anfasst.
NEVER_TOUCH_USERS='admin p2d2_wfst_user'

# Workspace-Soll-Tabelle (Schritt 2): Workspace | Namespace-URI.
# Identisch zum Standalone-Export 2026-09-29; keine Workspace-ACLs, keine Umbenennung.
WS_TABLE='main|urn:data-dna:govdata:main
dev|urn:data-dna:govdata:dev
de1|urn:data-dna:govdata:de1
de2|urn:data-dna:govdata:de2
fv|urn:data-dna:govdata:fv
friedhofsplaene|urn:data-dna:tiffdata'

# Datastore-Soll-Tabelle (Schritt 3): KEY | Workspace | Datastore | Schema | DB-User-Variable | Secret.
# Die DB-User-Variable ist der Name des .env-Schlüssels (P2D2_<KEY>_DB_USER); ihr Wert (z. B. P2D2-MAIN)
# kommt als Datastore-Parameter `user`. Das Secret (Key DB_PASSWORD) gehört addon_00 und wird nur gelesen.
DS_TABLE='MAIN|main|main_pg|p2d2_main|P2D2_MAIN_DB_USER|p2d2-main-secret
DEVELOP|dev|dev_pg|p2d2_develop|P2D2_DEVELOP_DB_USER|p2d2-dev-secret
DE1|de1|de1_pg|p2d2_de1|P2D2_DE1_DB_USER|p2d2-f-de1-secret
DE2|de2|de2_pg|p2d2_de2|P2D2_DE2_DB_USER|p2d2-f-de2-secret
FV|fv|fv_pg|p2d2_fv|P2D2_FV_DB_USER|p2d2-f-fv-secret'

# FeatureType-Soll-Tabelle (Schritt 4): Name | Native-Name | Titel (%ws% = Workspace) | cachingEnabled (-/false) | Default-Style.
# Die Titel werden durch Ersetzen von %ws% durch den Workspace-Namen gebildet.
FT_TABLE='geo-containers|p2d2_containers|Geo-Containers (%ws%)|-|polygon
grabflure|v_grabflure_aktuell|grabflure_aktuell|false|polygon
grabflure_versionen|p2d2_grabflure_versionen|grabflure_versionen|false|polygon
graeber|v_graeber_aktuell|Gräber (%ws%)|-|generic
graeber_versionen|p2d2_graeber_versionen|Gräber Versionen (%ws%)|-|polygon'

# ═══════════════════════════════════════════════════════════════════════════
# Globals
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_NAME="p2d2-geoserver-config_v1.sh"
NAMESPACE=""
GS_BASE=""          # z. B. https://geoportal.<domain>/geoserver
GS_REST=""          # $GS_BASE/rest
DRY_RUN=0
UNINSTALL=0
# GS_ADMIN_USER/GS_ADMIN_PW werden NICHT vorbelegt: ein in der Umgebung gesetzter
# Wert (Override) muss in preflight() als "${GS_ADMIN_USER:-...}" erhalten bleiben.
HOWTO_FILE=""
HOWTO_FD=3          # Datei-Deskriptor für die How-To-Ausgabe

# ═══════════════════════════════════════════════════════════════════════════
# Logging (ohne Werte/Secrets)
# ═══════════════════════════════════════════════════════════════════════════
log()      { printf '%s\n' "$*"; }
log_ok()   { printf 'OK   %s\n' "$*"; }
log_warn() { printf 'WARN %s\n' "$*" >&2; }
log_error(){ printf 'FEHLER %s\n' "$*" >&2; }

# log_gs_error <msg> — Fehler mit optionalem Antworttext (R2).
log_gs_error() {
  if [[ -n "${_GS_ERR_BODY:-}" ]]; then
    log_error "$1 — ${_GS_ERR_BODY}"
  else
    log_error "$1"
  fi
}

# Legacy-Umgebungsvariablen: nur Namen melden, nie Werte (K6).
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

# ═══════════════════════════════════════════════════════════════════════════
# How-To-Ausgabe (A5): pro Schritt Methode/Pfad/Payload/HTTP-Code, ohne Werte.
# ═══════════════════════════════════════════════════════════════════════════
howto() {
  [[ -n "$HOWTO_FILE" ]] || return 0
  printf '%s\n' "$*" >&"$HOWTO_FD"
}

# howto_step "<Methode Pfad>" "<erwartet>" "<erhalten>" "<Beschreibung>"
howto_step() {
  howto "$1 (erwartet $2, erhalten $3)${4:+ — $4}"
}

# ═══════════════════════════════════════════════════════════════════════════
# Argumente
# ═══════════════════════════════════════════════════════════════════════════
usage() {
  printf 'Usage: bash ./%s [--dry-run] [--uninstall] [--url BASE] [--ns NAMESPACE] [--help|-h]\n' "$SCRIPT_NAME" >&2
  exit 2
}

print_help() {
  cat <<EOF
${SCRIPT_NAME} — GeoServer-Konfiguration: WFS-T-/WFS-Benutzer, Rollen, Kubernetes-Secrets, Workspaces, Datastores, FeatureTypes und Default-Styles.

Usage: bash ./${SCRIPT_NAME} [--dry-run] [--uninstall] [--url BASE] [--ns NAMESPACE] [--help|-h]

Optionen:
  --dry-run      Nur planen: keine Änderung an GeoServer oder Kubernetes.
  --uninstall    Genau die angelegten Benutzer/Rollen/Secrets/Workspaces/Datastores/FeatureTypes wieder entfernen.
  --url BASE     GeoServer-Basis-URL (z. B. https://geoportal.<domain>/geoserver).
  --ns NAMESPACE Kubernetes-Namespace (Standard: ADDON_NS bzw. cc-prd-geodata-stack).
  --help, -h     Diese Hilfe.

Umgebungsvariablen:
  GS_ADMIN_USER, GS_ADMIN_PW   Admin-Zugang für GeoServer-REST. Nur GEMEINSAM setzen;
                               sie haben Vorrang vor dem Secret geoserver-geoserver.

Exit-Codes: 0 = ok, 1 = Fehler, 2 = Aufruf-/Voraussetzungsfehler.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --url)
      [[ $# -ge 2 ]] || usage
      GS_BASE="${2%/}"; shift 2 ;;
    --ns)
      [[ $# -ge 2 ]] || usage
      NAMESPACE="$2"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *) log_error "Unbekanntes Argument: $1"; usage ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════
# Konfiguration auflösen (nur diese Schlüssel, nie Komplett-Export)
# ═══════════════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════════════
# Datastore-Konfiguration (C2): nur diese Schlüssel, keine Defaults im Skript.
# ═══════════════════════════════════════════════════════════════════════════
_DB_HOST=""
_DB_PORT=""
_DB_NAME=""

# _cfg_ok <wert> — 0 wenn gesetzt, nicht leer und nicht CHANGEME.
_cfg_ok() {
  local v="$1"
  [[ -n "$v" && "$v" != "CHANGEME" && "$v" != "changeme" ]]
}

# load_ds_config — löst die Datastore-Konfiguration auf (nur die benannten Schlüssel).
# Rückgabe 0 ok; 2 bei fehlendem/leerem/CHANGEME-Wert (vor jeder Mutation).
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

# ADDON_NS
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="${ADDON_NS:-}"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="$(_env_resolve ADDON_NS || true)"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="cc-prd-geodata-stack"
fi

# ADDON_DOMAIN (bzw. DOMAIN_NAME → udp.<DOMAIN_NAME>)
if [[ -z "$GS_BASE" ]]; then
  local_addon_domain="${ADDON_DOMAIN:-}"
  [[ -z "$local_addon_domain" ]] && local_addon_domain="$(_env_resolve ADDON_DOMAIN || true)"
  if [[ -z "$local_addon_domain" ]]; then
    local_domain_name="${DOMAIN_NAME:-}"
    [[ -z "$local_domain_name" ]] && local_domain_name="$(_env_resolve DOMAIN_NAME || true)"
    [[ -n "$local_domain_name" ]] && local_addon_domain="udp.${local_domain_name}"
  fi
  [[ -n "$local_addon_domain" ]] && GS_BASE="https://geoportal.${local_addon_domain}/geoserver"
fi
GS_REST="${GS_BASE}/rest"

# ═══════════════════════════════════════════════════════════════════════════
# Kubernetes-Secret-Helfer (selbsttragend; analog addon_03_secrets.sh)
# ═══════════════════════════════════════════════════════════════════════════
_secret_get() {
  local ns="$1" name="$2" key="$3"
  kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

_secret_apply() {
  local ns="$1" name="$2"; shift 2
  local manifest json kv k v b64 err
  manifest="$(mktemp)"
  json="$(kubectl -n "$ns" get secret "$name" -o json 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    json="$(printf '%s' "$json" | jq -c --arg n "$name" --arg ns "$ns" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:$ns},type:(.type // "Opaque"),data:(.data // {})}' 2>/dev/null || true)"
  fi
  [[ -n "$json" ]] || json="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name\",\"namespace\":\"$ns\"},\"type\":\"Opaque\",\"data\":{}}"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    b64="$(printf '%s' "$v" | base64 -w0)"
    json="$(printf '%s' "$json" | jq -c --arg k "$k" --arg v "$b64" '.data[$k] = $v')"
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

# ═══════════════════════════════════════════════════════════════════════════
# Passwort-Generator/Validierung (analog addon_03_secrets.sh)
# ═══════════════════════════════════════════════════════════════════════════
_pw_gen() { openssl rand -hex 24; }

_pw_is_valid() {
  local v="$1"
  [[ "${#v}" -ge 16 && ! "$v" =~ [^A-Za-z0-9._~@%+=:,/-] ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# GeoServer-REST (Credentials via curl -K - stdin, Body via mktemp 0600)
# ═══════════════════════════════════════════════════════════════════════════
# _curl_user_cfg <user> <pw> — gibt die Zeile `user = "..."` (escaped) auf stdout.
# Escaping gemäß curl -K: innerhalb der Anführungszeichen werden \" und \\ zu " bzw. \.
# Ein CR/LF im Wert würde eine weitere Konfigurationszeile einschleusen -> Fehler.
_curl_user_cfg() {
  local s="${1}:${2}"
  case "$s" in *$'\n'*|*$'\r'*) log_error "Zugangsdaten enthalten Zeilenumbruch"; return 1 ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf 'user = "%s"\n' "$s"
}

# _gs_http_code <method> <path> [<payload-file>] [<content-type>]
_gs_http_code() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" code
  if [[ -n "$payload" ]]; then
    code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || code="000"
  else
    code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X "$method" -H "Content-Type: $ctype" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || code="000"
  fi
  printf '%s' "$code"
}

# _gs_write_body <method> <path> [<payload-file>] [<content-type>] — Schreibaufruf
# (POST/PUT/DELETE) ohne usergroup. Setzt _GS_CODE und _GS_ERR_BODY (erste Antwortzeile,
# max. 200 Zeichen, R2). Wird DIREKT aufgerufen (nicht in einer Subshell), damit die
# globalen Variablen in der aufrufenden Shell ankommen.
_GS_ERR_BODY=""
_gs_write_body() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" tmp
  _GS_ERR_BODY=""
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if [[ -n "$payload" ]]; then
    _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" -o "$tmp" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
  else
    _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X "$method" -H "Content-Type: $ctype" -o "$tmp" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
  fi
  _GS_ERR_BODY="$(head -1 "$tmp" 2>/dev/null | cut -c1-200)"
  rm -f "$tmp"
}

# ═══════════════════════════════════════════════════════════════════════════
# Preflight
# ═══════════════════════════════════════════════════════════════════════════
preflight() {
  local cmd rc=0
  for cmd in kubectl jq curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Voraussetzung fehlt: $cmd"; rc=2; }
  done
  [[ "$rc" -eq 0 ]] || exit "$rc"

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

  local code
  code="$(_gs_http_code GET 'security/roles.json')"
  if [[ "$code" != "200" ]]; then
    log_error "GeoServer nicht erreichbar (GET security/roles.json -> $code, Benutzer $GS_ADMIN_USER, Passwort aus $pw_src): $GS_REST"
    exit 2
  fi
  log_ok "Preflight ok (Namespace ${NAMESPACE}, GeoServer ${GS_BASE})"
}

# ═══════════════════════════════════════════════════════════════════════════
# Bestand lesen (Benutzer + Rollen), nie Passwörter. Statusbewusst (K8):
# ein HTTP-Fehler ist ein Fehler, keine leere Liste.
# ═══════════════════════════════════════════════════════════════════════════
_GS_CODE=""      # global: HTTP-Code des letzten _gs_get
_GS_BODY_FILE=""  # global: Temp-Datei mit dem Body des letzten _gs_get

# _gs_get <path> — GET; setzt _GS_CODE und _GS_BODY_FILE (Body in Datei).
# Wird direkt (nicht in einer Kommando-Substitution) aufgerufen, damit die
# globalen Variablen in der aufrufenden Shell ankommen.
_gs_get() {
  local path="$1"
  _GS_BODY_FILE="$(mktemp)"; chmod 600 "$_GS_BODY_FILE"
  _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X GET -H "Content-Type: application/json" -o "$_GS_BODY_FILE" -w '%{http_code}' "$GS_REST/$path" 2>/dev/null )" || _GS_CODE="000"
}

# read_users — Benutzernamen (sortiert) auf stdout; 0 ok, 1 Lesefehler.
read_users() {
  _gs_get 'security/usergroup/users.json'
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen security/usergroup/users.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -e '.users | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { rm -f "$_GS_BODY_FILE"; log_error "security/usergroup/users.json: unerwartete JSON-Form"; return 1; }
  jq -r '.users[]?.userName // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  rm -f "$_GS_BODY_FILE"
}

# read_roles — Rollen (sortiert) auf stdout; 0 ok, 1 Lesefehler.
read_roles() {
  _gs_get 'security/roles.json'
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen security/roles.json fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -e '.roles | type == "array"' "$_GS_BODY_FILE" >/dev/null 2>&1 \
    || { rm -f "$_GS_BODY_FILE"; log_error "security/roles.json: unerwartete JSON-Form"; return 1; }
  jq -r '.roles[]? // empty' "$_GS_BODY_FILE" 2>/dev/null | sort
  rm -f "$_GS_BODY_FILE"
}

# read_user_roles <user> — Rollen eines Benutzers; 200/404 = ok (404 => leer).
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

# read_workspaces — Workspace-Namen (sortiert) auf stdout; 0 ok, 1 Fehler.
# Akzeptiert .workspaces.workspace als Array oder als ""/null (leer).
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

# read_namespace_uri <ws> — Namespace-URI auf stdout (leer bei Fehler); 0 ok, 1 Fehler.
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

# read_available_natives <ws> <ds> — verfügbare Native-Namen (list=available); 0 ok, 1 Fehler.
read_available_natives() {
  local ws="$1" ds="$2"
  _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes.json?list=available"
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "list=available für ${ws}/${ds} fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  jq -r '.list.string[]? // empty' "$_GS_BODY_FILE" 2>/dev/null
  rm -f "$_GS_BODY_FILE"
}

# read_featuretypes <ws> <ds> — publizierte FeatureType-Namen; 0 ok, 1 Fehler.
# Akzeptiert .featureTypes.featureType als Array, .featureTypes als ""/null (leer) und 404 (leer).
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

# read_datastores <ws> — Datastore-Namen (sortiert) für einen Workspace; 0 ok, 1 Fehler.
# Akzeptiert .dataStores.dataStore als Array, .dataStores als ""/null (leer) und 404 (leer).
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

# _ds_present <ws> <ds> — 0 wenn der Datastore existiert (der Workspace ist damit implizit vorhanden),
# 1 wenn nicht, 2 bei Lesefehler. read_datastores liefert 404 = leer (Workspace fehlt).
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

# _http_code_url <url> — authentifizierter GET auf eine beliebige URL; gibt HTTP-Code.
_http_code_url() {
  local url="$1" code
  code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -o /dev/null -w '%{http_code}' "$url" 2>/dev/null )" || code="000"
  printf '%s' "$code"
}

# _gs_get_url <url> — authentifizierter GET auf eine beliebige URL (z. B. WFS-Dienst);
# setzt _GS_CODE und _GS_BODY_FILE. Wird direkt aufgerufen (nicht in einer Subshell).
_gs_get_url() {
  local url="$1"
  _GS_BODY_FILE="$(mktemp)"; chmod 600 "$_GS_BODY_FILE"
  _GS_CODE="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -X GET -o "$_GS_BODY_FILE" -w '%{http_code}' "$url" 2>/dev/null )" || _GS_CODE="000"
}

# Globaler Bestand (K8), nach dem Preflight einmal gelesen.
_INV_USERS=()
_INV_ROLES=()
_USER_ROLES=()

# _read_user_roles_into <user> — liest Rollen in das globale Array _USER_ROLES; 0 ok, 1 Fehler.
_read_user_roles_into() {
  local user="$1" tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_user_roles "$user" > "$tmp"; then rm -f "$tmp"; return 1; fi
  mapfile -t _USER_ROLES < "$tmp"
  rm -f "$tmp"
  return 0
}

# _load_inventory — liest Benutzer+Rollen, prüft Plausibilität (admin/ADMIN).
# Rückgabe 0 ok; 2 bei Lesefehler oder Plausibilitätsfehler (vor jeder Mutation).
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

# _has <needle> <items...> — 0 wenn needle enthalten.
_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# _inventory_plausible <users_array_name> <roles_array_name> — 0 wenn Admin-Benutzer
# und ADMIN-Rolle vorhanden, sonst 1 (Meldung ohne Werte). Namerefs, bash >= 4.3.
_inventory_plausible() {
  local -n users="$1" roles="$2"
  _has "$GS_ADMIN_USER" "${users[@]}" || { log_error "Benutzerliste enthält nicht den Admin-Benutzer $GS_ADMIN_USER"; return 1; }
  _has "ADMIN" "${roles[@]}" || { log_error "Rollenliste enthält nicht die Rolle ADMIN"; return 1; }
  return 0
}

# Sicherheitsnetz: Soll-Tabelle darf nie admin/p2d2_wfst_user enthalten.
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

# Startprüfung: jeder Workspace aus SOL_TABLE (Spalte 2, außer "-") muss in WS_TABLE stehen.
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

# _ws_uri <ws> — Namespace-URI aus WS_TABLE; 0 ok, 1 nicht gefunden.
_ws_uri() {
  local want="$1" w uri
  while IFS='|' read -r w uri; do
    [[ -n "$w" ]] || continue
    [[ "$w" == "$want" ]] && { printf '%s' "$uri"; return 0; }
  done <<< "$WS_TABLE"
  return 1
}

# Startprüfung (C1): jeder DS_TABLE-KEY steht in SOL_TABLE, jeder Workspace in WS_TABLE.
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

# Startprüfung (D1): die eingebauten Default-Styles polygon/generic müssen existieren.
check_styles() {
  local style code
  for style in polygon generic; do
    code="$(_gs_http_code GET "styles/${style}.json")"
    [[ "$code" == "200" ]] || { log_error "Stil $style nicht vorhanden (GET styles/$style.json -> $code)"; return 1; }
  done
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Install
# ═══════════════════════════════════════════════════════════════════════════
do_install() {
  local -a existing_users existing_roles
  local line key _ user roles secret role password
  local f

  existing_users=("${_INV_USERS[@]}")
  existing_roles=("${_INV_ROLES[@]}")

  log "== Soll/Ist: Benutzer und Rollen =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    local ustate rstate
    ustate="fehlt"; _has "$user" "${existing_users[@]}" && ustate="vorhanden"
    rstate="vorhanden"
    for role in ${roles//,/ }; do
      _has "$role" "${existing_roles[@]}" || rstate="fehlt"
    done
    printf '  %-8s user=%-20s (%s)  rollen=%s\n' "$key" "$user" "$ustate" "$rstate"
  done <<< "$SOL_TABLE"

  # Rollen anlegen (idempotent)
  local -a all_roles
  all_roles=()
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      _has "$role" "${all_roles[@]}" || all_roles+=("$role")
    done
  done <<< "$SOL_TABLE"

  log "== Rollen =="
  for role in "${all_roles[@]}"; do
    if _has "$role" "${existing_roles[@]}"; then
      log "  Rolle vorhanden: $role"
    else
      log "  Rolle anlegen: $role"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "POST security/roles/role/$role" "200/201" "-" "idempotent"
        continue
      fi
      local code
      code="$(_gs_http_code POST "security/roles/role/$role")"
      howto_step "POST security/roles/role/$role" "200/201" "$code" "idempotent"
      [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Rolle $role anlegen fehlgeschlagen (HTTP $code)"; return 1; }
      log_ok "  Rolle $role angelegt"
    fi
  done

  log "== Benutzer + Secrets =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue

    # Passwort aus Secret übernehmen oder erzeugen (Secret = Single Source of Truth).
    # Kein Env-Stage (E3): nur Secret -> erzeugt.
    password="$(_secret_get "$NAMESPACE" "$secret" "password")"
    if _pw_is_valid "$password"; then
      log "  ${key}: Secret-Wert wiederverwendet"
    else
      password="$(_pw_gen)"
      log "  ${key}: neues Passwort erzeugt"
      howto "kubectl -n $NAMESPACE apply secret $secret (Key password) — Wert nicht ausgegeben"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! _secret_apply "$NAMESPACE" "$secret" "password=$password"; then
          log_error "Secret $secret konnte nicht gespeichert werden — Abbruch vor GeoServer-Änderung"
          return 1
        fi
      fi
    fi

    # GeoServer: Benutzer anlegen oder Passwort setzen.
    local uexists
    uexists="nein"; _has "$user" "${existing_users[@]}" && uexists="ja"

    if [[ "$uexists" == "nein" ]]; then
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><userName>%s</userName><password>%s</password><enabled>true</enabled></user>\n' "$user" "$password" > "$f"
        local code
        code="$(_gs_http_code POST 'security/usergroup/users' "$f" 'text/xml')"
        rm -f "$f"
        howto_step "POST security/usergroup/users" "200/201" "$code" "XML <user><userName>$user</userName><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml"
        [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Benutzer $user anlegen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Benutzer $user angelegt"
      else
        howto_step "POST security/usergroup/users" "200/201" "-" "XML <user><userName>$user</userName><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml (geplant)"
        log "  Benutzer $user würde angelegt (dry-run)"
      fi
    else
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><password>%s</password><enabled>true</enabled></user>\n' "$password" > "$f"
        local code
        code="$(_gs_http_code POST "security/usergroup/user/$user" "$f" 'text/xml')"
        rm -f "$f"
        howto_step "POST security/usergroup/user/$user" "200" "$code" "XML <user><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml — Passwort setzen, Benutzer aktivieren"
        [[ "$code" == "200" ]] || { log_error "Passwort für $user setzen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Passwort für $user gesetzt"
      else
        howto_step "POST security/usergroup/user/$user" "200" "-" "XML <user><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml — Passwort setzen, Benutzer aktivieren (geplant)"
        log "  Passwort für $user würde gesetzt (dry-run)"
      fi
    fi

    # Rollen zuordnen (idempotent, POST)
    for role in ${roles//,/ }; do
      if [[ "$DRY_RUN" -eq 0 ]]; then
        local code
        code="$(_gs_http_code POST "security/roles/role/$role/user/$user")"
        howto_step "POST security/roles/role/$role/user/$user" "200" "$code" "idempotent"
        [[ "$code" == "200" ]] || { log_error "Zuordnung $role -> $user fehlgeschlagen (HTTP $code)"; return 1; }
      else
        howto_step "POST security/roles/role/$role/user/$user" "200" "-" "idempotent (geplant)"
      fi
    done
  done <<< "$SOL_TABLE"

  # Workspaces anlegen (Schritt 2, nach Benutzern/Rollen/Zuordnungen)
  install_workspaces || return 1

  # Datastores anlegen (Schritt 3)
  install_datastores || return 1

  # FeatureTypes anlegen (Schritt 4)
  install_featuretypes || return 1

  # Verifikation (im Dry-run übersprungen, K1)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  Verifikation wird im Dry-run übersprungen"
  else
    verify_install || return 1
    verify_workspaces || return 1
    verify_datastores || return 1
    verify_featuretypes || return 1
  fi
  return 0
}

verify_install() {
  local line key _ user roles secret password code neg
  log "== Verifikation =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    password="$(_secret_get "$NAMESPACE" "$secret" "password")"
    [[ -n "$password" ]] || { log_error "Verifikation $key: kein Passwort im Secret"; return 1; }

    # Positivtest (authentifizierter GetCapabilities) — Credentials via curl -K - (stdin)
    code="$( _curl_user_cfg "$user" "$password" | curl -sS -K - -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || code="000"

    # Negativtest (falsches Passwort muss 401 liefern)
    neg="$( _curl_user_cfg "$user" "falsch_${password}" | curl -sS -K - -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || neg="000"

    if [[ "$code" != "200" ]]; then
      log_error "Verifikation $key: GetCapabilities HTTP $code (erwartet 200)"
      return 1
    fi
    if [[ "$neg" == "200" ]]; then
      log_warn "Verifikation $key: Negativtest lieferte 200 — Positivprüfung nicht aussagekräftig"
    elif [[ "$neg" != "401" ]]; then
      log_warn "Verifikation $key: Negativtest HTTP $neg (erwartet 401)"
    else
      log_ok "  $key: 200 (positiv), 401 (negativ) — Anmeldung wird ausgewertet"
    fi

    # Rollenliste je Benutzer (Soll ⊆ Ist)
    if ! _read_user_roles_into "$user"; then
      log_error "Verifikation $key: Rollen für $user nicht lesbar"
      return 1
    fi
    for role in ${roles//,/ }; do
      _has "$role" "${_USER_ROLES[@]}" || { log_error "Verifikation $key: Rolle $role fehlt bei $user"; return 1; }
    done
  done <<< "$SOL_TABLE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Workspaces (Schritt 2): anlegen / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════
install_workspaces() {
  local -a existing
  local ws uri cur code rc=0 f
  local tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_workspaces > "$tmp"; then
    rm -f "$tmp"; log_error "Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t existing < "$tmp"
  rm -f "$tmp"

  log "== Workspaces =="
  while IFS='|' read -r ws uri; do
    [[ -n "$ws" ]] || continue
    if ! _has "$ws" "${existing[@]}"; then
      log "  Workspace $ws anlegen"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "POST namespaces" "201" "-" "JSON {\"namespace\":{\"prefix\":\"$ws\",\"uri\":\"$uri\"}}"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      jq -nc --arg p "$ws" --arg u "$uri" '{namespace:{prefix:$p,uri:$u}}' > "$f"
      _gs_write_body POST 'namespaces' "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "POST namespaces" "201" "$code" "JSON {\"namespace\":{\"prefix\":\"$ws\",\"uri\":\"$uri\"}}"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_ok "  Workspace $ws angelegt"
      else
        log_gs_error "Workspace $ws anlegen fehlgeschlagen (HTTP $code)"; rc=1
      fi
    else
      if ! cur="$(read_namespace_uri "$ws")"; then
        log_error "Workspace $ws: Namespace nicht lesbar"; rc=1
        continue
      fi
      if [[ -z "$cur" ]]; then
        log_error "Workspace $ws vorhanden, aber Namespace fehlt"; rc=1
      elif [[ "$cur" != "$uri" ]]; then
        log_error "Workspace $ws: Namespace-URI weicht ab (erwartet $uri, vorhanden $cur)"; rc=1
      else
        log "  Workspace $ws vorhanden, URI stimmt"
      fi
    fi
  done <<< "$WS_TABLE"
  return "$rc"
}

verify_workspaces() {
  local ws uri cur code rc=0 name
  log "== Verifikation Workspaces =="
  while IFS='|' read -r ws uri; do
    [[ -n "$ws" ]] || continue
    # Namespace-URI
    _gs_get "namespaces/${ws}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      cur="$(jq -r '.namespace.uri // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET namespaces/$ws.json" "200" "200" "URI prüfen"
      if [[ "$cur" == "$uri" ]]; then
        log_ok "  $ws: Namespace-URI ok"
      else
        log_error "Verifikation $ws: Namespace-URI weicht ab (erwartet $uri, vorhanden $cur)"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET namespaces/$ws.json" "200" "$code" "URI prüfen"
      log_error "Verifikation $ws: GET namespaces/$ws.json -> $code (erwartet 200)"; rc=1
    fi
    # Workspace vorhanden und name stimmt
    _gs_get "workspaces/${ws}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      name="$(jq -r '.workspace.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws.json" "200" "200" "name prüfen"
      if [[ "$name" == "$ws" ]]; then
        log_ok "  $ws: Workspace-name ok"
      else
        log_error "Verifikation $ws: workspaces/$ws.json name weicht ab (erwartet $ws, erhalten $name)"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws.json" "200" "$code" "name prüfen"
      log_error "Verifikation $ws: GET workspaces/$ws.json -> $code (erwartet 200)"; rc=1
    fi
    # Virtuelle Dienste (hart, R7)
    code="$(_http_code_url "$GS_BASE/$ws/wms?service=WMS&version=1.3.0&request=GetCapabilities")"
    howto_step "GET $ws/wms GetCapabilities" "200" "$code" "Dienstprüfung"
    if [[ "$code" == "200" ]]; then log_ok "  $ws: WMS GetCapabilities 200"; else log_error "Verifikation $ws: WMS GetCapabilities -> $code (erwartet 200)"; rc=1; fi
    if [[ "$ws" != "friedhofsplaene" ]]; then
      code="$(_http_code_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetCapabilities")"
      howto_step "GET $ws/wfs GetCapabilities" "200" "$code" "Dienstprüfung"
      if [[ "$code" == "200" ]]; then log_ok "  $ws: WFS GetCapabilities 200"; else log_error "Verifikation $ws: WFS GetCapabilities -> $code (erwartet 200)"; rc=1; fi
    fi
  done <<< "$WS_TABLE"
  return "$rc"
}

uninstall_workspaces() {
  local -a existing
  local ws code rc=0
  local tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_workspaces > "$tmp"; then
    rm -f "$tmp"; log_error "Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t existing < "$tmp"
  rm -f "$tmp"

  log "== Workspaces entfernen =="
  while IFS='|' read -r ws _; do
    [[ -n "$ws" ]] || continue
    if ! _has "$ws" "${existing[@]}"; then
      log "  Workspace $ws nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      howto_step "DELETE workspaces/$ws" "200" "-" "404 = schon weg, ohne recurse"
      continue
    fi
    _gs_write_body DELETE "workspaces/${ws}"
    code="$_GS_CODE"
    howto_step "DELETE workspaces/$ws" "200" "$code" "404 = schon weg, ohne recurse"
    case "$code" in
      200|201) log_ok "  Workspace $ws gelöscht" ;;
      404)     log "  Workspace $ws schon weg" ;;
      *)       log_gs_error "Workspace $ws löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$WS_TABLE"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# Datastores (Schritt 3): anlegen / aktualisieren / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════
# _ds_body <name> <schema> <host> <port> <db> <user> <ns> <password> <outfile>
# Baut den vollständigen PostGIS-Datastore-Body (20 Parameter). Das Passwort wird
# nur per --rawfile über Prozesssubstitution eingelesen (printf ist Builtin), damit
# es in keiner Argumentliste von jq auftaucht (C3).
_ds_body() {
  local name="$1" schema="$2" host="$3" port="$4" db="$5" user="$6" ns="$7" pw="$8" out="$9"
  jq -n \
    --rawfile pw <(printf '%s' "$pw") \
    --arg name "$name" --arg schema "$schema" --arg host "$host" --arg port "$port" \
    --arg db "$db" --arg user "$user" --arg ns "$ns" \
    '{dataStore:{name:$name,type:"PostGIS",enabled:true,disableOnConnFailure:false,
      connectionParameters:{entry:[
        {"@key":"schema","$":$schema},
        {"@key":"Estimated extends","$":"false"},
        {"@key":"fetch size","$":"1000"},
        {"@key":"encode functions","$":"false"},
        {"@key":"Expose primary keys","$":"true"},
        {"@key":"validate connections","$":"true"},
        {"@key":"Support on the fly geometry simplification","$":"false"},
        {"@key":"Connection timeout","$":"20"},
        {"@key":"create database","$":"false"},
        {"@key":"preparedStatements","$":"false"},
        {"@key":"database","$":$db},
        {"@key":"reWriteBatchedInserts","$":"false"},
        {"@key":"port","$":$port},
        {"@key":"passwd","$":$pw},
        {"@key":"dbtype","$":"postgis"},
        {"@key":"host","$":$host},
        {"@key":"namespace","$":$ns},
        {"@key":"Loose bbox","$":"false"},
        {"@key":"Test while idle","$":"false"},
        {"@key":"user","$":$user}
      ]}}}' > "$out"
}

install_datastores() {
  local -a existing
  local key ws ds schema uservar secret uri user password code rc=0 f tmp
  log "== Datastores =="
  log "  Basis: host=${_DB_HOST} port=${_DB_PORT} db=${_DB_NAME}"
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    uri="$(_ws_uri "$ws")"
    user="$(_env_resolve "$uservar")"
    password="$(_secret_get "$NAMESPACE" "$secret" "DB_PASSWORD")"
    if ! _pw_is_valid "$password"; then
      log_error "Datastore $ds: kein gültiges DB_PASSWORD im Secret $secret"
      rc=1
      continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_datastores "$ws" > "$tmp"; then
      rm -f "$tmp"; log_error "Datastore-Liste für $ws nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"
    rm -f "$tmp"
    if ! _has "$ds" "${existing[@]}"; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] $ds würde angelegt (schema=$schema, user=$user)"
        howto_step "POST workspaces/$ws/datastores" "201" "-" "JSON (20 Parameter, passwd=<PASSWORD>); schema=$schema user=$user host=${_DB_HOST} port=${_DB_PORT} db=${_DB_NAME}"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      _ds_body "$ds" "$schema" "$_DB_HOST" "$_DB_PORT" "$_DB_NAME" "$user" "$uri" "$password" "$f"
      _gs_write_body POST "workspaces/${ws}/datastores" "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "POST workspaces/$ws/datastores" "201" "$code" "JSON (20 Parameter, passwd=<PASSWORD>)"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_ok "  Datastore $ds angelegt"
      else
        log_gs_error "Datastore $ds anlegen fehlgeschlagen (HTTP $code)"; rc=1
      fi
    else
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] $ds würde aktualisiert (schema=$schema, user=$user)"
        howto_step "PUT workspaces/$ws/datastores/$ds" "200" "-" "JSON (20 Parameter, passwd=<PASSWORD>)"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      _ds_body "$ds" "$schema" "$_DB_HOST" "$_DB_PORT" "$_DB_NAME" "$user" "$uri" "$password" "$f"
      _gs_write_body PUT "workspaces/${ws}/datastores/${ds}" "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "PUT workspaces/$ws/datastores/$ds" "200" "$code" "JSON (20 Parameter, passwd=<PASSWORD>)"
      if [[ "$code" == "200" ]]; then
        log_ok "  Datastore $ds aktualisiert"
      else
        log_gs_error "Datastore $ds aktualisieren fehlgeschlagen (HTTP $code)"; rc=1
      fi
    fi
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_datastores() {
  local key ws ds schema uservar secret uri user code rc=0 cnt diag
  local en get_schema get_user get_db get_host get_ns
  log "== Verifikation Datastores =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    uri="$(_ws_uri "$ws")"
    user="$(_env_resolve "$uservar")"
    _gs_get "workspaces/${ws}/datastores/${ds}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      en="$(jq -r '.dataStore.enabled // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      get_schema="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="schema") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_user="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="user") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_db="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="database") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_host="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="host") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_ns="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="namespace") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds.json" "200" "200" "Parameter prüfen"
      if [[ "$en" == "true" && "$get_schema" == "$schema" && "$get_user" == "$user" && "$get_db" == "$_DB_NAME" && "$get_host" == "$_DB_HOST" && "$get_ns" == "$uri" ]]; then
        log_ok "  $ds: Parameter ok"
      else
        diag=""
        [[ "$en" == "true" ]] || diag+=" enabled(erwartet true, vorhanden $en)"
        [[ "$get_schema" == "$schema" ]] || diag+=" schema(erwartet $schema, vorhanden $get_schema)"
        [[ "$get_user" == "$user" ]] || diag+=" user(erwartet $user, vorhanden $get_user)"
        [[ "$get_db" == "$_DB_NAME" ]] || diag+=" database(erwartet $_DB_NAME, vorhanden $get_db)"
        [[ "$get_host" == "$_DB_HOST" ]] || diag+=" host(erwartet $_DB_HOST, vorhanden $get_host)"
        [[ "$get_ns" == "$uri" ]] || diag+=" namespace(erwartet $uri, vorhanden $get_ns)"
        log_error "Verifikation $ds: Parameter weichen ab:$diag"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds.json" "200" "$code" "Parameter prüfen"
      log_error "Verifikation $ds: GET workspaces/$ws/datastores/$ds.json -> $code (erwartet 200)"; rc=1
    fi
    # Verbindungstest: list=available erzwingt DB-Verbindung (Statuscode hart, Form tolerant).
    _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes.json?list=available"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      cnt="$(jq -r '.list.string[]? // empty' "$_GS_BODY_FILE" 2>/dev/null | awk 'END{print NR}')"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds/featuretypes.json?list=available" "200" "200" "DB-Verbindungstest"
      log_ok "  $ds: list=available 200 ($cnt Namen)"
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds/featuretypes.json?list=available" "200" "$code" "DB-Verbindungstest"
      log_error "Verifikation $ds: list=available -> $code (erwartet 200)"; rc=1
    fi
  done <<< "$DS_TABLE"
  return "$rc"
}

uninstall_datastores() {
  local -a existing
  local key ws ds schema uservar secret code rc=0 tmp
  log "== Datastores entfernen =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_datastores "$ws" > "$tmp"; then
      rm -f "$tmp"; log_error "Datastore-Liste für $ws nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"
    rm -f "$tmp"
    if ! _has "$ds" "${existing[@]}"; then
      log "  Datastore $ds nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      howto_step "DELETE workspaces/$ws/datastores/$ds" "200" "-" "404 = schon weg, ohne recurse"
      continue
    fi
    _gs_write_body DELETE "workspaces/${ws}/datastores/${ds}"
    code="$_GS_CODE"
    howto_step "DELETE workspaces/$ws/datastores/$ds" "200" "$code" "404 = schon weg, ohne recurse"
    case "$code" in
      200|201) log_ok "  Datastore $ds gelöscht" ;;
      404)     log "  Datastore $ds schon weg" ;;
      *)       log_gs_error "Datastore $ds löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$DS_TABLE"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# FeatureTypes + Default-Styles (Schritt 4): anlegen / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════
# _ft_title <template> <ws> — ersetzt %ws% im Titelmuster durch den Workspace-Namen.
_ft_title() {
  local t="$1" ws="$2"
  printf '%s' "${t//%ws%/$ws}"
}

# _ft_body <name> <native> <ws> <title> <cache> <outfile> — FeatureType-Body (kein Passwort).
_ft_body() {
  local name="$1" native="$2" ws="$3" title="$4" cache="$5" out="$6"
  if [[ "$cache" == "false" ]]; then
    jq -n --arg ws "$ws" --arg name "$name" --arg native "$native" --arg title "$title" \
      '{featureType:{name:$name,nativeName:$native,namespace:{name:$ws},title:$title,
        keywords:{string:["features",$native]},srs:"EPSG:4326",projectionPolicy:"FORCE_DECLARED",
        enabled:true,advertised:true,
        nativeBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        latLonBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        metadata:{entry:{"@key":"cachingEnabled","$":"false"}}}}' > "$out"
  else
    jq -n --arg ws "$ws" --arg name "$name" --arg native "$native" --arg title "$title" \
      '{featureType:{name:$name,nativeName:$native,namespace:{name:$ws},title:$title,
        keywords:{string:["features",$native]},srs:"EPSG:4326",projectionPolicy:"FORCE_DECLARED",
        enabled:true,advertised:true,
        nativeBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        latLonBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"}}}' > "$out"
  fi
}

# _ft_cmp <body-file> <ws> <name> <native> <title> <cache> — 0 wenn alle nicht generierten
# Felder stimmen, sonst 1. Abweichungen werden als Info (log) gemeldet; erst ein fehlgeschlagener
# PUT ist ein Fehler (B5). Bounding-Box-Vergleich numerisch; metadata.entry als Objekt ODER Array.
_ft_cmp() {
  local f="$1" ws="$2" name="$3" native="$4" title="$5" cache="$6" dev=0 v
  v="$(jq -r '.featureType.nativeName // empty' "$f" 2>/dev/null)"
  [[ "$v" == "$native" ]] || { log "  FeatureType $ws/$name: nativeName weicht ab (erwartet $native, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.title // empty' "$f" 2>/dev/null)"
  [[ "$v" == "$title" ]] || { log "  FeatureType $ws/$name: title weicht ab (erwartet $title, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.srs // empty' "$f" 2>/dev/null)"
  [[ "$v" == "EPSG:4326" ]] || { log "  FeatureType $ws/$name: srs weicht ab (erwartet EPSG:4326, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.projectionPolicy // empty' "$f" 2>/dev/null)"
  [[ "$v" == "FORCE_DECLARED" ]] || { log "  FeatureType $ws/$name: projectionPolicy weicht ab (erwartet FORCE_DECLARED, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.enabled // empty' "$f" 2>/dev/null)"
  [[ "$v" == "true" ]] || { log "  FeatureType $ws/$name: enabled weicht ab (erwartet true, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.advertised // empty' "$f" 2>/dev/null)"
  [[ "$v" == "true" ]] || { log "  FeatureType $ws/$name: advertised weicht ab (erwartet true, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  jq -e '.featureType.nativeBoundingBox | (.minx==-10 and .maxx==40 and .miny==35 and .maxy==71)' "$f" >/dev/null 2>&1 \
    || { log "  FeatureType $ws/$name: nativeBoundingBox weicht ab — wird per PUT angepasst"; dev=1; }
  jq -e '.featureType.latLonBoundingBox | (.minx==-10 and .maxx==40 and .miny==35 and .maxy==71)' "$f" >/dev/null 2>&1 \
    || { log "  FeatureType $ws/$name: latLonBoundingBox weicht ab — wird per PUT angepasst"; dev=1; }
  if [[ "$cache" == "false" ]]; then
    v="$(jq -r '[.featureType.metadata.entry] | flatten | map(select(."@key"=="cachingEnabled")) | .[0]."$" // empty' "$f" 2>/dev/null)"
    [[ "$v" == "false" ]] || { log "  FeatureType $ws/$name: cachingEnabled weicht ab (erwartet false, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  fi
  return "$dev"
}

# _ensure_default_style <ws> <name> <style> — setzt bei Abweichung den Layer-Default-Style.
_ensure_default_style() {
  local ws="$1" name="$2" style="$3" code cur f
  _gs_get "workspaces/${ws}/layers/${name}.json"
  code="$_GS_CODE"
  if [[ "$code" == "200" ]]; then
    cur="$(jq -r '.layer.defaultStyle.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
    rm -f "$_GS_BODY_FILE"
    howto_step "GET workspaces/$ws/layers/$name.json" "200" "200" "defaultStyle prüfen $ws/$name"
    if [[ "$cur" == "$style" ]]; then
      log "  $ws/$name: Default-Style ok ($style)"
      return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] $ws/$name: Default-Style $style würde gesetzt (vorhanden $cur)"
      howto_step "PUT workspaces/$ws/layers/$name" "200" "-" "defaultStyle $ws/$name=$style"
      return 0
    fi
    f="$(mktemp)"; chmod 600 "$f"
    jq -nc --arg s "$style" '{layer:{defaultStyle:{name:$s}}}' > "$f"
    _gs_write_body PUT "workspaces/${ws}/layers/${name}" "$f" 'application/json'
    code="$_GS_CODE"; rm -f "$f"
    howto_step "PUT workspaces/$ws/layers/$name" "200" "$code" "defaultStyle $ws/$name=$style"
    [[ "$code" == "200" ]] || { log_gs_error "$ws/$name Default-Style setzen fehlgeschlagen (HTTP $code)"; return 1; }
    log_ok "  $ws/$name: Default-Style $style gesetzt"
  elif [[ "$code" == "404" ]]; then
    rm -f "$_GS_BODY_FILE"
    howto_step "GET workspaces/$ws/layers/$name.json" "200" "404" "defaultStyle prüfen $ws/$name"
    log "  $ws/$name nicht vorhanden (wird mit dem FeatureType angelegt)"
  else
    rm -f "$_GS_BODY_FILE"
    log_error "$ws/$name lesen fehlgeschlagen (HTTP $code)"; return 1
  fi
  return 0
}

install_featuretypes() {
  local -a existing avail
  local key ws ds schema uservar secret name native tpl cache style title code rc=0 f tmp dsp
  log "== FeatureTypes =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    _ds_present "$ws" "$ds"; dsp=$?
    if [[ "$dsp" -eq 2 ]]; then
      log_error "FeatureTypes $ws/$ds: Datastore-Präsenz nicht lesbar"; rc=1; continue
    fi
    if [[ "$dsp" -eq 1 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        while IFS='|' read -r name native tpl cache style; do
          [[ -n "$name" ]] || continue
          title="$(_ft_title "$tpl" "$ws")"
          log "  [dry-run] $ws/$name würde angelegt (Datastore wird zuvor angelegt; native=$native erst danach prüfbar)"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "-" "FeatureType $ws/$name (native=$native)"
          log "  [dry-run] $ws/$name: Default-Style $style würde gesetzt"
          howto_step "PUT workspaces/$ws/layers/$name" "200" "-" "defaultStyle $ws/$name=$style"
        done <<< "$FT_TABLE"
      else
        log_error "FeatureTypes $ws/$ds: Datastore nicht vorhanden"; rc=1
      fi
      continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_available_natives "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "list=available für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t avail < "$tmp"; rm -f "$tmp"
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_featuretypes "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "FeatureType-Liste für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"; rm -f "$tmp"
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      title="$(_ft_title "$tpl" "$ws")"
      if ! _has "$native" "${avail[@]}" && ! _has "$name" "${existing[@]}"; then
        log_error "FeatureType $ws/$name: Native-Name $native nicht in list=available"
        rc=1
        continue
      fi
      if ! _has "$name" "${existing[@]}"; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "  [dry-run] $ws/$name würde angelegt (title=$title)"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "-" "FeatureType $ws/$name (native=$native)"
        else
          f="$(mktemp)"; chmod 600 "$f"
          _ft_body "$name" "$native" "$ws" "$title" "$cache" "$f"
          _gs_write_body POST "workspaces/${ws}/datastores/${ds}/featuretypes" "$f" 'application/json'
          code="$_GS_CODE"; rm -f "$f"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "$code" "FeatureType $ws/$name"
          if [[ "$code" == "200" || "$code" == "201" ]]; then
            log_ok "  $ws/$name angelegt"
          else
            log_gs_error "FeatureType $ws/$name anlegen fehlgeschlagen (HTTP $code)"; rc=1
          fi
        fi
      else
        if [[ "$DRY_RUN" -eq 1 ]]; then
          howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "-" "Vergleich $ws/$name"
        else
          _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
          if [[ "$_GS_CODE" == "200" ]]; then
            if _ft_cmp "$_GS_BODY_FILE" "$ws" "$name" "$native" "$title" "$cache"; then
              rm -f "$_GS_BODY_FILE"
              log "  $ws/$name vorhanden, unverändert"
            else
              rm -f "$_GS_BODY_FILE"
              f="$(mktemp)"; chmod 600 "$f"
              _ft_body "$name" "$native" "$ws" "$title" "$cache" "$f"
              _gs_write_body PUT "workspaces/${ws}/datastores/${ds}/featuretypes/${name}" "$f" 'application/json'
              code="$_GS_CODE"; rm -f "$f"
              howto_step "PUT workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "$code" "FeatureType $ws/$name"
              [[ "$code" == "200" ]] || { log_gs_error "FeatureType $ws/$name aktualisieren fehlgeschlagen (HTTP $code)"; rc=1; }
            fi
          else
            rm -f "$_GS_BODY_FILE"
            log_error "FeatureType $ws/$name: GET -> $_GS_CODE (erwartet 200)"; rc=1
          fi
        fi
      fi
      _ensure_default_style "$ws" "$name" "$style" || rc=1
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_featuretypes() {
  local key ws ds schema uservar secret name native tpl cache style title code rc=0
  log "== Verifikation FeatureTypes =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      title="$(_ft_title "$tpl" "$ws")"
      _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]]; then
        local en adv nn tt ss
        en="$(jq -r '.featureType.enabled // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        adv="$(jq -r '.featureType.advertised // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        nn="$(jq -r '.featureType.nativeName // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        tt="$(jq -r '.featureType.title // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        ss="$(jq -r '.featureType.srs // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "200" "verifizieren $ws/$name"
        if [[ "$en" == "true" && "$adv" == "true" && "$nn" == "$native" && "$tt" == "$title" && "$ss" == "EPSG:4326" ]]; then
          log_ok "  $ws/$name: FeatureType ok"
        else
          log_error "Verifikation $ws/$name: FeatureType weicht ab"; rc=1
        fi
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "$code" "verifizieren $ws/$name"
        log_error "Verifikation $ws/$name: FeatureType GET -> $code (erwartet 200)"; rc=1
      fi
      _gs_get "workspaces/${ws}/layers/${name}.json"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]]; then
        local dstyle
        dstyle="$(jq -r '.layer.defaultStyle.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/layers/$name.json" "200" "200" "defaultStyle verifizieren $ws/$name"
        if [[ "$dstyle" == "$style" ]]; then
          log_ok "  $ws/$name: defaultStyle $style ok"
        else
          log_error "Verifikation $ws/$name: defaultStyle weicht ab (erwartet $style, vorhanden $dstyle)"; rc=1
        fi
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/layers/$name.json" "200" "$code" "defaultStyle verifizieren $ws/$name"
        log_error "Verifikation $ws/$name: Layer GET -> $code (erwartet 200)"; rc=1
      fi
      _gs_get_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=DescribeFeatureType&typeNames=${ws}:${name}"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]] && ! grep -q 'ExceptionReport' "$_GS_BODY_FILE" 2>/dev/null; then
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs DescribeFeatureType" "200" "200" "kein ExceptionReport $ws/$name"
        log_ok "  $ws/$name: DescribeFeatureType ok"
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs DescribeFeatureType" "200" "$code" "kein ExceptionReport $ws/$name"
        log_error "Verifikation $ws/$name: DescribeFeatureType -> $code (erwartet 200, kein ExceptionReport)"; rc=1
      fi
      _gs_get_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=${ws}:${name}&resultType=hits"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]] && ! grep -q 'ExceptionReport' "$_GS_BODY_FILE" 2>/dev/null; then
        local nm
        nm="$(grep -o 'numberMatched="[0-9]*"' "$_GS_BODY_FILE" 2>/dev/null | head -1)"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs GetFeature hits" "200" "200" "kein ExceptionReport $ws/$name"
        log_ok "  $ws/$name: GetFeature hits ok${nm:+ ($nm)}"
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs GetFeature hits" "200" "$code" "kein ExceptionReport $ws/$name"
        log_error "Verifikation $ws/$name: GetFeature hits -> $code (erwartet 200, kein ExceptionReport)"; rc=1
      fi
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

uninstall_featuretypes() {
  local -a existing
  local key ws ds schema uservar secret name native tpl cache style code rc=0 tmp dsp
  log "== FeatureTypes entfernen =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    _ds_present "$ws" "$ds"; dsp=$?
    if [[ "$dsp" -eq 1 ]]; then
      log "  FeatureTypes von $ws/$ds nicht prüfbar (Datastore nicht vorhanden) — übersprungen"
      continue
    fi
    if [[ "$dsp" -eq 2 ]]; then
      log_error "FeatureTypes $ws/$ds: Datastore-Präsenz nicht lesbar"; rc=1; continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_featuretypes "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "FeatureType-Liste für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"; rm -f "$tmp"
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      if ! _has "$name" "${existing[@]}"; then
        log "  $ws/$name nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "DELETE workspaces/$ws/layers/$name" "200" "-" "404 = schon weg, ohne recurse ($ws/$name)"
        howto_step "DELETE workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "-" "404 = schon weg, ohne recurse ($ws/$name)"
        continue
      fi
      _gs_write_body DELETE "workspaces/${ws}/layers/${name}"
      code="$_GS_CODE"
      howto_step "DELETE workspaces/$ws/layers/$name" "200" "$code" "404 = schon weg, ohne recurse ($ws/$name)"
      case "$code" in
        200|201) log_ok "  $ws/$name: Layer gelöscht" ;;
        404)     log "  $ws/$name: Layer schon weg" ;;
        *)       log_gs_error "Layer $ws/$name löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
      _gs_write_body DELETE "workspaces/${ws}/datastores/${ds}/featuretypes/${name}"
      code="$_GS_CODE"
      howto_step "DELETE workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "$code" "404 = schon weg, ohne recurse ($ws/$name)"
      case "$code" in
        200|201) log_ok "  $ws/$name: FeatureType gelöscht" ;;
        404)     log "  $ws/$name: FeatureType schon weg" ;;
        *)       log_gs_error "FeatureType $ws/$name löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# Uninstall (nur exakt benannte Objekte)
# ═══════════════════════════════════════════════════════════════════════════
do_uninstall() {
  local line key _ user roles secret code rc=0 role
  local -a existing_users existing_roles
  log "== Uninstall =="

  # Bestand aus _load_inventory (in main gelesen + plausibel geprüft, K8).
  existing_users=("${_INV_USERS[@]}")
  existing_roles=("${_INV_ROLES[@]}")

  # 0) FeatureTypes/Layer entfernen (Reihenfolge umgekehrt zum Install; vor Datastores)
  uninstall_featuretypes || rc=1

  # 0b) Datastores entfernen (vor Workspaces)
  uninstall_datastores || rc=1

  # 0b) Workspaces entfernen (vor Benutzern/Rollen/Secrets)
  uninstall_workspaces || rc=1

  # 1) Rollenzuordnungen lösen (nur vorhandene)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if ! _read_user_roles_into "$user"; then
      log_error "Rollen für $user nicht lesbar — Zuordnungen übersprungen"
      rc=1
      continue
    fi
    for role in ${roles//,/ }; do
      if ! _has "$role" "${_USER_ROLES[@]}"; then
        log "  Zuordnung $role/$user nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "DELETE security/roles/role/$role/user/$user" "200" "-" "404 = schon weg"
        continue
      fi
      _gs_write_body DELETE "security/roles/role/$role/user/$user"
      code="$_GS_CODE"
      howto_step "DELETE security/roles/role/$role/user/$user" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Zuordnung $role/$user gelöst" ;;
        404)     log "  Zuordnung $role/$user schon weg" ;;
        *)       log_gs_error "Zuordnung $role/$user lösen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  # 2) Benutzer löschen (nur vorhandene)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if ! _has "$user" "${existing_users[@]}"; then
      log "  Benutzer $user nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      howto_step "DELETE security/usergroup/user/$user" "200" "-" "404 = schon weg"
      continue
    fi
    _gs_write_body DELETE "security/usergroup/user/$user"
    code="$_GS_CODE"
    howto_step "DELETE security/usergroup/user/$user" "200" "$code" "404 = schon weg"
    case "$code" in
      200|201) log_ok "  Benutzer $user gelöscht" ;;
      404)     log "  Benutzer $user schon weg" ;;
      *)       log_gs_error "Benutzer $user löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$SOL_TABLE"

  # 3) Rollen löschen (nur vorhandene)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      if ! _has "$role" "${existing_roles[@]}"; then
        log "  Rolle $role nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "DELETE security/roles/role/$role" "200" "-" "404 = schon weg"
        continue
      fi
      _gs_write_body DELETE "security/roles/role/$role"
      code="$_GS_CODE"
      howto_step "DELETE security/roles/role/$role" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Rolle $role gelöscht" ;;
        404)     log "  Rolle $role schon weg" ;;
        *)       log_gs_error "Rolle $role löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  # GeoServer-Teil fehlgeschlagen -> Secrets NICHT löschen (bleiben autoritativ)
  [[ "$rc" -eq 0 ]] || { log_error "GeoServer-Teil fehlgeschlagen — Secrets bleiben bestehen"; return 1; }

  # 4) Secrets löschen (exakte Namen)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    howto "kubectl -n $NAMESPACE delete secret $secret --ignore-not-found"
    [[ "$DRY_RUN" -eq 1 ]] && continue
    kubectl -n "$NAMESPACE" delete secret "$secret" --ignore-not-found >/dev/null 2>&1 \
      || { log_error "Secret $secret löschen fehlgeschlagen"; rc=1; }
  done <<< "$SOL_TABLE"

  [[ "$rc" -eq 0 ]] || return 1

  # Verifikation (im Dry-run übersprungen, K2)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  Verifikation wird im Dry-run übersprungen"
    return 0
  fi

  local -a after_users after_roles
  local ftmp
  ftmp="$(mktemp)"; chmod 600 "$ftmp"
  if ! read_users > "$ftmp"; then
    rm -f "$ftmp"; log_error "Schlussverifikation: Benutzerliste nicht lesbar"; return 1
  fi
  mapfile -t after_users < "$ftmp"
  if ! read_roles > "$ftmp"; then
    rm -f "$ftmp"; log_error "Schlussverifikation: Rollenliste nicht lesbar"; return 1
  fi
  mapfile -t after_roles < "$ftmp"
  rm -f "$ftmp"
  _inventory_plausible after_users after_roles || { log_error "Schlussverifikation: Bestand unplausibel"; return 1; }
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    _has "$user" "${after_users[@]}" && { log_error "Benutzer $user noch vorhanden"; rc=1; }
    for role in ${roles//,/ }; do
      _has "$role" "${after_roles[@]}" && { log_error "Rolle $role noch vorhanden"; rc=1; }
    done
    kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1 && { log_error "Secret $secret noch vorhanden"; rc=1; }
  done <<< "$SOL_TABLE"

  # Workspaces: nicht mehr gelistet (Schritt 2)
  local -a after_ws
  local wtmp ws
  wtmp="$(mktemp)"; chmod 600 "$wtmp"
  if ! read_workspaces > "$wtmp"; then
    rm -f "$wtmp"; log_error "Schlussverifikation: Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t after_ws < "$wtmp"
  rm -f "$wtmp"
  while IFS='|' read -r ws _; do
    [[ -n "$ws" ]] || continue
    _has "$ws" "${after_ws[@]}" && { log_error "Workspace $ws noch vorhanden"; rc=1; }
  done <<< "$WS_TABLE"

  # Datastores: nicht mehr gelistet (Schritt 3)
  local -a after_ds
  local dtmp dkey dws dname
  dtmp="$(mktemp)"; chmod 600 "$dtmp"
  while IFS='|' read -r dkey dws dname _ _ _; do
    [[ -n "$dkey" ]] || continue
    if ! read_datastores "$dws" > "$dtmp"; then
      rm -f "$dtmp"; log_error "Schlussverifikation: Datastore-Liste für $dws nicht lesbar"; return 1
    fi
    mapfile -t after_ds < "$dtmp"
    _has "$dname" "${after_ds[@]}" && { log_error "Datastore $dname noch vorhanden"; rc=1; }
  done <<< "$DS_TABLE"
  rm -f "$dtmp"

  # FeatureTypes: nicht mehr gelistet (Schritt 4). Datastore, den der Uninstall
  # bereits gelöscht hat, wird übersprungen (B1); nur echte Lesefehler sind Fehler.
  local -a after_ft
  local ftmp fkey fws fds fname fdsp
  ftmp="$(mktemp)"; chmod 600 "$ftmp"
  while IFS='|' read -r fkey fws fds _ _ _; do
    [[ -n "$fkey" ]] || continue
    _ds_present "$fws" "$fds"; fdsp=$?
    if [[ "$fdsp" -eq 1 ]]; then
      continue
    fi
    if [[ "$fdsp" -eq 2 ]]; then
      rm -f "$ftmp"; log_error "Schlussverifikation: Datastore-Präsenz für $fws/$fds nicht lesbar"; return 1
    fi
    if ! read_featuretypes "$fws" "$fds" > "$ftmp"; then
      rm -f "$ftmp"; log_error "Schlussverifikation: FeatureType-Liste für $fws/$fds nicht lesbar"; return 1
    fi
    mapfile -t after_ft < "$ftmp"
    while IFS='|' read -r fname _ _ _ _; do
      [[ -n "$fname" ]] || continue
      _has "$fname" "${after_ft[@]}" && { log_error "FeatureType $fname noch vorhanden"; rc=1; }
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  rm -f "$ftmp"

  [[ "$rc" -eq 0 ]] && log_ok "Uninstall verifiziert (alle Soll-Objekte entfernt)"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# Haupt
# ═══════════════════════════════════════════════════════════════════════════
main() {
  warn_legacy_vars
  preflight
  _load_inventory || exit 2

  # How-To-Datei vorbereiten (R3: Modus im Namen, damit Install/Uninstall nicht kollidieren)
  local howto_mode git_hash mode
  if [[ "$UNINSTALL" -eq 1 ]]; then
    [[ "$DRY_RUN" -eq 1 ]] && howto_mode="uninstall-dry-run" || howto_mode="uninstall"
  else
    [[ "$DRY_RUN" -eq 1 ]] && howto_mode="install-dry-run" || howto_mode="install"
  fi
  HOWTO_FILE="p2d2-geoserver-config_v1_${howto_mode}_$(date +%Y%m%d-%H%M%S).howto.md"
  exec 3> "$HOWTO_FILE"

  git_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "$git_hash" ]] || git_hash="unbekannt"
  mode="$([[ "$DRY_RUN" -eq 1 ]] && echo 'dry-run (geplant)' || echo 'ausgeführt')"

  howto "# How-To: GeoServer-Konfiguration: Benutzer/Rollen/Secrets/Workspaces/Datastores/FeatureTypes (${SCRIPT_NAME})"
  howto "Git-Hash: ${git_hash}"
  howto "Zeitpunkt: $(date -Is)"
  howto "Modus: ${mode}"
  howto "GeoServer: ${GS_BASE}"
  howto "Namespace: ${NAMESPACE}"
  howto ""
  howto "## Konventionen"
  howto '- Authentifizierung: curl -K - mit `user = "<user>:<password>"` über stdin (Anführungszeichen und Backslash im Wert escapen).'
  howto '- Request-Bodies: mktemp-Datei (Mode 0600), `--data-binary @datei`.'
  howto '- Passwort: `openssl rand -hex 24`, mind. 16 Zeichen, Zeichensatz A-Za-z0-9._~@%+=:,/- .'
  howto '- Secret: Typ Opaque, Key `password`, Merge-Manifest per `kubectl apply`, Wert base64.'
  howto '- Admin-Zugang: Secret `geoserver-geoserver`, Keys `geoserver-user`/`geoserver-password`.'
  howto ""
  howto "## Lesende Schritte"
  howto 'GET security/roles.json             -> {"roles":["ADMIN",...]}'
  howto 'GET security/usergroup/users.json   -> {"users":[{"userName":...,"enabled":true},...]}'
  howto 'GET security/roles/user/<user>.json -> {"roles":[...]}  (404 = leer)'
  howto ""
  howto "## Secret-Schritte"
  howto "Lesen:   kubectl -n ${NAMESPACE} get secret <name> -o jsonpath='{.data.password}' (Wert nie ausgeben)"
  howto "Anlegen: kubectl apply -f <manifest> mit"
  howto '  {"apiVersion":"v1","kind":"Secret","metadata":{"name":"<name>","namespace":"<ns>"},"type":"Opaque","data":{"password":"<BASE64>"}}'
  howto "Löschen: kubectl -n ${NAMESPACE} delete secret <name> --ignore-not-found"
  howto ""
  howto "## Verifikation"
  howto "Positiv: GET ${GS_BASE}/ows?service=WFS&version=2.0.0&request=GetCapabilities (Basic <user>) -> 200"
  howto "Negativ: gleiches mit falschem Passwort -> 401"
  howto "Rollen:  GET security/roles/user/<user>.json; Soll-Rollen müssen enthalten sein."
  howto ""
  howto "## Entscheidungslogik"
  howto "- Secret: wiederverwenden, wenn ein gültiger Wert vorhanden ist, sonst neu erzeugen."
  howto "- Benutzer: anlegen (POST usergroup/users) oder Passwort setzen (POST usergroup/user/<name>)."
  howto "- Uninstall: nur Vorhandenes löschen; 404 gilt als 'schon weg'."
  howto "- Reihenfolge Install: Rollen -> je Benutzer Secret -> Benutzer -> Zuordnungen -> Workspaces -> Datastores -> FeatureTypes -> Default-Styles -> Verifikation."
  howto "- Reihenfolge Uninstall: Layer -> FeatureTypes -> Datastores -> Workspaces -> Zuordnungen -> Benutzer -> Rollen -> Secrets -> Verifikation."
  howto ""
  howto "## Workspaces"
  howto 'GET workspaces.json        -> {"workspaces":{"workspace":[{"name":...,"href":...}]}}'
  howto 'GET namespaces/<ws>.json  -> {"namespace":{"prefix":...,"uri":...}}'
  howto 'GET workspaces/<ws>.json  -> {"workspace":{"name":...}}'
  howto 'POST namespaces           -> {"namespace":{"prefix":"<ws>","uri":"<uri>"}} (Content-Type application/json); 200/201 = ok'
  howto 'DELETE workspaces/<ws>    -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- Anlegen: Workspace fehlt -> POST namespaces (legt Workspace und Namespace an).'
  howto '- Vorhanden: GET namespaces/<ws>.json; URI gleich -> ok, abweichend/fehlt -> Fehler, keine Änderung.'
  howto '- Verifikation: namespaces/<ws>.json URI, workspaces/<ws>.json name, WMS/WFS GetCapabilities.'
  howto ""
  howto "## Datastores"
  howto 'GET workspaces/<ws>/datastores.json            -> {"dataStores":{"dataStore":[{"name":...,"href":...}]}}  ("" = leer)'
  howto 'GET workspaces/<ws>/datastores/<ds>.json      -> {"dataStore":{"name":...,"connectionParameters":{"entry":[{"@key":...,"$":...}]}}}'
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes.json?list=available -> {"list":{"string":[...]}} (DB-Verbindungstest)'
  howto 'POST workspaces/<ws>/datastores               -> 201 (200/201 = ok); Body: 20 connectionParameters'
  howto 'PUT  workspaces/<ws>/datastores/<ds>          -> 200; Body: 20 connectionParameters (vollständig)'
  howto 'DELETE workspaces/<ws>/datastores/<ds>        -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- 20 Parameter: schema, user, namespace, passwd, host, port, database variabel; dbtype=postgis, Estimated extends=false, fetch size=1000, encode functions=false, Expose primary keys=true, validate connections=true, Support on the fly geometry simplification=false, Connection timeout=20, create database=false, preparedStatements=false, reWriteBatchedInserts=false, Loose bbox=false, Test while idle=false fest.'
  howto '- passwd: aus Secret <name> (Key DB_PASSWORD), nur lesend, nie in einer Argumentliste.'
  howto '- Wertequellen: host/port/database aus P2D2_BASE_DB_HOST/PORT/NAME, user aus P2D2_<KEY>_DB_USER, schema aus DS_TABLE, namespace aus WS_TABLE.'
  howto '- Anlegen (fehlt): POST; Vorhanden: PUT (vollständiger Body).'
  howto ""
  howto "## FeatureTypes/Layer"
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes.json            -> {"featureTypes":{"featureType":[{"name":...}]}}  ("" = leer)'
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes/<name>.json    -> {"featureType":{"name":...,"nativeName":...}}'
  howto 'POST workspaces/<ws>/datastores/<ds>/featuretypes               -> 201 (200/201 = ok)'
  howto 'PUT  workspaces/<ws>/datastores/<ds>/featuretypes/<name>        -> 200 (nur bei Abweichung)'
  howto 'GET workspaces/<ws>/layers/<name>.json                          -> {"layer":{"defaultStyle":{"name":...}}}'
  howto 'PUT  workspaces/<ws>/layers/<name>                              -> 200 (defaultStyle setzen)'
  howto 'DELETE workspaces/<ws>/layers/<name>                            -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto 'DELETE workspaces/<ws>/datastores/<ds>/featuretypes/<name>      -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- Body: name, nativeName, namespace, title, keywords, srs=EPSG:4326, projectionPolicy=FORCE_DECLARED, enabled/advertised=true, beide BoundingBoxes; cachingEnabled nur bei grabflure* = false.'
  howto '- Default-Styles: polygon/generic (eingebaute GeoServer-Stile).'
  howto '- Verifikation: FeatureType (enabled/advertised/nativeName/title/srs), Layer defaultStyle, DescribeFeatureType/GetFeature hits (kein ExceptionReport).'
  howto '- Wertequellen: FT_TABLE (Name/Native/Titel/Default-Style), Workspace aus DS_TABLE.'
  howto ''
  howto 'Body (POST/PUT, alle Werte per jq --arg; kein Passwort beteiligt):'
  howto '  {"featureType":{"name":"<name>","nativeName":"<native>","namespace":{"name":"<ws>"},"title":"<title>",'
  howto '    "keywords":{"string":["features","<native>"]},"srs":"EPSG:4326","projectionPolicy":"FORCE_DECLARED",'
  howto '    "enabled":true,"advertised":true,'
  howto '    "nativeBoundingBox":{"minx":-10,"maxx":40,"miny":35,"maxy":71,"crs":"EPSG:4326"},'
  howto '    "latLonBoundingBox":{"minx":-10,"maxx":40,"miny":35,"maxy":71,"crs":"EPSG:4326"}}};'
  howto '  nur grabflure/grabflure_versionen zusätzlich: "metadata":{"entry":{"@key":"cachingEnabled","$":"false"}}'
  howto ''
  howto 'FT_TABLE (Name | Native-Name | Titelmuster %ws% | cachingEnabled | Default-Style):'
  howto '  geo-containers|p2d2_containers|Geo-Containers (%ws%)|-|polygon'
  howto '  grabflure|v_grabflure_aktuell|grabflure_aktuell|false|polygon'
  howto '  grabflure_versionen|p2d2_grabflure_versionen|grabflure_versionen|false|polygon'
  howto '  graeber|v_graeber_aktuell|Gräber (%ws%)|-|generic'
  howto '  graeber_versionen|p2d2_graeber_versionen|Gräber Versionen (%ws%)|-|polygon'
  howto ''
  howto '- Hinweise (VM): POST featuretypes legt den Layer mit passendem Default-Style an.'
  howto '  featuretypes.json eines nicht vorhandenen Datastores -> HTTP 500; list=available eines nicht vorhandenen Workspaces -> HTTP 404; datastores.json eines nicht vorhandenen Workspaces -> HTTP 404.'
  howto ""

  howto "## Ausgeführte Schritte"

  if [[ "$UNINSTALL" -eq 1 ]]; then
    do_uninstall || { exec 3>&-; exit 1; }
  else
    do_install || { exec 3>&-; exit 1; }
  fi

  exec 3>&-
  log_ok "How-To geschrieben: ${HOWTO_FILE}"
  [[ "$DRY_RUN" -eq 1 ]] && log "Dry-run: keine Änderungen vorgenommen."
  exit 0
}

main "$@"

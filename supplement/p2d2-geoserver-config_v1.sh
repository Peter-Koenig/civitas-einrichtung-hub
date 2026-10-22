#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-geoserver-config_v1.sh — GeoServer-Konfiguration (CIVITAS/CORE-AddOn).
# Schritt 1: WFS-T-/WFS-Benutzer, Rollen und Kubernetes-Secrets.
# Schritt 2: Workspaces (Name + Namespace-URI) analog zum Standalone.
#
# Läuft in der CIVITAS/CORE-VM (root, kubectl vorhanden). Legt die fünf
# WFS-T-Benutzer und den WFS-Lese-Benutzer samt Rollen an bzw. setzt deren
# Passwort, erzeugt die Passwörter und speichert sie als Kubernetes-Secrets
# (das Secret ist Single Source of Truth). Legt außerdem die sechs Workspaces
# an. --uninstall entfernt genau diese Objekte wieder.
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
${SCRIPT_NAME} — GeoServer-Konfiguration: WFS-T-/WFS-Benutzer, Rollen, Kubernetes-Secrets und Workspaces.

Usage: bash ./${SCRIPT_NAME} [--dry-run] [--uninstall] [--url BASE] [--ns NAMESPACE] [--help|-h]

Optionen:
  --dry-run      Nur planen: keine Änderung an GeoServer oder Kubernetes.
  --uninstall    Genau die angelegten Benutzer/Rollen/Secrets/Workspaces wieder entfernen.
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

# _http_code_url <url> — authentifizierter GET auf eine beliebige URL; gibt HTTP-Code.
_http_code_url() {
  local url="$1" code
  code="$( _curl_user_cfg "$GS_ADMIN_USER" "$GS_ADMIN_PW" | curl -sS -K - -o /dev/null -w '%{http_code}' "$url" 2>/dev/null )" || code="000"
  printf '%s' "$code"
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

  # Verifikation (im Dry-run übersprungen, K1)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  Verifikation wird im Dry-run übersprungen"
  else
    verify_install || return 1
    verify_workspaces || return 1
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
      code="$(_gs_http_code POST 'namespaces' "$f" 'application/json')"
      rm -f "$f"
      howto_step "POST namespaces" "201" "$code" "JSON {\"namespace\":{\"prefix\":\"$ws\",\"uri\":\"$uri\"}}"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_ok "  Workspace $ws angelegt"
      else
        log_error "Workspace $ws anlegen fehlgeschlagen (HTTP $code)"; rc=1
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
    if ! cur="$(read_namespace_uri "$ws")"; then
      log_error "Verifikation $ws: Namespace nicht lesbar"; rc=1
    elif [[ "$cur" != "$uri" ]]; then
      log_error "Verifikation $ws: Namespace-URI weicht ab (erwartet $uri, vorhanden $cur)"; rc=1
    fi
    # Workspace vorhanden und name stimmt
    _gs_get "workspaces/${ws}.json"
    if [[ "$_GS_CODE" == "200" ]]; then
      name="$(jq -r '.workspace.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      [[ "$name" == "$ws" ]] || { log_error "Verifikation $ws: workspaces/$ws.json name weicht ab (erwartet $ws, erhalten $name)"; rc=1; }
    else
      rm -f "$_GS_BODY_FILE"
      log_error "Verifikation $ws: GET workspaces/$ws.json -> $_GS_CODE (erwartet 200)"; rc=1
    fi
    # Virtuelle Dienste (informativ; ob ein leerer Workspace 200 liefert, ist offen)
    code="$(_http_code_url "$GS_BASE/$ws/wms?service=WMS&version=1.3.0&request=GetCapabilities")"
    [[ "$code" == "200" ]] || log_warn "Verifikation $ws: WMS GetCapabilities -> $code (erwartet 200)"
    if [[ "$ws" != "friedhofsplaene" ]]; then
      code="$(_http_code_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetCapabilities")"
      [[ "$code" == "200" ]] || log_warn "Verifikation $ws: WFS GetCapabilities -> $code (erwartet 200)"
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
    code="$(_gs_http_code DELETE "workspaces/${ws}")"
    howto_step "DELETE workspaces/$ws" "200" "$code" "404 = schon weg, ohne recurse"
    case "$code" in
      200|201) log_ok "  Workspace $ws gelöscht" ;;
      404)     log "  Workspace $ws schon weg" ;;
      *)       log_error "Workspace $ws löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$WS_TABLE"
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

  # 0) Workspaces entfernen (Reihenfolge umgekehrt zum Install; vor Benutzern/Rollen/Secrets)
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
      code="$(_gs_http_code DELETE "security/roles/role/$role/user/$user")"
      howto_step "DELETE security/roles/role/$role/user/$user" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Zuordnung $role/$user gelöst" ;;
        404)     log "  Zuordnung $role/$user schon weg" ;;
        *)       log_error "Zuordnung $role/$user lösen fehlgeschlagen (HTTP $code)"; rc=1 ;;
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
    code="$(_gs_http_code DELETE "security/usergroup/user/$user")"
    howto_step "DELETE security/usergroup/user/$user" "200" "$code" "404 = schon weg"
    case "$code" in
      200|201) log_ok "  Benutzer $user gelöscht" ;;
      404)     log "  Benutzer $user schon weg" ;;
      *)       log_error "Benutzer $user löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
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
      code="$(_gs_http_code DELETE "security/roles/role/$role")"
      howto_step "DELETE security/roles/role/$role" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Rolle $role gelöscht" ;;
        404)     log "  Rolle $role schon weg" ;;
        *)       log_error "Rolle $role löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
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

  # How-To-Datei vorbereiten
  HOWTO_FILE="p2d2-geoserver-config_v1_$(date +%Y%m%d-%H%M).howto.md"
  exec 3> "$HOWTO_FILE"

  local git_hash mode
  git_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "$git_hash" ]] || git_hash="unbekannt"
  mode="$([[ "$DRY_RUN" -eq 1 ]] && echo 'dry-run (geplant)' || echo 'ausgeführt')"

  howto "# How-To: GeoServer-Benutzer/Rollen/Secrets (${SCRIPT_NAME})"
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
  howto "- Reihenfolge Install: Rollen -> je Benutzer Secret -> Benutzer -> Zuordnungen -> Workspaces -> Verifikation."
  howto "- Reihenfolge Uninstall: Workspaces -> Zuordnungen -> Benutzer -> Rollen -> Secrets -> Verifikation."
  howto ""
  howto "## Workspaces"
  howto 'GET workspaces.json        -> {"workspaces":{"workspace":[{"name":...,"href":...}]}}'
  howto 'GET namespaces/<ws>.json  -> {"namespace":{"prefix":...,"uri":...}}'
  howto 'GET workspaces/<ws>.json  -> {"workspace":{"name":...}}'
  howto 'POST namespaces           -> {"namespace":{"prefix":"<ws>","uri":"<uri>"}} (Content-Type application/json); 200/201 = ok'
  howto 'DELETE workspaces/<ws>    -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- Anlegen: Workspace fehlt -> POST namespaces (legt Workspace und Namespace an).'
  howto '- Vorhanden: GET namespaces/<ws>.json; URI gleich -> ok, abweichend/fehlt -> Fehler, keine Änderung.'
  howto '- Verifikation: namespaces/<ws>.json URI, workspaces/<ws>.json name, WMS/WFS GetCapabilities (informativ).'
  howto ""

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

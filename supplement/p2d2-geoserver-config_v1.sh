#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-geoserver-config_v1.sh — GeoServer-Konfiguration, Schritt 1:
# WFS-T-/WFS-Benutzer, Rollen und Kubernetes-Secrets (CIVITAS/CORE-AddOn).
#
# Läuft in der CIVITAS/CORE-VM (root, kubectl vorhanden). Legt die fünf
# WFS-T-Benutzer und den WFS-Lese-Benutzer samt Rollen an bzw. setzt deren
# Passwort, erzeugt die Passwörter und speichert sie als Kubernetes-Secrets
# (das Secret ist Single Source of Truth). --uninstall entfernt genau diese
# Objekte wieder.
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

# ═══════════════════════════════════════════════════════════════════════════
# How-To-Ausgabe (A5): pro Schritt Methode/Pfad/Payload/HTTP-Code, ohne Werte.
# ═══════════════════════════════════════════════════════════════════════════
howto() {
  [[ -n "$HOWTO_FILE" ]] || return 0
  printf '%s\n' "$*" >&"$HOWTO_FD"
}

# ═══════════════════════════════════════════════════════════════════════════
# Argumente
# ═══════════════════════════════════════════════════════════════════════════
usage() {
  cat >&2 <<EOF
Usage: bash ./${SCRIPT_NAME} [--dry-run] [--uninstall] [--url BASE] [--ns NAMESPACE] [--help|-h]
EOF
  exit 2
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
    --help|-h) usage ;;
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
  for f in "./.env.p2d2-addon" "../.env.p2d2-addon"; do
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
# _gs_curl <method> <path> [<payload-file>] [<content-type>]
#   GET:  keine Payload
#   POST: --data-binary @<payload-file>
_gs_curl() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" out
  local cfg
  cfg="$(mktemp)"
  printf 'user = "%s:%s"\n' "$GS_ADMIN_USER" "$GS_ADMIN_PW" > "$cfg"
  chmod 600 "$cfg"
  if [[ -n "$payload" ]]; then
    out="$(curl -sS -K "$cfg" -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" "$GS_REST/$path" 2>/dev/null)" || out=""
  else
    out="$(curl -sS -K "$cfg" -X "$method" -H "Content-Type: $ctype" "$GS_REST/$path" 2>/dev/null)" || out=""
  fi
  rm -f "$cfg"
  printf '%s' "$out"
}

# _gs_http_code <method> <path> [<payload-file>] [<content-type>]
_gs_http_code() {
  local method="$1" path="$2" payload="${3:-}" ctype="${4:-application/json}" code
  local cfg
  cfg="$(mktemp)"
  printf 'user = "%s:%s"\n' "$GS_ADMIN_USER" "$GS_ADMIN_PW" > "$cfg"
  chmod 600 "$cfg"
  if [[ -n "$payload" ]]; then
    code="$(curl -sS -K "$cfg" -X "$method" -H "Content-Type: $ctype" --data-binary "@$payload" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null)" || code="000"
  else
    code="$(curl -sS -K "$cfg" -X "$method" -H "Content-Type: $ctype" -o /dev/null -w '%{http_code}' "$GS_REST/$path" 2>/dev/null)" || code="000"
  fi
  rm -f "$cfg"
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

  kubectl -n "$NAMESPACE" get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || { log_error "Namespace existiert nicht: $NAMESPACE"; exit 2; }

  # Admin-Zugang: Secret zuerst, Env-Override GS_ADMIN_USER/GS_ADMIN_PW gewinnt.
  # Das Admin-Passwort wird nie ausgegeben.
  local secret_user secret_pw
  secret_user="$(kubectl -n "$NAMESPACE" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  secret_pw="$(kubectl -n "$NAMESPACE" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  GS_ADMIN_USER="${GS_ADMIN_USER:-$secret_user}"
  GS_ADMIN_PW="${GS_ADMIN_PW:-$secret_pw}"
  [[ -n "$GS_ADMIN_USER" && -n "$GS_ADMIN_PW" ]] \
    || { log_error "Admin-Zugang (Secret geoserver-geoserver) nicht lesbar"; exit 2; }
  check_never_touch || exit 2

  local code
  code="$(_gs_http_code GET 'security/roles.json')"
  if [[ "$code" != "200" ]]; then
    log_error "GeoServer nicht erreichbar (GET security/roles.json -> $code): $GS_REST"
    exit 2
  fi
  log_ok "Preflight ok (Namespace ${NAMESPACE}, GeoServer ${GS_BASE})"
}

# ═══════════════════════════════════════════════════════════════════════════
# Bestand lesen (Benutzer + Rollen), nie Passwörter
# ═══════════════════════════════════════════════════════════════════════════
read_users()  { _gs_curl GET 'security/usergroup/users.json' | jq -r '.users[]?.userName // empty' 2>/dev/null | sort; }
read_roles()  { _gs_curl GET 'security/roles.json' | jq -r '.roles[]?.name // .roles.role[]?.name // empty' 2>/dev/null | sort; }

# _has <needle> <items...> — 0 wenn needle enthalten.
_has() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
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

# ═══════════════════════════════════════════════════════════════════════════
# Install
# ═══════════════════════════════════════════════════════════════════════════
do_install() {
  local -a existing_users existing_roles
  local line key _ user roles secret role password
  local f

  mapfile -t existing_users < <(read_users)
  mapfile -t existing_roles < <(read_roles)

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
      howto "POST security/roles/role/$role (erwartet 200) — idempotent"
      [[ "$DRY_RUN" -eq 1 ]] && continue
      local code
      code="$(_gs_http_code POST "security/roles/role/$role")"
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
      [[ "$DRY_RUN" -eq 1 ]] || _secret_apply "$NAMESPACE" "$secret" "password=$password"
    fi

    # GeoServer: Benutzer anlegen oder Passwort setzen.
    local uexists
    uexists="nein"; _has "$user" "${existing_users[@]}" && uexists="ja"

    if [[ "$uexists" == "nein" ]]; then
      howto "POST security/usergroup/users (XML <user><userName>$user</userName><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml, erwartet 201)"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><userName>%s</userName><password>%s</password><enabled>true</enabled></user>\n' "$user" "$password" > "$f"
        local code
        code="$(_gs_http_code POST 'security/usergroup/users' "$f" 'text/xml')"
        rm -f "$f"
        [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Benutzer $user anlegen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Benutzer $user angelegt"
      else
        log "  Benutzer $user würde angelegt (dry-run)"
      fi
    else
      howto "POST security/usergroup/user/$user (XML <user><password><PASSWORD></password></user>, Content-Type text/xml, erwartet 200) — nur Passwort setzen"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><password>%s</password></user>\n' "$password" > "$f"
        local code
        code="$(_gs_http_code POST "security/usergroup/user/$user" "$f" 'text/xml')"
        rm -f "$f"
        [[ "$code" == "200" ]] || { log_error "Passwort für $user setzen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Passwort für $user gesetzt"
      else
        log "  Passwort für $user würde gesetzt (dry-run)"
      fi
    fi

    # Rollen zuordnen (idempotent, POST)
    for role in ${roles//,/ }; do
      howto "POST security/roles/role/$role/user/$user (erwartet 200) — idempotent"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        local code
        code="$(_gs_http_code POST "security/roles/role/$role/user/$user")"
        [[ "$code" == "200" ]] || { log_error "Zuordnung $role -> $user fehlgeschlagen (HTTP $code)"; return 1; }
      fi
    done
  done <<< "$SOL_TABLE"

  # Verifikation
  verify_install || return 1
  return 0
}

verify_install() {
  local line key _ user roles secret password code neg
  log "== Verifikation =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    password="$(_secret_get "$NAMESPACE" "$secret" "password")"
    [[ -n "$password" ]] || { log_error "Verifikation $key: kein Passwort im Secret"; return 1; }

    # Positivtest (authentifizierter GetCapabilities)
    local cfg f
    cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'user = "%s:%s"\n' "$user" "$password" > "$cfg"
    code="$(curl -sS -K "$cfg" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null)" || code="000"
    rm -f "$cfg"

    # Negativtest (falsches Passwort muss 401 liefern)
    cfg="$(mktemp)"; chmod 600 "$cfg"
    printf 'user = "%s:%s"\n' "$user" "falsch_${password}" > "$cfg"
    neg="$(curl -sS -K "$cfg" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null)" || neg="000"
    rm -f "$cfg"

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
  done <<< "$SOL_TABLE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Uninstall (nur exakt benannte Objekte)
# ═══════════════════════════════════════════════════════════════════════════
do_uninstall() {
  local line key _ user roles secret code rc=0
  log "== Uninstall =="

  # 1) Rollenzuordnungen lösen
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      howto "DELETE security/roles/role/$role/user/$user (erwartet 200)"
      [[ "$DRY_RUN" -eq 1 ]] && continue
      code="$(_gs_http_code DELETE "security/roles/role/$role/user/$user")"
      [[ "$code" == "200" ]] || { log_error "Zuordnung $role/$user lösen fehlgeschlagen (HTTP $code)"; rc=1; }
    done
  done <<< "$SOL_TABLE"

  # 2) Benutzer löschen
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    howto "DELETE security/usergroup/user/$user (erwartet 200)"
    [[ "$DRY_RUN" -eq 1 ]] && continue
    code="$(_gs_http_code DELETE "security/usergroup/user/$user")"
    [[ "$code" == "200" ]] || { log_error "Benutzer $user löschen fehlgeschlagen (HTTP $code)"; rc=1; }
  done <<< "$SOL_TABLE"

  # 3) Rollen löschen
  local role
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      howto "DELETE security/roles/role/$role (erwartet 200)"
      [[ "$DRY_RUN" -eq 1 ]] && continue
      code="$(_gs_http_code DELETE "security/roles/role/$role")"
      [[ "$code" == "200" ]] || { log_error "Rolle $role löschen fehlgeschlagen (HTTP $code)"; rc=1; }
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

  # Verifikation: Benutzer/Rollen/Secrets nicht mehr vorhanden
  local -a after_users after_roles
  mapfile -t after_users < <(read_users)
  mapfile -t after_roles < <(read_roles)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    _has "$user" "${after_users[@]}" && { log_error "Benutzer $user noch vorhanden"; rc=1; }
    for role in ${roles//,/ }; do
      _has "$role" "${after_roles[@]}" && { log_error "Rolle $role noch vorhanden"; rc=1; }
    done
    kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1 && { log_error "Secret $secret noch vorhanden"; rc=1; }
  done <<< "$SOL_TABLE"

  [[ "$rc" -eq 0 ]] && log_ok "Uninstall verifiziert (alle Soll-Objekte entfernt)"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# Haupt
# ═══════════════════════════════════════════════════════════════════════════
main() {
  preflight

  # How-To-Datei vorbereiten
  HOWTO_FILE="p2d2-geoserver-config_v1_$(date +%Y%m%d-%H%M).howto.md"
  exec 3> "$HOWTO_FILE"
  howto "# How-To: GeoServer-Benutzer/Rollen/Secrets (${SCRIPT_NAME})"
  howto "Mode: $([[ "$DRY_RUN" -eq 1 ]] && echo 'dry-run (geplant)' || echo 'ausgeführt')"
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

#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_11_geoserver_config.sh — GeoServer-Vektor-Konfiguration (Workspaces,
# Datastores, FeatureTypes, Benutzer/Rollen/ACLs, Dienst-Metadaten). Überträgt das
# Wegwerf-Skript supplement/p2d2-geoserver-config_v1.sh als Modul in den Installer.
#
# Voraussetzung: bash >= 5.2 (VM: 5.2.37).
# D8: RO-Benutzer p2d2_wfs_user + Rolle WFS-USER + Secret p2d2-geoserver-wfs-user
#     sind Legacy (kein Konsument), werden aber übernommen.
# D9: Import-Rolle P2D2_OSM_IMPORT (Benutzer p2d2_osm_import, Secret
#     p2d2-geoserver-osm-import) ist nur als Kommentar vorgesehen, wird NICHT angelegt.
#
# Hinweis (D1): _p2d2_pw_resolve exportiert die Variablen P2D2_<KEY>_WFST_PASSWORD
# absichtlich in den aufrufenden Prozess; addon_30 (apply_addon_secrets) liest sie
# dort. Voraussetzung: install_addon_geoserver_config läuft vor install_addon_frontend.
#
# Hinweis (D1a/Auflage 8): Das Modul schreibt ausschließlich P2D2_<KEY>_WFST_PASSWORD
# in die .env (ADDON_ENV_FILE); RO (p2d2_wfs_user) bleibt secret-geführt ohne
# .env-Variable.

# Guard wie addon_10: ohne ADDON_NS/ADDON_DOMAIN wird das Sourcen abgebrochen.
if [[ -z "${ADDON_NS:-}" || -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_NS/ADDON_DOMAIN nicht gesetzt — addon_11_geoserver_config.sh nicht isoliert sourcen." >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck source=./addon_11_geoserver_config_core.sh
source "$(dirname "${BASH_SOURCE[0]}")/addon_11_geoserver_config_core.sh"
# shellcheck source=./addon_11_geoserver_config_catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/addon_11_geoserver_config_catalog.sh"
# shellcheck source=./addon_11_geoserver_config_security.sh
source "$(dirname "${BASH_SOURCE[0]}")/addon_11_geoserver_config_security.sh"
# shellcheck source=./addon_11_geoserver_config_settings.sh
source "$(dirname "${BASH_SOURCE[0]}")/addon_11_geoserver_config_settings.sh"

install_addon_geoserver_config()   { _gsc_run install; }
verify_addon_geoserver_config()    { _gsc_run verify; }
uninstall_addon_geoserver_config() { _gsc_run uninstall; }

# _gsc_run <install|verify|uninstall> — hält den gesamten Modulzustand als local
# (dynamischer Geltungsbereich) und gibt 0/1 zurück. Kein trap, kein umask, kein cd.
_gsc_run() {
  local mode="$1" rc=0 tmp
  local NAMESPACE="${ADDON_NS}" GS_BASE="https://geoportal.${ADDON_DOMAIN}/geoserver" GS_REST=""
  local DRY_RUN=0 UNINSTALL=0 HOWTO_FILE="" HOWTO_FD=3 GS_ADMIN_USER="" GS_ADMIN_PW=""
  local SOL_TABLE="" WS_TABLE="" DS_TABLE="" FT_TABLE="" ATTR_MAP_TABLE="" ACL_LAYER_TABLE=""
  local NEVER_TOUCH_USERS="admin p2d2_wfst_user"
  local _GS_CODE="" _GS_BODY_FILE="" _GS_ERR_BODY="" _GS_METADATA="" _GS_ALLOW_INCOMPLETE=0
  local _DB_HOST="" _DB_PORT="" _DB_NAME=""
  local GS_METADATA_FILE="${ADDON_SUPPLEMENT_DIR}/geoserver-metadata.md"
  local -a GS_CURL_TMO=(--connect-timeout 10 --max-time "${GS_CURL_MAX_TIME:-60}")
  local -a _INV_USERS=() _INV_ROLES=() _USER_ROLES=() _KEEP_ROLES=() _EXISTING_WS=() _PLANNED_LAYER_DEL=()
  GS_REST="${GS_BASE}/rest"
  tmp="$(mktemp -d)" || return 1
  local -x TMPDIR="${tmp}"
  case "${mode}" in
    install)   if ! _gsc_do_install;   then rc=1; fi ;;
    verify)    if ! _gsc_do_verify;    then rc=1; fi ;;
    uninstall) if ! _gsc_do_uninstall; then rc=1; fi ;;
    *) log_error "interner Fehler: Modus ${mode}"; rc=1 ;;
  esac
  rm -rf -- "${tmp}"
  return "${rc}"
}

# _gsc_preflight — Voraussetzungen prüfen (admin nur aus Secret, kein Env-Override).
_gsc_preflight() {
  local cmd rc=0
  if ! (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 2) )); then
    log_error "bash >= 5.2 erforderlich (ist: ${BASH_VERSION})"; return 2
  fi
  for cmd in kubectl jq curl openssl yq; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Voraussetzung fehlt: $cmd"; rc=2; }
  done
  [[ "$rc" -eq 0 ]] || return "$rc"
  yq --version 2>&1 | grep -q mikefarah || { log_error 'yq: mikefarah v4 erforderlich'; return 2; }

  GS_ADMIN_USER="$(_p2d2_secret_get "$NAMESPACE" geoserver-geoserver geoserver-user)"
  GS_ADMIN_PW="$(_p2d2_secret_get "$NAMESPACE" geoserver-geoserver geoserver-password)"
  [[ -n "$GS_ADMIN_USER" && -n "$GS_ADMIN_PW" ]] \
    || { log_error "Admin-Zugang (Secret geoserver-geoserver) nicht lesbar"; return 2; }

  _gsc_define_tables || return 2
  check_never_touch || return 2
  check_ws_table || return 2
  check_ds_table || return 2
  load_ds_config || return 2
  check_styles || return 2
  _wait_gs_ready || { log_error "GeoServer nicht erreichbar: ${GS_REST}"; return 2; }
  log_ok 'Preflight ok'
  return 0
}

# _gsc_define_tables — SOL_TABLE aus .env bauen (Abgleich), WS_TABLE ohne friedhofsplaene.
_gsc_define_tables() {
  local key ws_var user_var ws user exp_ws
  SOL_TABLE=""
  for key in MAIN DEVELOP DE1 DE2 FV; do
    case "$key" in
      MAIN)    exp_ws=main ;;
      DEVELOP) exp_ws=dev ;;
      DE1)     exp_ws=de1 ;;
      DE2)     exp_ws=de2 ;;
      FV)      exp_ws=fv ;;
    esac
    ws_var="P2D2_${key}_WFST_WORKSPACE"
    user_var="P2D2_${key}_WFST_USERNAME"
    ws="${!ws_var:-}"
    user="${!user_var:-}"
    [[ "$ws" == "$exp_ws" ]] || { log_error "${ws_var}='${ws}' (erwartet ${exp_ws})"; return 1; }
    [[ "$user" == "p2d2_wfst_${key,,}" ]] || { log_error "${user_var}='${user}' (erwartet p2d2_wfst_${key,,})"; return 1; }
    SOL_TABLE+="${key}|${ws}|${user}|P2D2_WFST_${key}|p2d2-geoserver-wfst-${key,,}
"
  done
  SOL_TABLE+="RO|-|p2d2_wfs_user|WFS-USER|p2d2-geoserver-wfs-user"

  WS_TABLE='main|urn:data-dna:govdata:main
dev|urn:data-dna:govdata:dev
de1|urn:data-dna:govdata:de1
de2|urn:data-dna:govdata:de2
fv|urn:data-dna:govdata:fv'

  DS_TABLE='MAIN|main|main_pg|p2d2_main|P2D2_MAIN_DB_USER|p2d2-main-secret
DEVELOP|dev|dev_pg|p2d2_develop|P2D2_DEVELOP_DB_USER|p2d2-dev-secret
DE1|de1|de1_pg|p2d2_de1|P2D2_DE1_DB_USER|p2d2-f-de1-secret
DE2|de2|de2_pg|p2d2_de2|P2D2_DE2_DB_USER|p2d2-f-de2-secret
FV|fv|fv_pg|p2d2_fv|P2D2_FV_DB_USER|p2d2-f-fv-secret'

  FT_TABLE='geo-containers|p2d2_containers|Geo-Containers (%ws%)|-|polygon
grabflure|v_grabflure_aktuell|grabflure_aktuell|false|polygon
grabflure_versionen|p2d2_grabflure_versionen|grabflure_versionen|false|polygon
graeber|v_graeber_aktuell|Gräber (%ws%)|-|generic
graeber_versionen|p2d2_graeber_versionen|Gräber Versionen (%ws%)|-|polygon'

  ATTR_MAP_TABLE='geo-containers|osm_name|name'

  ACL_LAYER_TABLE='geo-containers|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
grabflure|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
graeber|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
grabflure_versionen|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|%stage%,ADMIN
graeber_versionen|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|%stage%,ADMIN'
  return 0
}

_gsc_do_install() {
  local -a existing_users existing_roles
  local line key _ user roles secret role password
  local f pw_var stored

  _gsc_preflight || return 1
  _load_inventory || return 1
  load_metadata || return 1

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
      local code
      code="$(_gs_http_code POST "security/roles/role/$role")"
      [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Rolle $role anlegen fehlgeschlagen (HTTP $code)"; return 1; }
      log_ok "  Rolle $role angelegt"
    fi
  done

  log "== Benutzer + Secrets =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue

    # D1: WFS-T-Passwort auflösen (nicht-RO über _p2d2_pw_resolve, RO rein Secret-geführt).
    if [[ "$key" != "RO" ]]; then
      pw_var="P2D2_${key}_WFST_PASSWORD"
      _p2d2_pw_resolve "$pw_var" "$NAMESPACE" "$secret" password || return 1
      password="${!pw_var}"
    else
      password="$(_p2d2_secret_get "$NAMESPACE" "$secret" password)"
      _p2d2_pw_is_valid "$password" || password="$(_p2d2_pw_gen)"
    fi
    stored="$(_p2d2_secret_get "$NAMESPACE" "$secret" password)"
    if [[ "$stored" != "$password" ]]; then
      _p2d2_secret_apply "$NAMESPACE" "$secret" "password=${password}" \
        || { log_error "Secret ${secret} nicht gespeichert — Abbruch vor GeoServer-Änderung"; return 1; }
    fi

    local uexists
    uexists="nein"; _has "$user" "${existing_users[@]}" && uexists="ja"

    if [[ "$uexists" == "nein" ]]; then
      f="$(mktemp)"; chmod 600 "$f"
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><userName>%s</userName><password>%s</password><enabled>true</enabled></user>\n' "$user" "$password" > "$f"
      local code
      code="$(_gs_http_code POST 'security/usergroup/users' "$f" 'text/xml')"
      rm -f "$f"
      [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Benutzer $user anlegen fehlgeschlagen (HTTP $code)"; return 1; }
      log_ok "  Benutzer $user angelegt"
    else
      f="$(mktemp)"; chmod 600 "$f"
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><password>%s</password><enabled>true</enabled></user>\n' "$password" > "$f"
      local code
      code="$(_gs_http_code POST "security/usergroup/user/$user" "$f" 'text/xml')"
      rm -f "$f"
      [[ "$code" == "200" ]] || { log_error "Passwort für $user setzen fehlgeschlagen (HTTP $code)"; return 1; }
      log_ok "  Passwort für $user gesetzt"
    fi

    for role in ${roles//,/ }; do
      local code
      code="$(_gs_http_code POST "security/roles/role/$role/user/$user")"
      [[ "$code" == "200" ]] || { log_error "Zuordnung $role -> $user fehlgeschlagen (HTTP $code)"; return 1; }
    done

    # Auflage 8 (D1a): Wert in die .env spiegeln, erst nachdem Secret und GeoServer
    # stimmen. pw_var ist nur für key != RO gesetzt; RO bleibt secret-geführt.
    if [[ "$key" != "RO" ]]; then
      _p2d2_env_mirror "${ADDON_ENV_FILE:-}" "$pw_var" "$password" || true
    fi
  done <<< "$SOL_TABLE"

  install_workspaces || return 1
  install_workspace_settings || return 1
  install_service_metadata || return 1
  install_datastores || return 1
  install_featuretypes || return 1
  install_attr_mapping || return 1
  install_acls || return 1
  return 0
}

verify_install() {
  local line key _ user roles secret password code neg role
  log "== Verifikation =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    password="$(_p2d2_secret_get "$NAMESPACE" "$secret" "password")"
    [[ -n "$password" ]] || { log_error "Verifikation $key: kein Passwort im Secret"; return 1; }

    code="$( _curl_user_cfg "$user" "$password" | curl -sS -K - "${GS_CURL_TMO[@]}" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || code="000"
    neg="$( _curl_user_cfg "$user" "falsch_${password}" | curl -sS -K - "${GS_CURL_TMO[@]}" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || neg="000"

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

_gsc_do_verify() {
  _gsc_preflight || return 1
  _load_inventory || return 1
  load_metadata || return 1
  verify_install || return 1
  verify_workspaces || return 1
  verify_workspace_settings || return 1
  verify_service_metadata || return 1
  verify_datastores || return 1
  verify_featuretypes || return 1
  verify_attr_mapping || return 1
  verify_acls || return 1
  return 0
}

_gsc_do_uninstall() {
  local line key _ user roles secret code rc=0 role
  local -a existing_users existing_roles

  _gsc_preflight || return 1
  _load_inventory || return 1

  log "== Uninstall =="
  existing_users=("${_INV_USERS[@]}")
  existing_roles=("${_INV_ROLES[@]}")

  uninstall_featuretypes || rc=1
  uninstall_acls || rc=1
  uninstall_datastores || rc=1
  uninstall_workspaces || rc=1

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
      _gs_write_body DELETE "security/roles/role/$role/user/$user"
      code="$_GS_CODE"
      case "$code" in
        200|201) log_ok "  Zuordnung $role/$user gelöst" ;;
        404)     log "  Zuordnung $role/$user schon weg" ;;
        *)       log_gs_error "Zuordnung $role/$user lösen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if ! _has "$user" "${existing_users[@]}"; then
      log "  Benutzer $user nicht vorhanden — übersprungen"
      continue
    fi
    _gs_write_body DELETE "security/usergroup/user/$user"
    code="$_GS_CODE"
    case "$code" in
      200|201) log_ok "  Benutzer $user gelöscht" ;;
      404)     log "  Benutzer $user schon weg" ;;
      *)       log_gs_error "Benutzer $user löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$SOL_TABLE"

  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      if _has "$role" "${_KEEP_ROLES[@]}"; then
        log "  Rolle $role bleibt (von noch vorhandener Layer-ACL benötigt)"
        continue
      fi
      if ! _has "$role" "${existing_roles[@]}"; then
        log "  Rolle $role nicht vorhanden — übersprungen"
        continue
      fi
      _gs_write_body DELETE "security/roles/role/$role"
      code="$_GS_CODE"
      case "$code" in
        200|201) log_ok "  Rolle $role gelöscht" ;;
        404)     log "  Rolle $role schon weg" ;;
        *)       log_gs_error "Rolle $role löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  [[ "$rc" -eq 0 ]] || { log_error "GeoServer-Teil fehlgeschlagen — Secrets bleiben bestehen"; return 1; }

  # 4) Secrets löschen (exakte Namen, je Secret eine Log-Zeile — Fix 7)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
      if kubectl -n "$NAMESPACE" delete secret "$secret" >/dev/null 2>&1; then
        log_ok "  Secret $secret gelöscht"
      else
        log_error "Secret $secret löschen fehlgeschlagen"; rc=1
      fi
    else
      log "  Secret $secret nicht vorhanden — übersprungen"
    fi
  done <<< "$SOL_TABLE"

  [[ "$rc" -eq 0 ]] || return 1

  # Schlussverifikation (Rückstandsfreiheit) — portiert aus supplement do_uninstall
  # (K2: im Dry-run übersprungen; hier gibt es keinen Dry-run). B1/B3: bereits gelöschte
  # Datastores werden übersprungen, Lesefehler sind Fehler.
  local -a after_users after_roles after_ws after_ds after_ft
  local ftmp wtmp dtmp ws dkey dws dname fdsp fname
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

  ftmp="$(mktemp)"; chmod 600 "$ftmp"
  while IFS='|' read -r dkey dws dname _ _ _; do
    [[ -n "$dkey" ]] || continue
    fdsp=0; _ds_present "$dws" "$dname" || fdsp=$?
    if [[ "$fdsp" -eq 1 ]]; then
      continue
    fi
    if [[ "$fdsp" -eq 2 ]]; then
      rm -f "$ftmp"; log_error "Schlussverifikation: Datastore-Präsenz für $dws/$dname nicht lesbar"; return 1
    fi
    if ! read_featuretypes "$dws" "$dname" > "$ftmp"; then
      rm -f "$ftmp"; log_error "Schlussverifikation: FeatureType-Liste für $dws/$dname nicht lesbar"; return 1
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

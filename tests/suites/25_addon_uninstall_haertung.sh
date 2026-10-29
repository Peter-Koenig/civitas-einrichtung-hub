#!/usr/bin/env bash
# Suite 25: Uninstall-Härtung Teil 2 — N4 Rückgabewerte (MapProxy/GeoServer) und
# N2e T3-Fehleraggregation im Hauptskript. Nur Stubs, kein Cluster/Netz.

begin_suite "addon_uninstall_haertung"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"

LOG_BUF="$T/log"
log()      { echo "L:$*" >> "$LOG_BUF"; }
log_ok()   { echo "O:$*" >> "$LOG_BUF"; }
log_warn() { echo "W:$*" >> "$LOG_BUF"; }
log_error(){ echo "E:$*" >> "$LOG_BUF"; }

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_20_mapproxy.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_10_geoserver.sh"
set +e

# ── MapProxy: kubectl-Stub (delete best-effort) + APISIX-curl ─────────────────
kubectl() { return 0; }
APISIX_CREDS_FILE="$T/creds"
printf 'APISIX_ADMIN_ROLE_KEY=test-key\n' > "$APISIX_CREDS_FILE"
export ADDON_APISIX_CREDENTIALS_FILE="$APISIX_CREDS_FILE"

APISIX_DELETE_CODE="200"
APISIX_LIST_CODE="200"
curl() {
  local has_w=0 url="" is_delete=0
  for a in "$@"; do case "$a" in https://*) url="$a" ;; -w) has_w=1 ;; esac; done
  [[ "$*" == *"-X DELETE"* ]] && is_delete=1
  case "$url" in
    *"/apisix/admin/"*)
      if [[ "$has_w" == "1" ]]; then
        if [[ "$is_delete" == "1" ]]; then printf '%s' "$APISIX_DELETE_CODE"; else printf '%s' "$APISIX_LIST_CODE"; fi
      else
        printf '{"list":[{"value":{"name":"mapserver-route","id":"1"}}]}'
      fi
      ;;
    *) return 0 ;;
  esac
}

APISIX_DELETE_CODE="200"; APISIX_LIST_CODE="200"
uninstall_addon_mapproxy >/dev/null 2>&1
check "N4 mapproxy ok: rc=0" "0" "$?"

APISIX_DELETE_CODE="500"; APISIX_LIST_CODE="200"
uninstall_addon_mapproxy >/dev/null 2>&1
check "N4 mapproxy DELETE fehl: rc=1" "1" "$?"

# A4: Listenabfrage HTTP != 200 -> rc=1 (nicht 'nicht vorhanden')
APISIX_DELETE_CODE="200"; APISIX_LIST_CODE="500"
uninstall_addon_mapproxy >/dev/null 2>&1
check "A4 mapproxy Liste fehl: rc=1" "1" "$?"

# Admin-Key fehlt -> rc=1
: > "$APISIX_CREDS_FILE"
uninstall_addon_mapproxy >/dev/null 2>&1
check "N4 mapproxy key fehlt: rc=1" "1" "$?"

# ── GeoServer: kubectl/curl-Stub ──────────────────────────────────────────────
GS_POD_NAME="geoserver-geoserver-0"
GS_DELETE_CODE="200"
RASTER_RC=0
kubectl() {
  case "$*" in
    *"get secret geoserver-geoserver"*"geoserver-user"*) printf 'YWRtaW4='; return 0 ;;
    *"get secret geoserver-geoserver"*"geoserver-password"*) printf 'cHc='; return 0 ;;
    *"get pods"*"-o jsonpath"*) printf '%s' "$GS_POD_NAME"; return 0 ;;
    *"exec"*"rm -rf"*) return "$RASTER_RC" ;;
    *) return 0 ;;
  esac
}
curl() {
  local has_w=0 url=""
  for a in "$@"; do case "$a" in https://*) url="$a" ;; -w) has_w=1 ;; esac; done
  case "$url" in
    *"/geoserver/rest/workspaces/"*)
      if [[ "$has_w" == "1" ]]; then printf '%s' "$GS_DELETE_CODE"; fi
      ;;
    *) return 0 ;;
  esac
}

GS_DELETE_CODE="200"; RASTER_RC=0
uninstall_addon_geoserver >/dev/null 2>&1
check "N4 geoserver ok: rc=0" "0" "$?"

GS_DELETE_CODE="500"; RASTER_RC=0
uninstall_addon_geoserver >/dev/null 2>&1
check "N4 geoserver Workspace-DELETE fehl: rc=1" "1" "$?"

GS_DELETE_CODE="200"; RASTER_RC=1
uninstall_addon_geoserver >/dev/null 2>&1
check "N4 geoserver Raster rm fehl: rc=1" "1" "$?"

# ── N2e T3: Uninstall-Zweig Fehleraggregation (Funktionsgrenzen-Extraktion) ──
# Den Uninstall-Zweig aus dem Hauptskript extrahieren und mit Stubs testen.
extract_uninstall_branch() {
  awk '/log "Modus: Uninstall/ {f=1} f && /^else$/ {exit} f {print}' "$MAIN"
}

run_uninstall_branch() {
  # $1 = welches Modul scheitert (name) bzw. "none"
  local fail="$1"
  local calls=""
  uninstall_addon_frontend()   { calls="${calls} frontend"; [[ "$fail" == "frontend" ]] && return 1; return 0; }
  uninstall_addon_iam()        { calls="${calls} iam"; [[ "$fail" == "iam" ]] && return 1; return 0; }
  uninstall_addon_mapproxy()   { calls="${calls} mapproxy"; [[ "$fail" == "mapproxy" ]] && return 1; return 0; }
  uninstall_addon_geoserver_config() { calls="${calls} geoserver_config"; [[ "$fail" == "geoserver_config" ]] && return 1; return 0; }
  uninstall_addon_geoserver()  { calls="${calls} geoserver"; [[ "$fail" == "geoserver" ]] && return 1; return 0; }
  uninstall_addon_postgresql() { calls="${calls} postgresql"; [[ "$fail" == "postgresql" ]] && return 1; return 0; }
  portal_remove() { calls="${calls} portal"; return 0; }
  log()      { :; }
  log_warn() { :; }
  ADDON_EXIT_CODE=0
  eval "$(extract_uninstall_branch)"
  printf '%s' "${ADDON_EXIT_CODE}"
}

check "N2e kein Fehler: exit=0" "0" "$(run_uninstall_branch none)"
check "N2e frontend fehlt: exit=1" "1" "$(run_uninstall_branch frontend)"
check "N2e geoserver_config fehlt: exit=1" "1" "$(run_uninstall_branch geoserver_config)"
check "N2e postgresql fehlt: exit=1" "1" "$(run_uninstall_branch postgresql)"

# ── Phase 3: Install-Zweig Reihenfolge + D6 (verify nicht-abbrechend) ────────
extract_install_branch() {
  awk '/^  install_addon_postgresql$/ {f=1} f {print; if (/addon_export_tls_backup/) exit}' "$MAIN"
}

run_install_branch() {
  local fail="$1"
  local calls=""
  install_addon_postgresql()     { calls="${calls} postgresql"; [[ "$fail" == "postgresql" ]] && return 1; return 0; }
  install_addon_geoserver()      { calls="${calls} geoserver"; [[ "$fail" == "geoserver" ]] && return 1; return 0; }
  verify_addon_geoserver_mosaic() { calls="${calls} verify_mosaic"; [[ "$fail" == "verify_mosaic" ]] && return 1; return 0; }
  install_addon_geoserver_config() { calls="${calls} geoserver_config"; [[ "$fail" == "geoserver_config" ]] && return 1; return 0; }
  verify_addon_geoserver_config() { calls="${calls} verify_geoserver_config"; [[ "$fail" == "verify_geoserver_config" ]] && return 1; return 0; }
  install_addon_mapproxy()       { calls="${calls} mapproxy"; [[ "$fail" == "mapproxy" ]] && return 1; return 0; }
  addon_docker_ensure()           { calls="${calls} docker_ensure"; return 0; }
  install_addon_mapproxy_build()  { calls="${calls} mapproxy_build"; [[ "$fail" == "mapproxy_build" ]] && return 1; return 0; }
  verify_addon_mapproxy()         { calls="${calls} verify_mapproxy"; [[ "$fail" == "verify_mapproxy" ]] && return 1; return 0; }
  addon_docker_release()          { calls="${calls} docker_release"; return 0; }
  install_addon_iam()            { calls="${calls} iam"; [[ "$fail" == "iam" ]] && return 1; return 0; }
  install_addon_frontend_build() { calls="${calls} frontend_build"; [[ "$fail" == "frontend_build" ]] && return 1; return 0; }
  install_addon_frontend()       { calls="${calls} frontend"; [[ "$fail" == "frontend" ]] && return 1; return 0; }
  portal_apply()                 { calls="${calls} portal_apply"; return 0; }
  portal_verify()                { calls="${calls} portal_verify"; return 0; }
  addon_export_tls_backup()      { calls="${calls} tls_backup"; return 0; }
  log()      { :; }
  log_warn() { :; }
  ADDON_EXIT_CODE=0
  eval "$(extract_install_branch)"
  printf '%s' "${ADDON_EXIT_CODE}|${calls}"
}

check "Install-Reihenfolge" "0| postgresql geoserver verify_mosaic geoserver_config verify_geoserver_config docker_ensure mapproxy_build mapproxy verify_mapproxy iam frontend_build docker_release frontend portal_apply portal_verify tls_backup" "$(run_install_branch none)"
check "Install verify-Geoserver-Fehler nicht-abbrechend" "1| postgresql geoserver verify_mosaic geoserver_config verify_geoserver_config docker_ensure mapproxy_build mapproxy verify_mapproxy iam frontend_build docker_release frontend portal_apply portal_verify tls_backup" "$(run_install_branch verify_geoserver_config)"

# ── A2: addon_remove_frontend_images (Stub-Zustand) ───────────────────────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"

IMG_STATE="$T/images"
k3s() {
  case "$*" in
    *"images ls"*) cat "$IMG_STATE" 2>/dev/null || true; return 0 ;;
    *"images rm"*)
      local ref
      ref="$(printf '%s' "$*" | sed -n 's/.*images rm \([^ ]*\).*/\1/p')"
      [[ "${IMG_RM_NOOP:-no}" == "yes" ]] && return 0
      grep -vxF "$ref" "$IMG_STATE" > "$IMG_STATE.tmp" 2>/dev/null || true
      mv "$IMG_STATE.tmp" "$IMG_STATE"
      return 0 ;;
  esac
}

printf '%s\n' p2d2-frontend-main:cfg-1 p2d2-frontend-dev:cfg-2 p2d2-frontend-de1:cfg-3 p2d2-frontend-de2:cfg-4 p2d2-frontend-fv:cfg-5 > "$IMG_STATE"
IMG_RM_NOOP=no
addon_remove_frontend_images >/dev/null 2>&1
check "A2 Images entfernt: rc=0" "0" "$?"
check "A2 Images weg" "0" "$(wc -l < "$IMG_STATE")"

printf '%s\n' p2d2-frontend-main:cfg-1 > "$IMG_STATE"
IMG_RM_NOOP=yes
addon_remove_frontend_images >/dev/null 2>&1
check "A2 Image bleibt: rc=1" "1" "$?"

rm -rf "$T"

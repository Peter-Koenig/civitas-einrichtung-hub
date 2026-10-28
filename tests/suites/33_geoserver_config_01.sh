#!/usr/bin/env bash
# Suite 33 Gruppe 01 (automatisch zerlegt).
begin_suite "geoserver_config_01"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (29) Workspaces: leere Liste als "" und als []
scenario "29"
reset_state
export GS_WS_EMPTY_FORM=str
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS leer (str) Exit 0"    "0" "$rc"
check "WS leer (str) 6 angelegt" "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
unset GS_WS_EMPTY_FORM
reset_state
export GS_WS_EMPTY_FORM=arr
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS leer (arr) Exit 0"    "0" "$rc"
check "WS leer (arr) 6 angelegt" "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
unset GS_WS_EMPTY_FORM

# (44) Datastores: Zweitlauf setzt per PUT
scenario "44"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Zweitlauf Exit 0"     "0" "$rc"
check "DS Zweitlauf 5 PUT"      "5" "$(grep -c 'METHOD=PUT' "$CURL_BODY_LOG" || true)"
check "DS Zweitlauf kein POST"  "0" "$(grep 'datastores' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"

# (76) A: Konflikt fehlende Quelle (kein name und kein osm_name)
scenario "76"
ensure_snap_installed
restore_state
jq '.featureType.attributes.attribute = []' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping quelle fehlt Exit 1"  "1" "$rc"
check "A Mapping quelle fehlt Meldung" "yes" "$(grep -q 'weder' "$T/err.log" && echo yes || echo no)"

# (47) Datastores: Dry-run ohne POST/PUT
scenario "47"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "DS Dry-Run Exit 0"           "0" "$rc"
check "DS Dry-Run kein POST/PUT"    "0" "$(grep -c 'METHOD=POST\|METHOD=PUT' "$CURL_BODY_LOG" || true)"
check "DS Dry-Run keine Datastores" "0" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (86) Snapshot, zweiter Lauf: idempotent, keine settings PUT/POST
if want 86; then
scenario "86"
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S86 Exit 0" "0" "$rc"
  check "S86 kein settings PUT/POST" "0" "$(grep -c '/settings' "$CURL_BODY_LOG" || true)"
fi



if want 108; then
scenario "108"
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S108 Exit 0" "0" "$rc"
  check "S108 alle mit max-time" "0" "$(grep -vc -- '--max-time' "$CURL_LOG" || true)"
fi

gs_group_end

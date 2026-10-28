#!/usr/bin/env bash
# Suite 33 Gruppe 03 (automatisch zerlegt).
begin_suite "geoserver_config_03"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (7) --uninstall entfernt nur exakt benannte Objekte
scenario "7"
ensure_snap_installed
restore_state
# Fremde Objekte hinzufügen (nie anzufassen). admin/ADMIN sind bereits als Baseline gesetzt.
printf '%s\n' ROLE_X >> "$GS_STATE_DIR/roles.list"
seed_secret "unrelated-secret" "YWJjZA=="
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Uninstall Exit 0"              "0" "$rc"
check "Uninstall nur admin übrig"     "admin" "$(cat "$GS_STATE_DIR/users.list")"
check "Uninstall ADMIN bleibt"         "yes" "$(grep -q '^ADMIN$' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "Uninstall ROLE_X bleibt"        "yes" "$(grep -q '^ROLE_X$' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "Uninstall 2 Rollen übrig"       "2" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Uninstall Fremd-Secret bleibt" "1" "$(count_secrets)"

# (43) Datastores: Erstlauf legt fünf Datastores mit 20 Einträgen an
scenario "43"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Erstlauf Exit 0"        "0" "$rc"
check "DS Erstlauf 5 Datastores"  "5" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f | awk 'END{print NR}')"
check "DS Payload 20 Einträge"    "20" "$(jq '.dataStore.connectionParameters.entry | length' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null || echo 0)"
check "DS Payload passwd korrekt" "$DB_PW" "$(jq -r '.dataStore.connectionParameters.entry[] | select(."@key"=="passwd") | ."$"' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null)"
check "DS Payload user korrekt"   "P2D2-MAIN" "$(jq -r '.dataStore.connectionParameters.entry[] | select(."@key"=="user") | ."$"' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null)"

# (69) B5: numerische Bounding-Box (-10.0 == -10) → unverändert
scenario "69"
ensure_snap_installed
restore_state
sed 's/"minx": -10,/"minx": -10.0,/g' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp"
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 numerische BBox Exit 0"  "0" "$rc"
check "B5 numerische BBox kein PUT" "0" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# (75) A: Konflikt doppeltes Attribut (name und osm_name)
scenario "75"
ensure_snap_installed
restore_state
jq '.featureType.attributes.attribute = [{"name":"name","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"},{"name":"osm_name","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"}]' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping doppelt Exit 1"   "1" "$rc"
check "A Mapping doppelt Meldung"  "yes" "$(grep -q 'doppeltes Attribut' "$T/err.log" && echo yes || echo no)"

# (48) Datastores: Uninstall löscht Datastores vor Workspaces, ohne recurse
scenario "48"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "DS Uninstall Exit 0"           "0" "$rc"
check "DS Uninstall ohne recurse"     "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"
check "DS Uninstall keine Datastores" "0" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
ds_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'datastores/[^/]*$' | head -1 | cut -d: -f1)"
ws_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'rest/workspaces/[^/]*$' | head -1 | cut -d: -f1)"
check "DS Uninstall Datastores vor Workspaces" "yes" "$([ -n "$ds_line" ] && [ -n "$ws_line" ] && [ "$ds_line" -lt "$ws_line" ] && echo yes || echo no)"

# (67) B1: echter Lesefehler (500 für vorhandenen Datastore) bleibt Fehler
scenario "67"
ensure_snap_installed
restore_state
export GS_FT_LIST_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B1 500 vorhandener Datastore Exit 1" "1" "$rc"
check "B1 500 nicht als leer gewertet"      "yes" "$(grep -q 'FeatureType-Liste für' "$T/err.log" && echo yes || echo no)"
unset GS_FT_LIST_FAIL

# (19) K8: users.json leer -> Plausibilität schlägt fehl -> Exit 2 (Install + Uninstall)
scenario "19"
reset_state
export GS_USERS_EMPTY=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 users leer Install Exit 2" "2" "$rc"
check "K8 users leer kein POST" "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K8 users leer Uninstall Exit 2" "2" "$rc"
unset GS_USERS_EMPTY

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

rm -rf "$T"

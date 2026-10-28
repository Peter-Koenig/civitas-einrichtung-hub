#!/usr/bin/env bash
# Suite 33 Gruppe 07 (automatisch zerlegt).
begin_suite "geoserver_config_07"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (16) Modify-Body enthält <enabled>true</enabled> (K5)
scenario "16"
reset_state
printf '%s\n' p2d2_wfst_main >> "$GS_STATE_DIR/users.list"
mkdir -p "$GS_STATE_DIR/userroles"
: > "$GS_STATE_DIR/userroles/p2d2_wfst_main.list"
rc="$(run_script --url "$URL" --ns "$NS")"
check "K5 Exit 0" "0" "$rc"
check "K5 <enabled>true</enabled>" "yes" "$(grep -q '<enabled>true</enabled>' "$CURL_BODY_LOG" && echo yes || echo no)"

# (73) A: Erstlauf Attribut-Mapping geo-containers (osm_name -> name)
scenario "73"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping Erstlauf Exit 0"          "0" "$rc"
check "A Mapping name mit source osm_name" "osm_name" "$(jq -r '.featureType.attributes.attribute[]? | select(.name=="name") | .source // empty' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" 2>/dev/null)"
check "A Mapping kein osm_name extra"       "" "$(jq -r '[.featureType.attributes.attribute[]?.name] | index("osm_name") // empty' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" 2>/dev/null)"
check "A Mapping 5 PUTs"                    "5" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# (71) B5: Titel-Abweichung → PUT mit Info-Zeile statt FEHLER
scenario "71"
ensure_snap_installed
restore_state
jq '.featureType.title = "X-Titel"' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" > "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/graeber.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 Titel-Abweichung Exit 0"            "0" "$rc"
check "B5 Titel-Abweichung 1 PUT"             "1" "$(grep -c 'featuretypes/graeber METHOD=PUT' "$CURL_BODY_LOG")"
check "B5 Titel-Abweichung Info statt FEHLER" "yes" "$(grep -q 'title weicht ab' "$T/out.log" && echo yes || echo no)"
check "B5 Titel-Abweichung kein FEHLER title" "0" "$(grep -c 'FEHLER.*title weicht ab' "$T/err.log" || true)"

# (53) R7: WMS-Dienstprüfung hart (503 → Exit 1)
scenario "53"
reset_state
export GS_WMS_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "R7 WMS 503 Exit 1"             "1" "$rc"
check "R7 WMS GetCapabilities Meldung" "yes" "$(grep -q 'WMS GetCapabilities' "$T/err.log" && echo yes || echo no)"
unset GS_WMS_FAIL

# (34) Workspaces: nicht-leerer Workspace (403) -> Exit 1, Secrets bleiben
scenario "34"
ensure_snap_installed
restore_state
export GS_WS_NONEMPTY=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS nicht-leer Exit 1"          "1" "$rc"
check "WS nicht-leer Secrets bleiben" "6" "$(count_secrets)"
unset GS_WS_NONEMPTY

# (8) GeoServer-Teilfehler beim Uninstall lässt Secrets stehen
scenario "8"
ensure_snap_installed
restore_state
export GS_DELETE_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Uninstall Teilfehler Exit 1"       "1" "$rc"
check "Uninstall Teilfehler Secrets bleiben" "6" "$(count_secrets)"
unset GS_DELETE_FAIL

# (60) D: Dry-run → kein Schreibaufruf (FeatureTypes)
scenario "60"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "D Dry-Run Exit 0"                  "0" "$rc"
check "D Dry-Run kein FeatureType POST/PUT" "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=POST\|METHOD=PUT')"
check "D Dry-Run keine FeatureTypes"       "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

rm -rf "$T"

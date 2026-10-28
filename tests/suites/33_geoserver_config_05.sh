#!/usr/bin/env bash
# Suite 33 Gruppe 05 (automatisch zerlegt).
begin_suite "geoserver_config_05"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (5) Legacy-Variablen: nur Namen melden, nie Werte
scenario "5"
reset_state
export P2D2_MAIN_WFST_PASSWORD="secretvalue-a"
export WFST_PW_FOO="secretvalue-b"
export WFS_RO_PW="secretvalue-c"
export WFS_PW="secretvalue-d"
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "Legacy WARN P2D2_MAIN_WFST_PASSWORD" "yes" "$(grep -q 'P2D2_MAIN_WFST_PASSWORD' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFST_PW_FOO"            "yes" "$(grep -q 'WFST_PW_FOO' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFS_RO_PW"              "yes" "$(grep -q 'WFS_RO_PW' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFS_PW"                 "yes" "$(grep -q 'WFS_PW ' "$T/err.log" && echo yes || echo no)"
check "Legacy kein Wert secretvalue-a"     "0" "$(grep -c 'secretvalue-a' "$T/err.log")"
check "Legacy kein Wert secretvalue-b"     "0" "$(grep -c 'secretvalue-b' "$T/err.log")"
check "Legacy kein Wert secretvalue-c"     "0" "$(grep -c 'secretvalue-c' "$T/err.log")"
check "Legacy kein Wert secretvalue-d"     "0" "$(grep -c 'secretvalue-d' "$T/err.log")"
unset P2D2_MAIN_WFST_PASSWORD WFST_PW_FOO WFS_RO_PW WFS_PW

# (55a) D: abweichender Default-Style -> PUT-Reparatur
scenario "55a"
reset_state
export GS_DEFAULT_STYLE=point
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Style-Reparatur Exit 0"        "0" "$rc"
check "D Style-Reparatur 25 Default-Style-PUT"  "25" "$(grep -c 'defaultStyle' "$CURL_BODY_LOG" || true)"
unset GS_DEFAULT_STYLE

# (57) D: abweichender Titel → PUT (nur bei Abweichung)
scenario "57"
ensure_snap_installed
restore_state
jq '.featureType.title = "X-Titel"' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" > "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/graeber.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Titel-Abweichung Exit 0"           "0" "$rc"
check "D Titel-Abweichung 1 PUT auf graeber" "1" "$(grep -c 'featuretypes/graeber METHOD=PUT' "$CURL_BODY_LOG")"

# (50) Datastores: Verifikationsfehler (list=available ungleich 200) -> Exit 1
scenario "50"
reset_state
export GS_LIST_AVAILABLE_FAIL_ON=6
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Verifikation list=available Exit 1"  "1" "$rc"
check "DS Verifikation list=available Meldung" "yes" "$(grep -q 'list=available' "$T/err.log" && echo yes || echo no)"
check "DS Verifikation erreicht (FeatureTypes angelegt)" "25" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
unset GS_LIST_AVAILABLE_FAIL_ON

# (49) Datastores: 403 beim Löschen -> Exit 1, Secrets bleiben
scenario "49"
ensure_snap_installed
restore_state
export GS_DS_NONEMPTY=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "DS nicht-leer Exit 1"          "1" "$rc"
check "DS nicht-leer Secrets bleiben" "6" "$(count_secrets)"
unset GS_DS_NONEMPTY

# (84) B: Teilfehler — nur ein Layer-DELETE scheitert; ACL/Rolle bleiben, Rest räumt auf
scenario "84"
ensure_snap_installed
restore_state
export GS_LAYER_DELETE_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B ACL Layer bleibt Exit 1"           "1" "$rc"
check "B ACL Layer bleibt Regel bleibt"     "yes" "$(jq -e 'has("main.geo-containers.r")' "$GS_STATE_DIR/acl.map" >/dev/null 2>&1 && echo yes || echo no)"
check "B ACL Layer bleibt Rolle bleibt"     "yes" "$(grep -q 'P2D2_IMPORT_ROLE' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "B ACL Layer bleibt FeatureType weg"  "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "B ACL Layer bleibt WFS-USER weg"    "yes" "$(grep -qx 'WFS-USER' "$GS_STATE_DIR/roles.list" && echo no || echo yes)"
unset GS_LAYER_DELETE_FAIL

# (28) Workspaces: Konflikt (abweichende URI) -> Exit 1, keine Änderung, Rest läuft
scenario "28"
reset_state
seed_workspace "main" "urn:data-dna:govdata:WRONG"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Konflikt Exit 1"               "1" "$rc"
check "WS Konflikt main URI unverändert" "urn:data-dna:govdata:WRONG" "$(cat "$GS_STATE_DIR/namespaces/main.uri")"
check "WS Konflikt 5 weitere angelegt"   "5" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

gs_group_end

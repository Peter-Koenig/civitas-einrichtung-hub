#!/usr/bin/env bash
# Suite 33 Gruppe 06 (automatisch zerlegt).
begin_suite "geoserver_config_06"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (10) Negativtest liefert 200 -> WARN
scenario "10"
reset_state
export GS_NEG200=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "Negativtest-200 Exit 0"  "0" "$rc"
check "Negativtest-200 WARN"    "yes" "$(grep -q 'Negativtest' "$T/err.log" && echo yes || echo no)"
unset GS_NEG200

# (68) B4: Meldungen mit <ws>/<name>-Präfix
scenario "68"
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "B4 Präfix main/geo-containers angelegt"      "yes" "$(grep -q 'main/geo-containers angelegt' "$T/out.log" && echo yes || echo no)"
check "B4 Präfix main/graeber DescribeFeatureType"  "yes" "$(grep -q 'main/graeber: DescribeFeatureType ok' "$T/out.log" && echo yes || echo no)"

# (70) B5: metadata.entry als Array → unverändert
scenario "70"
ensure_snap_installed
restore_state
jq '.featureType.metadata.entry = [.featureType.metadata.entry]' "$GS_STATE_DIR/ft/main/main_pg/grabflure.json" > "$GS_STATE_DIR/ft/main/main_pg/grabflure.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/grabflure.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/grabflure.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 metadata-Array Exit 0"  "0" "$rc"
check "B5 metadata-Array kein PUT" "0" "$(grep -c 'featuretypes/grabflure METHOD=PUT' "$CURL_BODY_LOG")"

# (35) Workspaces: aggregierter Verifikationsfehler -> Exit 1
scenario "35"
reset_state
export GS_WS_VERIFY_BAD=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Verifikation Fehler Exit 1" "1" "$rc"
check "WS Verifikation Meldung"       "yes" "$(grep -q 'weicht ab' "$T/err.log" && echo yes || echo no)"
unset GS_WS_VERIFY_BAD

# (33) Workspaces: DELETE 404 gilt als schon weg
scenario "33"
ensure_snap_installed
restore_state
export GS_WS_DELETE_404=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS 404 Exit 0"    "0" "$rc"
check "WS 404 schon weg" "yes" "$(grep -q 'schon weg' "$T/out.log" && echo yes || echo no)"
unset GS_WS_DELETE_404

# (30) Workspaces: Workspace ohne Namespace -> Exit 1, übrige laufen weiter
scenario "30"
reset_state
seed_workspace "dev"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS ohne Namespace Exit 1"  "1" "$rc"
check "WS ohne Namespace Meldung" "yes" "$(grep -q 'Namespace nicht lesbar' "$T/err.log" && echo yes || echo no)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (94) --dry-run: Exit 0, keine Mutation, How-To im Dry-run-Modus
if want 94; then
scenario "94"
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
  check "S94 Exit 0" "0" "$rc"
  check "S94 keine Mutation" "0" "$(grep -cE 'METHOD=(POST|PUT|DELETE)' "$CURL_BODY_LOG" || true)"
  howto_file="$(latest_howto)"
  check "S94 How-To dry-run" "yes" "$(grep -q 'dry-run' "$howto_file" && echo yes || echo no)"
fi

gs_group_end

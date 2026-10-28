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


if want 100; then
scenario "100"
  ensure_snap_installed
  restore_state
  export GS_CAPS_EXCEPTION=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S100 Exit 1" "1" "$rc"
  check "S100 nennt ExceptionReport" "yes" "$(grep -q 'ExceptionReport' "$T/err.log" && echo yes || echo no)"
  unset GS_CAPS_EXCEPTION
fi


if want 106; then
scenario "106"
  ensure_snap_installed
  restore_state
  vor="$(normalize_state "$GS_STATE_DIR" "$KUBE_STATE_DIR" | sha256sum | cut -d' ' -f1)"
  rc="$(run_script --uninstall --dry-run --url "$URL" --ns "$NS")"
  check "S106 Exit 0" "0" "$rc"
  check "S106 0 DELETE" "0" "$(grep -c '\-X DELETE' "$CURL_LOG" || true)"
  nach="$(normalize_state "$GS_STATE_DIR" "$KUBE_STATE_DIR" | sha256sum | cut -d' ' -f1)"
  check "S106 Zustand unveraendert" "$vor" "$nach"
  check "S106 kein WARN behalten" "0" "$(grep -c 'behalten' "$T/err.log" || true)"
  check "S106 kein bleibt" "0" "$(grep -c 'bleibt' "$T/err.log" || true)"
  check "S106 Plan FeatureTypes 25" "25" "$(grep -c 'Layer und FeatureType wuerden entfernt' "$T/out.log" || true)"
  check "S106 Plan ACL 50" "50" "$(grep -c 'ACL .* entfaellt mit dem Layer' "$T/out.log" || true)"
  check "S106 Plan Datastores 5" "5" "$(grep -c 'Datastore .* wuerde entfernt' "$T/out.log" || true)"
  check "S106 Plan Workspaces 6" "6" "$(grep -c 'Workspace .* wuerde entfernt' "$T/out.log" || true)"
  check "S106 Plan Zuordnungen 6" "6" "$(grep -c 'Zuordnung .* wuerde entfernt' "$T/out.log" || true)"
  check "S106 Plan Benutzer 6" "6" "$(grep -c 'Benutzer .* wuerde entfernt' "$T/out.log" || true)"
  check "S106 Plan Rollen 6" "6" "$(grep -c 'Rolle .* wuerde entfernt' "$T/out.log" || true)"
  check "S106 Plan Secrets 6" "6" "$(grep -c 'Secret .* wuerde entfernt' "$T/out.log" || true)"
  restore_state
  rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
  check "S106 Ist Exit 0" "0" "$rc"
  check "S106 Ist FeatureType 25" "25" "$(grep -c 'FeatureType gelöscht' "$T/out.log" || true)"
  check "S106 Ist Datastore 5" "5" "$(grep -c 'Datastore .* gelöscht' "$T/out.log" || true)"
  check "S106 Ist Workspace 6" "6" "$(grep -c 'Workspace .* gelöscht' "$T/out.log" || true)"
  check "S106 Ist Zuordnung 6" "6" "$(grep -c 'Zuordnung .* gelöst' "$T/out.log" || true)"
  check "S106 Ist Benutzer 6" "6" "$(grep -c 'Benutzer .* gelöscht' "$T/out.log" || true)"
  check "S106 Ist Rolle 6" "6" "$(grep -c 'Rolle .* gelöscht' "$T/out.log" || true)"
fi

gs_group_end

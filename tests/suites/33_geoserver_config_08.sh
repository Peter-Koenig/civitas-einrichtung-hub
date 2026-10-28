#!/usr/bin/env bash
# Suite 33 Gruppe 08 (automatisch zerlegt).
begin_suite "geoserver_config_08"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (23) How-To: enthält keinen Passwortwert
scenario "23"
reset_state
for n in p2d2-geoserver-wfst-main p2d2-geoserver-wfst-develop p2d2-geoserver-wfst-de1 \
         p2d2-geoserver-wfst-de2 p2d2-geoserver-wfst-fv p2d2-geoserver-wfs-user; do
  seed_secret "$n" "$PASS_VALID_B64"
done
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "How-To vorhanden"        "yes" "$([ -n "$howto_file" ] && echo yes || echo no)"
check "How-To kein Passwortwert" "0" "$(grep -c "$PASS_VALID" "$howto_file" 2>/dev/null || true)"
check "How-To kein base64"       "0" "$(grep -c "$PASS_VALID_B64" "$howto_file" 2>/dev/null || true)"

scenario "24"
check "How-To Konventionen"      "yes" "$(grep -q '## Konventionen' "$howto_file" && echo yes || echo no)"
check "How-To Lesende Schritte"  "yes" "$(grep -q '## Lesende Schritte' "$howto_file" && echo yes || echo no)"
check "How-To Secret-Schritte"   "yes" "$(grep -q '## Secret-Schritte' "$howto_file" && echo yes || echo no)"
check "How-To Verifikation"      "yes" "$(grep -q '## Verifikation' "$howto_file" && echo yes || echo no)"
check "How-To Entscheidungslogik" "yes" "$(grep -q '## Entscheidungslogik' "$howto_file" && echo yes || echo no)"
check "How-To erhaltene Codes"   "yes" "$(grep -q 'erhalten 20' "$howto_file" && echo yes || echo no)"
check "How-To Modus ausgeführt"  "yes" "$(grep -q 'Modus: ausgeführt' "$howto_file" && echo yes || echo no)"
check "How-To Workspaces Abschnitt" "yes" "$(grep -q '## Workspaces' "$howto_file" && echo yes || echo no)"

# (79) B: fremde Regeln bleiben unverändert
scenario "79"
reset_state
printf '%s' '{"foreign.layer.r":"ROLE_X"}' > "$GS_STATE_DIR/acl.map"
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL fremd Exit 0"      "0" "$rc"
check "B ACL fremd bleibt"      "ROLE_X" "$(jq -r '."foreign.layer.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL fremd + 50 eigene" "51" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# (80) B: Konflikt (gleiche Regel, andere Rollen) -> Exit 1, keine Änderung
scenario "80"
reset_state
printf '%s' '{"main.geo-containers.r":"SOMETHING_ELSE"}' > "$GS_STATE_DIR/acl.map"
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Konflikt Exit 1"   "1" "$rc"
check "B ACL Konflikt Meldung"  "yes" "$(grep -q 'Konflikt' "$T/err.log" && echo yes || echo no)"
check "B ACL Konflikt unverändert" "SOMETHING_ELSE" "$(jq -r '."main.geo-containers.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# (37) A1: Uninstall-Schlussverifikation mit leerer Liste -> Exit 1
scenario "37"
ensure_snap_installed
restore_state
export GS_USERS_EMPTY_ON=2
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "A1 Schlussverifikation Exit 1"         "1" "$rc"
check "A1 keine Uninstall-verifiziert-Zeile"  "0" "$(grep -c 'Uninstall verifiziert' "$T/out.log" || true)"
unset GS_USERS_EMPTY_ON

# (11) Dry-Run Install/Uninstall: Exit 0, keine Verifikationsfehler (K1/K2)
scenario "11"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "K1 Dry-Run-Install Exit 0"   "0" "$rc"
check "K1 Verifikation übersprungen" "0" "$(grep -c 'kein Passwort' "$T/err.log" || true)"

# K2: erst real anlegen, dann Dry-Run-Uninstall (Objekte bleiben, Verifikation übersprungen).
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --dry-run --uninstall --url "$URL" --ns "$NS")"
check "K2 Dry-Run-Uninstall Exit 0" "0" "$rc"
check "K2 Verifikation übersprungen" "0" "$(grep -c 'noch vorhanden' "$T/err.log" || true)"

# (82) B: Dry-run ohne ACL-POST
scenario "82"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "B ACL Dry-Run Exit 0"       "0" "$rc"
check "B ACL Dry-Run kein POST"    "0" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG" || true)"
check "B ACL Dry-Run keine Regeln" "0" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (87) Snapshot, dev lokal auf 4: genau ein Reparatur-PUT auf dev
if want 87; then
scenario "87"
  ensure_snap_installed
  restore_state
  jq '.settings.numDecimals = 4' "$GS_STATE_DIR/settings/dev.json" > "$GS_STATE_DIR/settings/dev.json.tmp" 2>/dev/null
  mv "$GS_STATE_DIR/settings/dev.json.tmp" "$GS_STATE_DIR/settings/dev.json"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S87 Exit 0" "0" "$rc"
  check "S87 genau 1 settings PUT dev" "1" "$(grep -c 'workspaces/dev/settings METHOD=PUT' "$CURL_BODY_LOG")"
  check "S87 Info weicht ab" "yes" "$(grep -q 'weichen ab' "$T/out.log" && echo yes || echo no)"
fi


if want 110; then
scenario "110"
  reset_state
  export GS_NOT_READY_FIRST=99
  export GS_WAIT_SECONDS=0
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S110 Exit 2" "2" "$rc"
  check "S110 nicht erreichbar" "yes" "$(grep -q 'nicht erreichbar' "$T/err.log" && echo yes || echo no)"
  unset GS_NOT_READY_FIRST GS_WAIT_SECONDS
fi


if want 102; then
scenario "102"
  ensure_snap_installed
  restore_state
  export GS_GEOJSON_PROP_DECIMALS=1
  export GS_IGNORE_SETTINGS=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S102 (a) Exit 1" "1" "$rc"
  unset GS_GEOJSON_PROP_DECIMALS GS_IGNORE_SETTINGS
  restore_state
  export GS_GEOJSON_EMPTY=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S102 (b) Exit 0" "0" "$rc"
  check "S102 (b) WARN keine Features" "yes" "$(grep -q 'keine Features' "$T/err.log" && echo yes || echo no)"
  unset GS_GEOJSON_EMPTY
fi

gs_group_end

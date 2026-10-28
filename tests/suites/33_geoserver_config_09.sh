#!/usr/bin/env bash
# Suite 33 Gruppe 09 (automatisch zerlegt).
begin_suite "geoserver_config_09"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (26) Workspaces: Erstlauf legt sechs Workspaces mit korrektem Payload an
scenario "26"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Erstlauf Exit 0"              "0" "$rc"
check "WS Erstlauf 6 Workspaces"        "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
check "WS main URI"                     "urn:data-dna:govdata:main" "$(cat "$GS_STATE_DIR/namespaces/main.uri")"
check "WS friedhofsplaene URI"          "urn:data-dna:tiffdata" "$(cat "$GS_STATE_DIR/namespaces/friedhofsplaene.uri")"
check "WS Payload prefix main"          "yes" "$(grep -q '"prefix":"main"' "$CURL_BODY_LOG" && echo yes || echo no)"
check "WS Payload uri main"             "yes" "$(grep -q '"uri":"urn:data-dna:govdata:main"' "$CURL_BODY_LOG" && echo yes || echo no)"
check "WS kein Passwort in curl-Args"    "0" "$(grep -c "$PASS_VALID" "$CURL_LOG" || true)"
check "WS kein Passwort in kubectl-Args" "0" "$(grep -c "$PASS_VALID" "$KUBECTL_LOG" || true)"

# (21) K8: Uninstall-Schlussverifikation Lesefehler -> Exit 1, keine Erfolgsmeldung
scenario "21"
ensure_snap_installed
restore_state
export GS_USERS_FAIL_ON=2
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K8 Schlussverifikation Lesefehler Exit 1" "1" "$rc"
check "K8 Schlussverifikation keine Erfolgsmeldung" "0" "$(grep -c 'Uninstall verifiziert' "$T/out.log" || true)"
unset GS_USERS_FAIL_ON

# (83) B: Uninstall entfernt eigene Regeln, fremde bleiben (nicht exakt 50 DELETEs)
scenario "83"
ensure_snap_installed
restore_state
# Fremde Regel nach dem Install dazulegen (bleibt bei Uninstall erhalten).
printf '%s' '{"foreign.layer.r":"ROLE_X"}' > "$GS_STATE_DIR/acl.add"
jq -s '.[0] * .[1]' "$GS_STATE_DIR/acl.map" "$GS_STATE_DIR/acl.add" > "$GS_STATE_DIR/acl.map.new" 2>/dev/null
mv "$GS_STATE_DIR/acl.map.new" "$GS_STATE_DIR/acl.map"
rm -f "$GS_STATE_DIR/acl.add"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B ACL Uninstall Exit 0"        "0" "$rc"
check "B ACL Uninstall eigene weg"    "no" "$(jq -e 'has("main.geo-containers.r")' "$GS_STATE_DIR/acl.map" >/dev/null 2>&1 && echo yes || echo no)"
check "B ACL Uninstall fremde bleibt" "ROLE_X" "$(jq -r '."foreign.layer.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL Uninstall nur fremde"    "1" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# (31) Workspaces: Dry-run ohne POST
scenario "31"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "WS Dry-Run Exit 0"               "0" "$rc"
check "WS Dry-Run kein namespaces POST" "0" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"
check "WS Dry-Run keine Workspaces"     "0" "$(count_lines "$GS_STATE_DIR/workspaces.list")"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (85) leerer Zustand, Install: Einstellungen + Dienst-Metadaten + 8 Stellen
if want 85; then
scenario "85"
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S85 Exit 0" "0" "$rc"
  check "S85 numDecimals 8 (5 WS)" "5" "$(for ws in main dev de1 de2 fv; do jq -r '.settings.numDecimals // empty' "$GS_STATE_DIR/settings/$ws.json" 2>/dev/null; done | grep -c '^8$')"
  check "S85 charset UTF-8 (5 WS)" "5" "$(for ws in main dev de1 de2 fv; do jq -r '.settings.charset // empty' "$GS_STATE_DIR/settings/$ws.json" 2>/dev/null; done | grep -c '^UTF-8$')"
  check "S85 Kontakt main" "info@data-dna.eu" "$(jq -r '.settings.contact.contactEmail // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
  check "S85 10 Dienst-Einstellungen" "10" "$(find "$GS_STATE_DIR/service" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
  check "S85 GetFeature 8 Stellen" "5" "$(grep -c 'mit 8 Nachkommastellen' "$T/out.log")"
fi

# (88) Snapshot: charset und contact.id bleiben (Ersetzen-Falle)
if want 88; then
scenario "88"
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S88 Exit 0" "0" "$rc"
  check "S88 charset bleibt" "UTF-8" "$(jq -r '.settings.charset // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
  check "S88 contact.id bleibt" "contact" "$(jq -r '.settings.contact.id // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
fi

# (92) GS_CAPS_NO_TITLE=1: Exit 1 aus der Capabilities-Verifikation
if want 92; then
scenario "92"
  ensure_snap_installed
  restore_state
  export GS_CAPS_NO_TITLE=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S92 Exit 1" "1" "$rc"
  unset GS_CAPS_NO_TITLE
fi

rm -rf "$T"

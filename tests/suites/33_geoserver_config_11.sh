#!/usr/bin/env bash
# Suite 33 Gruppe 11 (automatisch zerlegt).
begin_suite "geoserver_config_11"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (41) R1: Workspace-Verifikation sichtbar (log_ok + howto_step)
scenario "41"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "R1 Exit 0"                       "0" "$rc"
check "R1 Namespace-URI ok sichtbar"    "yes" "$(grep -q 'Namespace-URI ok' "$T/out.log" && echo yes || echo no)"
check "R1 WMS GetCapabilities sichtbar" "yes" "$(grep -q 'WMS GetCapabilities 200' "$T/out.log" && echo yes || echo no)"
check "R1 WFS GetCapabilities sichtbar" "yes" "$(grep -q 'WFS GetCapabilities 200' "$T/out.log" && echo yes || echo no)"

# (3) Vorhandener gültiger Secret-Wert wird wiederverwendet; kein Passwort in Args
scenario "3"
reset_state
for n in p2d2-geoserver-wfst-main p2d2-geoserver-wfst-develop p2d2-geoserver-wfst-de1 \
         p2d2-geoserver-wfst-de2 p2d2-geoserver-wfst-fv p2d2-geoserver-wfs-user; do
  seed_secret "$n" "$PASS_VALID_B64"
done
rc="$(run_script --url "$URL" --ns "$NS")"
check "Reuse Exit 0"            "0" "$rc"
check "Reuse kein Apply"        "0" "$(grep -c 'apply' "$KUBECTL_LOG")"
check "Reuse MAIN-Wert bleibt"  "$PASS_VALID_B64" "$(cat "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64")"
check "Reuse kein Passwort in curl-Args"   "0" "$(grep -c "$PASS_VALID" "$CURL_LOG")"
check "Reuse kein base64 in curl-Args"     "0" "$(grep -c "$PASS_VALID_B64" "$CURL_LOG")"
check "Reuse kein Passwort in kubectl-Args" "0" "$(grep -c "$PASS_VALID" "$KUBECTL_LOG")"
check "Reuse kein base64 in kubectl-Args"   "0" "$(grep -c "$PASS_VALID_B64" "$KUBECTL_LOG")"

# (77) B: Erstlauf 50 Layer-ACLs mit Stage-Trennung
scenario "77"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Erstlauf Exit 0"             "0" "$rc"
check "B ACL 50 Regeln"                    "50" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL 50 POSTs"                     "50" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG")"
check "B ACL Stage-Trennung (de1)"         "P2D2_WFST_DE1,ADMIN" "$(jq -r '."de1.grabflure_versionen.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL geo-containers write"         "ADMIN" "$(jq -r '."main.geo-containers.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL grabflure write"              "ADMIN" "$(jq -r '."main.grabflure.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# (64) B2: zweiter Uninstall idempotent
scenario "64"
ensure_snap_installed
restore_state
run_script --uninstall --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B2 zweiter Uninstall Exit 0"      "0" "$rc"
check "B2 zweiter Uninstall verifiziert" "yes" "$(grep -q 'Uninstall verifiziert' "$T/out.log" && echo yes || echo no)"

# (13) Teilzustand (ein Benutzer fehlt, ein Secret fehlt) sauber aufgeräumt
scenario "13"
ensure_snap_installed
restore_state
grep -vx 'p2d2_wfst_de2' "$GS_STATE_DIR/users.list" > "$GS_STATE_DIR/users.list.tmp" 2>/dev/null || true
mv "$GS_STATE_DIR/users.list.tmp" "$GS_STATE_DIR/users.list"
rm -f "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-de2.b64"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Teilzustand Uninstall Exit 0" "0" "$rc"
check "Teilzustand nur admin übrig" "1" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Teilzustand nur ADMIN übrig"  "1" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Teilzustand keine Secrets übrig"  "0" "$(count_secrets)"

# (81) B: Lesefehler (GET acl) -> Exit 1
scenario "81"
reset_state
export GS_ACL_GET_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Lesefehler Exit 1" "1" "$rc"
unset GS_ACL_GET_FAIL

# (12) Zweiter --uninstall auf leerem GeoServer -> Exit 0, kein DELETE (K3)
scenario "12"
reset_state
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K3 leerer Uninstall Exit 0" "0" "$rc"
check "K3 leerer Uninstall kein DELETE" "0" "$(grep -c '\-X DELETE' "$CURL_LOG" || true)"

# (66) B3: Dry-run Uninstall auf leerem System
scenario "66"
reset_state
clear_logs
rc="$(run_script --dry-run --uninstall --url "$URL" --ns "$NS")"
check "B3 Dry-Run leer Uninstall Exit 0"       "0" "$rc"
check "B3 Dry-Run leer Uninstall keine FEHLER" "0" "$(grep -c 'FEHLER' "$T/err.log" || true)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy



if want 105; then
scenario "105"
  ensure_snap_installed
  restore_state
  printf '%s' '{"main.geo-containers.w":"P2D2_IMPORT_ROLE,ADMIN"}' > "$GS_STATE_DIR/acl.add"
  jq -s '.[0] * .[1]' "$GS_STATE_DIR/acl.map" "$GS_STATE_DIR/acl.add" > "$GS_STATE_DIR/acl.map.new" 2>/dev/null
  mv "$GS_STATE_DIR/acl.map.new" "$GS_STATE_DIR/acl.map"
  rm -f "$GS_STATE_DIR/acl.add"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S105 Exit 1" "1" "$rc"
  check "S105 Konflikt Meldung" "yes" "$(grep -q 'Konflikt' "$T/err.log" && echo yes || echo no)"
  check "S105 Regel bleibt" "P2D2_IMPORT_ROLE,ADMIN" "$(jq -r '."main.geo-containers.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
fi

gs_group_end

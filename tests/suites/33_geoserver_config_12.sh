#!/usr/bin/env bash
# Suite 33 Gruppe 12 (automatisch zerlegt).
begin_suite "geoserver_config_12"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (51) Datastores: kein DB-Passwort in Argumentlisten von curl/kubectl/jq
scenario "51"
reset_state
export JQ_LOG_ARGS=1
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "DS kein DB-Passwort in curl-Args"    "0" "$(grep -c "$DB_PW" "$CURL_LOG" || true)"
check "DS kein DB-Passwort in kubectl-Args" "0" "$(grep -c "$DB_PW" "$KUBECTL_LOG" || true)"
check "DS kein DB-Passwort in jq-Args"      "0" "$(grep -c "$DB_PW" "$JQ_LOG" || true)"
unset JQ_LOG_ARGS

# (22) K8: anderer Admin-Name per GS_ADMIN_USER funktioniert
scenario "22"
reset_state
printf '%s\n' customadmin > "$GS_STATE_DIR/users.list"
export GS_ADMIN_USER=customadmin
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 customadmin Exit 0" "0" "$rc"
unset GS_ADMIN_USER

# (27) Workspaces: Zweitlauf idempotent
scenario "27"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Zweitlauf Exit 0"               "0" "$rc"
check "WS Zweitlauf weiterhin 6"          "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
check "WS Zweitlauf kein namespaces POST" "0" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"

# (78) B: Zweitlauf ohne unnötige Mutation
scenario "78"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Zweitlauf Exit 0"     "0" "$rc"
check "B ACL Zweitlauf kein POST"  "0" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG" || true)"

# (63) B1: Uninstall nach Install — kein 500, „Uninstall verifiziert"
scenario "63"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B1 Uninstall Exit 0"                 "0" "$rc"
check "B1 kein featuretypes.json 500"       "0" "$(grep -c 'featuretypes.json fehlgeschlagen (HTTP 500)' "$T/err.log" || true)"
check "B1 Uninstall verifiziert"            "yes" "$(grep -q 'Uninstall verifiziert' "$T/out.log" && echo yes || echo no)"

# (46) Datastores: fehlendes Secret -> Fehler der Stage, übrige laufen, Exit 1
scenario "46"
reset_state
rm -f "$KUBE_STATE_DIR/secrets/p2d2-main-secret.dbpw"
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS fehlendes Secret Exit 1"        "1" "$rc"
check "DS fehlendes Secret 4 weitere"     "4" "$(grep 'datastores' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"
check "DS fehlendes Secret kein main POST" "0" "$(grep -c 'workspaces/main/datastores METHOD=POST' "$CURL_BODY_LOG" || true)"

# (14) GS_BASE leer -> Exit 2 mit Hinweis (K4)
scenario "14"
reset_state
rc="$(run_script --ns "$NS")"
check "K4 GS_BASE leer Exit 2" "2" "$rc"
check "K4 GS_BASE leer Hinweis" "yes" "$(grep -q 'GS_BASE leer' "$T/err.log" && echo yes || echo no)"

# (17) _secret_apply schlägt fehl -> Exit 1, Meldung, kein User-POST (K7)
scenario "17"
reset_state
export KUBECTL_APPLY_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K7 Exit 1"          "1" "$rc"
check "K7 klare Meldung"   "yes" "$(grep -q 'konnte nicht gespeichert werden' "$T/err.log" && echo yes || echo no)"
check "K7 kein User-POST"  "0" "$(grep -c 'security/usergroup/users$' "$CURL_LOG" || true)"
unset KUBECTL_APPLY_FAIL

# (18) --help/-h -> Exit 0, Hilfe auf stdout (K6)
scenario "18"
rc="$(run_script --help)"
check "--help Exit 0" "0" "$rc"
check "--help Usage auf stdout" "yes" "$(grep -q 'Usage:' "$T/out.log" && echo yes || echo no)"
rc="$(run_script -h)"
check "-h Exit 0" "0" "$rc"

# (20) K8: users.json HTTP 500 -> Exit 2
scenario "20"
reset_state
export GS_USERS_500=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 users 500 Exit 2" "2" "$rc"
unset GS_USERS_500

# (36) Workspaces: Startprüfung SOL/WS (tampered copy)
scenario "36"
reset_state
sed 's/main|urn:data-dna:govdata:main//' "$SCRIPT" > "$T/script-ws-missing.sh"
# Vollständiges Bundle für die mutierte Einstiegskopie bereitstellen (Loader braucht geoserver-config/).
cp -r "$REPO/supplement/geoserver-config" "$T/geoserver-config"
rc="$( cd "$WORK" && bash "$T/script-ws-missing.sh" --url "$URL" --ns "$NS" >"$T/out.log" 2>"$T/err.log"; printf '%s' "$?" )"
check "WS Startprüfung Exit 2"  "2" "$rc"
check "WS Startprüfung Meldung" "yes" "$(grep -q 'fehlt in WS_TABLE' "$T/err.log" && echo yes || echo no)"

# (39) A2: Passwort mit Zeilenumbruch -> Exit 2
scenario "39"
reset_state
export GS_ADMIN_PW=$'secret\nline2'
rc="$(run_script --url "$URL" --ns "$NS")"
check "A2 newline Exit 2" "2" "$rc"
unset GS_ADMIN_PW

# (40) A3: Lesefehler hinterlässt keine Temp-Datei
scenario "40"
reset_state
mkdir -p "$T/tmpdir"
export TMPDIR="$T/tmpdir"
export GS_USERS_500=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "A3 Lesefehler Exit 2"      "2" "$rc"
check "A3 keine Temp-Datei übrig" "0" "$(find "$T/tmpdir" -type f | awk 'END{print NR}')"
unset GS_USERS_500 TMPDIR

# (45) Datastores: fehlender ENV-Schlüssel -> Exit 2 ohne Mutation
scenario "45"
reset_state
unset P2D2_BASE_DB_NAME
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS fehlender ENV Exit 2"    "2" "$rc"
check "DS fehlender ENV kein POST" "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
export P2D2_BASE_DB_NAME="p2d2"

# (59) D: fehlender Stil → Exit 2, keine Mutation
scenario "59"
reset_state
export GS_STYLE_POLYGON_MISSING=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D fehlender Stil Exit 2"          "2" "$rc"
check "D fehlender Stil keine FeatureTypes" "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "D fehlender Stil keine Secrets"    "0" "$(count_secrets)"
unset GS_STYLE_POLYGON_MISSING

# (72) B6/B7: Hilfe und How-To
scenario "72"
rc="$(run_script --help)"
check "B6 --help nennt FeatureTypes" "yes" "$(grep -q 'FeatureTypes' "$T/out.log" && echo yes || echo no)"

ensure_snap_installed
restore_state
howto_file="$(latest_howto)"
check "B7 How-To Ausgeführte Schritte" "yes" "$(grep -q '## Ausgeführte Schritte' "$howto_file" && echo yes || echo no)"
check "B7 How-To Body-Skelett"         "yes" "$(grep -q 'nativeBoundingBox' "$howto_file" && echo yes || echo no)"
check "B7 How-To FT_TABLE"             "yes" "$(grep -q 'geo-containers|p2d2_containers' "$howto_file" && echo yes || echo no)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (89) GS_SETTINGS_PUT_DROPS_KEY=charset: Exit 1, verlorener Schlüssel gemeldet
if want 89; then
scenario "89"
  ensure_snap_installed
  restore_state
  export GS_SETTINGS_PUT_DROPS_KEY=charset
  jq '.settings.numDecimals = 3' "$GS_STATE_DIR/settings/dev.json" > "$GS_STATE_DIR/settings/dev.json.tmp" 2>/dev/null
  mv "$GS_STATE_DIR/settings/dev.json.tmp" "$GS_STATE_DIR/settings/dev.json"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S89 Exit 1" "1" "$rc"
  check "S89 Meldung verlorener Schlüssel" "yes" "$(grep -q 'charset' "$T/err.log" && echo yes || echo no)"
  unset GS_SETTINGS_PUT_DROPS_KEY
fi

# (90) YAML mit TODO: Exit 2 ohne Mutation; mit --allow-incomplete-metadata: Exit 0 + WARN
if want 90; then
scenario "90"
  reset_state
  bundle_copy "$T/todo"
  sed 's|license: "ODbL-1.0"|license: "TODO"|' "$REPO/supplement/geoserver-metadata.md" > "$T/todo/geoserver-metadata.md"
  rc="$(run_bundle "$T/todo" --url "$URL" --ns "$NS")"
  check "S90 TODO Exit 2" "2" "$rc"
  check "S90 TODO keine Mutation" "0" "$(grep -cE 'METHOD=(POST|PUT|DELETE)' "$CURL_BODY_LOG" || true)"
  clear_logs
  rc="$(run_bundle "$T/todo" --allow-incomplete-metadata --url "$URL" --ns "$NS")"
  check "S90 allow Exit 0" "0" "$rc"
  check "S90 allow WARN" "yes" "$(grep -q 'unvollständig' "$T/err.log" && echo yes || echo no)"
fi

# (91) Snapshot: Titel/Abstract je Workspace korrekt aufgelöst
if want 91; then
scenario "91"
  ensure_snap_installed
  check "S91 dev WMS-Titel" "p2d2 Karten – dev" "$(jq -r '.wms.title // empty' "$GS_STATE_DIR/service/dev/wms.json" 2>/dev/null)"
  check "S91 de1 WFS-Abstract Team-Staging DE1" "yes" "$(jq -r '.wfs.abstrct // empty' "$GS_STATE_DIR/service/de1/wfs.json" 2>/dev/null | grep -q 'Team-Staging DE1' && echo yes || echo no)"
fi

rm -rf "$T"

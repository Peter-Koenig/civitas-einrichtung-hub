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

# (97) Dry-run auf sauberem Stand (L1): vollstaendiger Plan, keine Mutation
if want 97; then
scenario "97"
  reset_state
  rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
  check "S97 Dry-run Exit 0" "0" "$rc"
  check "S97 keine Mutation" "0" "$(grep -cE 'METHOD=(POST|PUT|DELETE)' "$CURL_BODY_LOG" || true)"
  check "S97 Plan Workspace-Einstellungen" "yes" "$(grep -q 'Workspace-Einstellungen' "$T/out.log" && echo yes || echo no)"
  check "S97 Plan Dienst-Metadaten" "yes" "$(grep -q 'Dienst-Metadaten' "$T/out.log" && echo yes || echo no)"
  check "S97 Plan Datastores" "yes" "$(grep -q 'Datastores' "$T/out.log" && echo yes || echo no)"
  check "S97 Plan FeatureTypes" "yes" "$(grep -q 'FeatureTypes' "$T/out.log" && echo yes || echo no)"
  check "S97 Plan Attribut-Mapping" "yes" "$(grep -q 'Attribut-Mapping' "$T/out.log" && echo yes || echo no)"
  check "S97 Plan Layer-ACLs" "yes" "$(grep -q 'Layer-ACLs' "$T/out.log" && echo yes || echo no)"
  check "S97 kein FEHLER" "0" "$(grep -c 'FEHLER' "$T/err.log" || true)"
fi

# (98) Anlegen auf sauberem Stand (L2/L4): name/enabled gesetzt, kein POST-Fallback
if want 98; then
scenario "98"
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S98 Exit 0" "0" "$rc"
  check "S98 kein POST auf Dienst-Settings" "0" "$(grep -c 'services/.*/workspaces/.*/settings METHOD=POST' "$CURL_BODY_LOG" || true)"
  check "S98 10 OK angelegt" "10" "$(grep -c 'Dienst-Metadaten.*angelegt' "$T/out.log")"
  for ws in main dev de1 de2 fv; do
    for svc in wms wfs; do
      exp="$(printf '%s' "$svc" | tr 'a-z' 'A-Z')"
      check "S98 $ws/$svc name" "$exp" "$(jq -r ".$svc.name // empty" "$GS_STATE_DIR/service/$ws/$svc.json" 2>/dev/null)"
      check "S98 $ws/$svc enabled" "true" "$(jq -r ".$svc.enabled // empty" "$GS_STATE_DIR/service/$ws/$svc.json" 2>/dev/null)"
    done
  done
fi

# (99) Reparatur: enabled/name werden gesetzt (L4), Zweitlauf ohne PUT
if want 99; then
scenario "99"
  ensure_snap_installed
  restore_state
  printf '%s' '{"wms":{"title":"alt","enabled":false}}' > "$GS_STATE_DIR/service/main/wms.json"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S99 Reparatur Exit 0" "0" "$rc"
  check "S99 main/wms name WMS" "WMS" "$(jq -r '.wms.name // empty' "$GS_STATE_DIR/service/main/wms.json" 2>/dev/null)"
  check "S99 main/wms enabled true" "true" "$(jq -r '.wms.enabled // empty' "$GS_STATE_DIR/service/main/wms.json" 2>/dev/null)"
  check "S99 genau 1 Dienst-PUT" "1" "$(grep -c 'services/wms/workspaces/main/settings METHOD=PUT' "$CURL_BODY_LOG" || true)"
  check "S99 aktualisiert Meldung" "yes" "$(grep -q 'main/wms: Dienst-Metadaten aktualisiert' "$T/out.log" && echo yes || echo no)"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S99 Zweitlauf Exit 0" "0" "$rc"
  check "S99 Zweitlauf 0 Dienst-PUT" "0" "$(grep -c 'services/wms/workspaces/main/settings METHOD=PUT' "$CURL_BODY_LOG" || true)"
fi

# (100) Capabilities-Ausnahme (L4/L7)
if want 100; then
scenario "100"
  reset_state
  export GS_CAPS_EXCEPTION=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S100 Exit 1" "1" "$rc"
  check "S100 nennt ExceptionReport" "yes" "$(grep -q 'ExceptionReport' "$T/err.log" && echo yes || echo no)"
  unset GS_CAPS_EXCEPTION
fi

# (101) Layer-Abstract fehlt
if want 101; then
scenario "101"
  reset_state
  export GS_CAPS_NO_ABSTRACT=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S101 Exit 1" "1" "$rc"
  check "S101 nennt Abstract" "yes" "$(grep -q 'Abstract' "$T/err.log" && echo yes || echo no)"
  unset GS_CAPS_NO_ABSTRACT
fi

# (102) GeoJSON-Genauigkeit
if want 102; then
scenario "102"
  reset_state
  export GS_GEOJSON_PROP_DECIMALS=1
  export GS_IGNORE_SETTINGS=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S102 (a) Exit 1" "1" "$rc"
  unset GS_GEOJSON_PROP_DECIMALS GS_IGNORE_SETTINGS
  reset_state
  export GS_GEOJSON_EMPTY=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S102 (b) Exit 0" "0" "$rc"
  check "S102 (b) WARN keine Features" "yes" "$(grep -q 'keine Features' "$T/err.log" && echo yes || echo no)"
  unset GS_GEOJSON_EMPTY
fi

# (103) HEAD auf onlineResource: einmal, ohne Credentials, mit --max-time
if want 103; then
scenario "103"
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S103 Exit 0" "0" "$rc"
  check "S103 genau 1 HEAD" "1" "$(grep -c ' -I ' "$CURL_LOG" || true)"
  headline="$(paste -d '|' "$CURL_LOG" "$CURL_STDIN_LOG" 2>/dev/null | grep -- ' -I ' | head -1)"
  check "S103 HEAD ohne Credentials" "no" "$(printf '%s' "$headline" | grep -q 'user =' && echo yes || echo no)"
  check "S103 HEAD mit max-time" "yes" "$(printf '%s' "$headline" | grep -q -- '--max-time' && echo yes || echo no)"
fi

# (104) yq-Vorpruefung: mikefarah erforderlich
if want 104; then
scenario "104"
  reset_state
  export YQ_VERSION_OUT='yq 3.4.3'
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S104 (a) yq alt Exit 2" "2" "$rc"
  check "S104 (a) nennt mikefarah" "yes" "$(grep -q 'mikefarah' "$T/err.log" && echo yes || echo no)"
  unset YQ_VERSION_OUT
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S104 (b) yq Standard Exit 0" "0" "$rc"
fi

# (105) Migration: alte Import-Rollen-ACL-Regel -> Konflikt, bleibt unveraendert
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

# (106) Dry-run Uninstall zeigt den echten Plan, keine Mutation
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
  check "S106 Ist FeatureType 25" "25" "$(grep -c 'FeatureType geloescht' "$T/out.log" || true)"
  check "S106 Ist Datastore 5" "5" "$(grep -c 'Datastore geloescht' "$T/out.log" || true)"
  check "S106 Ist Workspace 6" "6" "$(grep -c 'Workspace geloescht' "$T/out.log" || true)"
  check "S106 Ist Zuordnung 6" "6" "$(grep -c 'Zuordnung .* geloest' "$T/out.log" || true)"
  check "S106 Ist Benutzer 6" "6" "$(grep -c 'Benutzer .* geloescht' "$T/out.log" || true)"
  check "S106 Ist Rolle 6" "6" "$(grep -c 'Rolle .* geloescht' "$T/out.log" || true)"
fi

# (107) XML-Escaping des Capabilities-Vergleichs (Abstract mit & und <)
if want 107; then
scenario "107"
  reset_state
  bundle_copy "$T/xml"
  sed -i 's|abstract: "Gräber je Friedhof.*|abstract: "Stufe A \& B <test>"|' "$T/xml/geoserver-metadata.md"
  rc="$(run_bundle "$T/xml" --url "$URL" --ns "$NS")"
  check "S107 Exit 0" "0" "$rc"
fi

# (108) Alle GeoServer-curl-Aufrufe mit --max-time
if want 108; then
scenario "108"
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S108 Exit 0" "0" "$rc"
  check "S108 alle mit max-time" "0" "$(grep -vc -- '--max-time' "$CURL_LOG" || true)"
fi

# (109) Preflight wartet auf GeoServer (2x 503, dann 200)
if want 109; then
scenario "109"
  reset_state
  export GS_NOT_READY_FIRST=2
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S109 Exit 0" "0" "$rc"
  check "S109 2 Wartemeldungen" "2" "$(grep -c 'noch nicht bereit' "$T/out.log" || true)"
  unset GS_NOT_READY_FIRST
fi

# (110) Preflight bricht nach einem Versuch ab (GS_WAIT_SECONDS=0)
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

# (111) Passwort-Hygiene: Secret-Werte nie in jq/kubectl/curl-Argumenten
if want 111; then
scenario "111"
  reset_state
  export JQ_LOG_ARGS=1
  run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
  leak=0
  for f in "$KUBE_STATE_DIR"/secrets/p2d2-geoserver-*.b64; do
    [ -f "$f" ] || continue
    b64="$(cat "$f")"
    klartext="$(base64 -d <<< "$b64" 2>/dev/null)"
    if grep -qF "$b64" "$JQ_LOG" "$KUBECTL_LOG" "$CURL_LOG" 2>/dev/null; then leak=1; fi
    if grep -qF "$klartext" "$JQ_LOG" "$KUBECTL_LOG" "$CURL_LOG" 2>/dev/null; then leak=1; fi
  done
  check "S111 keine Secret-Leaks" "0" "$leak"
  unset JQ_LOG_ARGS
fi

# (112) Abbruch mitten im Lauf raeumt Temp-Verzeichnis auf
if want 112; then
scenario "112"
  reset_state
  mkdir -p "$T/tmpdir"
  export TMPDIR="$T/tmpdir"
  export GS_ACL_POST_FAIL=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S112 Abbruch Exit 1" "1" "$rc"
  check "S112 keine Temp-Datei" "0" "$(find "$T/tmpdir" -mindepth 1 | awk 'END{print NR}')"
  unset GS_ACL_POST_FAIL TMPDIR
fi

gs_group_end

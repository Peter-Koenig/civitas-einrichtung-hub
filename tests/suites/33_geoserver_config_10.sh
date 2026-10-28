#!/usr/bin/env bash
# Suite 33 Gruppe 10 (automatisch zerlegt).
begin_suite "geoserver_config_10"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (38) A2: Credential-Escaping (Anführungszeichen + Backslash)
scenario "38"
reset_state
export GS_ADMIN_PW='ab"cd\ef'
rc="$(run_script --url "$URL" --ns "$NS")"
check "A2 escape Exit 0"           "0" "$rc"
check "A2 escape in stdin-Konfig"  "yes" "$(grep -Fq 'ab\"cd\\ef' "$CURL_STDIN_LOG" && echo yes || echo no)"
unset GS_ADMIN_PW

# (32) Workspaces: Uninstall löscht nur Soll, ohne recurse
scenario "32"
ensure_snap_installed
restore_state
seed_workspace "foreign_ws" "urn:data-dna:govdata:foreign"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS Uninstall Exit 0"          "0" "$rc"
check "WS Uninstall foreign bleibt"  "foreign_ws" "$(cat "$GS_STATE_DIR/workspaces.list")"
check "WS Uninstall ohne recurse"    "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"

# (58) D: fehlender Native-Name → Exit 1, kein POST für den betroffenen FeatureType
scenario "58"
reset_state
export GS_LIST_AVAILABLE_MISSING_NATIVE=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D fehlender Native Exit 1"     "1" "$rc"
check "D fehlender Native kein graeber" "0" "$(test -f "$GS_STATE_DIR/ft/main/main_pg/graeber.json" && echo 1 || echo 0)"
check "D fehlender Native 20 übrige"   "20" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
unset GS_LIST_AVAILABLE_MISSING_NATIVE

# (6) --dry-run: kein POST/PUT/DELETE und kein kubectl apply
scenario "6"
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "Dry-Run Exit 0"          "0" "$rc"
check "Dry-Run kein POST"       "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
check "Dry-Run kein DELETE"     "0" "$(grep -c '\-X DELETE' "$CURL_LOG" || true)"
check "Dry-Run kein kubectl apply" "0" "$(grep -c 'apply' "$KUBECTL_LOG" || true)"
check "Dry-Run keine Secrets angelegt" "0" "$(count_secrets)"

# (65) B3: Dry-run Install auf leerem System
scenario "65"
reset_state
clear_logs
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "B3 Dry-Run leer Install Exit 0"       "0" "$rc"
check "B3 Dry-Run leer Install keine FEHLER" "0" "$(grep -c 'FEHLER' "$T/err.log" || true)"
check "B3 Dry-Run leer würde angelegt"       "yes" "$(grep -q 'main/geo-containers würde angelegt' "$T/out.log" && echo yes || echo no)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# (95) Anlegen eines lokalen Dienstes scheitert (405/500) -> Abbruch, kein POST
if want 95; then
scenario "95"
  reset_state
  export GS_SERVICE_CREATE_FAIL=405
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S95 405 Exit 1" "1" "$rc"
  check "S95 405 kein POST" "0" "$(grep -c 'services/.*/workspaces/.*/settings METHOD=POST' "$CURL_BODY_LOG" || true)"
  check "S95 405 anlegen fehlgeschlagen" "yes" "$(grep -q 'anlegen fehlgeschlagen' "$T/err.log" && echo yes || echo no)"
  check "S95 405 Code genannt" "yes" "$(grep -q '405' "$T/err.log" && echo yes || echo no)"
  check "S95 405 kein Datastore" "0" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
  unset GS_SERVICE_CREATE_FAIL
  reset_state
  export GS_SERVICE_CREATE_FAIL=500
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S95 500 Exit 1" "1" "$rc"
  check "S95 500 kein POST" "0" "$(grep -c 'services/.*/workspaces/.*/settings METHOD=POST' "$CURL_BODY_LOG" || true)"
  check "S95 500 anlegen fehlgeschlagen" "yes" "$(grep -q 'anlegen fehlgeschlagen' "$T/err.log" && echo yes || echo no)"
  unset GS_SERVICE_CREATE_FAIL
fi

# (96) Snapshot: Attribution nur bei Abweichung (Zweitlauf keiner)
if want 96; then
scenario "96"
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S96 Exit 0" "0" "$rc"
  check "S96 kein Layer-PUT im Zweitlauf" "0" "$(grep -c '/layers/' "$CURL_BODY_LOG" || true)"
  check "S96 Attribution gesetzt" "© OpenStreetMap-Mitwirkende" "$(jq -r '.title // empty' "$GS_STATE_DIR/layers/main/geo-containers.attr.json" 2>/dev/null)"
fi

# (93) GS_IGNORE_SETTINGS=1: Exit 1, Koordinaten auf 4 Stellen gerundet
if want 93; then
scenario "93"
  ensure_snap_installed
  restore_state
  export GS_IGNORE_SETTINGS=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S93 Exit 1" "1" "$rc"
  check "S93 Meldung 4 Stellen" "yes" "$(grep -q 'auf 4 Stellen gerundet' "$T/err.log" && echo yes || echo no)"
  unset GS_IGNORE_SETTINGS
fi

gs_group_end

#!/usr/bin/env bash
# Suite 33 Gruppe 04 (automatisch zerlegt).
begin_suite "geoserver_config_04"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (4) Ungültiger Secret-Wert wird ersetzt
scenario "4"
reset_state
seed_secret "p2d2-geoserver-wfst-main" "$PASS_INVALID_B64"
rc="$(run_script --url "$URL" --ns "$NS")"
check "Invalid-Ersetzen Exit 0" "0" "$rc"
check "Invalid ersetzt (nicht a3Vyeg==)" "0" "$(grep -c '^a3Vyeg==$' "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64" 2>/dev/null || true)"
newlen="$(base64 -d < "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64" 2>/dev/null | awk '{print length}')"
check "Invalid neuer Wert >= 16 Zeichen" "0" "$( [ "$newlen" -ge 16 ] 2>/dev/null && echo 0 || echo 1 )"

# (55) D: FeatureTypes Erstlauf (25 Stück, Umlaut-Titel, Default-Styles)
scenario "55"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Erstlauf Exit 0"                "0" "$rc"
check "D Erstlauf 25 FeatureTypes"       "25" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "D graeber Titel Umlaut"           "Gräber (main)" "$(jq -r '.featureType.title' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" 2>/dev/null)"
check "D graeber Default-Style generic"  "generic" "$(cat "$GS_STATE_DIR/layers/main/graeber.style" 2>/dev/null)"
check "D geo-containers Style polygon"   "polygon" "$(cat "$GS_STATE_DIR/layers/main/geo-containers.style" 2>/dev/null)"
check "D Erstlauf kein Default-Style-PUT"  "0" "$(grep -c 'defaultStyle' "$CURL_BODY_LOG" || true)"
check "D Erstlauf 5 Attribution-PUTs"       "5" "$(grep -c 'attribution' "$CURL_BODY_LOG" || true)"

# (56) D: Zweitlauf ohne Abweichung → kein POST/PUT auf FeatureTypes/Layer
scenario "56"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Zweitlauf Exit 0"             "0" "$rc"
check "D Zweitlauf kein FeatureType POST" "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"
check "D Zweitlauf kein FeatureType PUT"  "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=PUT')"
check "D Zweitlauf kein Layer PUT"       "0" "$(grep 'layers/' "$CURL_BODY_LOG" | grep -c 'METHOD=PUT')"

# (54) R4: abweichender Datastore-Parameter nennt erwartet/vorhanden
scenario "54"
reset_state
export GS_DS_BAD_PARAM=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "R4 DS-Bad-Param Exit 1"       "1" "$rc"
check "R4 DS-Diagnose user"          "yes" "$(grep -q 'user(erwartet P2D2-MAIN, vorhanden WRONG)' "$T/err.log" && echo yes || echo no)"
unset GS_DS_BAD_PARAM

# (61) D: Uninstall Reihenfolge Layer → FeatureType → Datastore, ohne recurse
scenario "61"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "D Uninstall Exit 0"          "0" "$rc"
check "D Uninstall ohne recurse"    "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"
check "D Uninstall keine FeatureTypes" "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
layer_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'layers/' | head -1 | cut -d: -f1)"
ft_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'featuretypes/' | head -1 | cut -d: -f1)"
ds_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'datastores/[^/]*$' | head -1 | cut -d: -f1)"
check "D Uninstall Layer vor FeatureType" "yes" "$([ -n "$layer_line" ] && [ -n "$ft_line" ] && [ "$layer_line" -lt "$ft_line" ] && echo yes || echo no)"
check "D Uninstall FeatureType vor Datastore" "yes" "$([ -n "$ft_line" ] && [ -n "$ds_line" ] && [ "$ft_line" -lt "$ds_line" ] && echo yes || echo no)"

# (9) Unbekanntes Argument -> Exit 2; --url gewinnt über ADDON_DOMAIN
scenario "9"
reset_state
rc="$(run_script --bogus)"
check "Unbekanntes Argument Exit 2" "2" "$rc"

reset_state
export ADDON_DOMAIN="udp.wrong.example"
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "--url gewinnt Exit 0" "0" "$rc"
check "--url gewinnt (kein udp.wrong)" "0" "$(grep -c 'udp.wrong.example' "$T/out.log" || true)"
unset ADDON_DOMAIN

# (25) How-To Dry-Run: Modus geplant
scenario "25"
reset_state
run_script --dry-run --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "How-To Dry-Run geplant" "yes" "$(grep -q 'Modus: dry-run (geplant)' "$howto_file" && echo yes || echo no)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy



if want 109; then
scenario "109"
  reset_state
  export GS_NOT_READY_FIRST=2
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S109 Exit 0" "0" "$rc"
  check "S109 2 Wartemeldungen" "2" "$(grep -c 'noch nicht bereit' "$T/out.log" || true)"
  unset GS_NOT_READY_FIRST
fi

gs_group_end

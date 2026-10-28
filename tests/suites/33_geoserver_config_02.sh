#!/usr/bin/env bash
# Suite 33 Gruppe 02 (automatisch zerlegt).
begin_suite "geoserver_config_02"
source "$(dirname "${BASH_SOURCE[0]}")/../lib_geoserver.sh"
gs_init_group_env

scenarios_legacy() {
# (1) Erstlauf legt sechs Secrets + sechs Benutzer an
scenario "1"
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "Erstlauf Exit 0"          "0" "$rc"
check "Erstlauf 6 Secrets"       "6" "$(count_secrets)"
check "Erstlauf 7 Benutzer (admin + 6)" "7" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Erstlauf 7 Rollen (ADMIN + 6)"   "7" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Erstlauf 6 Secret-Applys" "6" "$(grep -c 'apply' "$KUBECTL_LOG")"

scenario "2"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "Zweitlauf Exit 0"            "0" "$rc"
check "Zweitlauf weiterhin 6 Secrets" "6" "$(count_secrets)"
check "Zweitlauf weiterhin 7 Benutzer" "7" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Zweitlauf weiterhin 7 Rollen"   "7" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Zweitlauf kein Secret-Apply" "0" "$(grep -c 'apply' "$KUBECTL_LOG")"

# (62) D: WFS-Antwort mit ExceptionReport → Verifikationsfehler Exit 1
scenario "62"
reset_state
export GS_WFS_EXCEPTION=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D WFS-Exception Exit 1"        "1" "$rc"
check "D WFS-Exception Meldung"       "yes" "$(grep -q 'DescribeFeatureType' "$T/err.log" && echo yes || echo no)"
unset GS_WFS_EXCEPTION

# (74) A: Zweitlauf ohne Mapping-PUT
scenario "74"
ensure_snap_installed
restore_state
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping Zweitlauf Exit 0"   "0" "$rc"
check "A Mapping Zweitlauf kein PUT" "0" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# (42) R2: Antworttext erscheint gekürzt in der Fehlermeldung
scenario "42"
ensure_snap_installed
restore_state
LONG="$(head -c 240 /dev/zero | tr '\0' 'A')TAIL"
export GS_WS_NONEMPTY=1
export GS_403_BODY="$LONG"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "R2 Exit 1"                          "1" "$rc"
check "R2 Antworttext gekürzt (kein TAIL)" "0" "$(grep -c 'TAIL' "$T/err.log" || true)"
check "R2 Antworttext vorhanden (A…)"      "yes" "$(grep -q 'AAAAAA' "$T/err.log" && echo yes || echo no)"
unset GS_WS_NONEMPTY GS_403_BODY

# (52) R3: zwei Läufe unterschiedlichen Modus → zwei How-To-Dateien (Modus im Namen)
scenario "52"
reset_state
rm -f "$WORK"/p2d2-geoserver-config_v1_*.howto.md
run_script --dry-run --url "$URL" --ns "$NS" >/dev/null 2>&1
run_script --dry-run --uninstall --url "$URL" --ns "$NS" >/dev/null 2>&1
check "R3 zwei How-To-Dateien" "2" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_*.howto.md' -type f 2>/dev/null | awk 'END{print NR}')"
check "R3 install-dry-run im Namen" "yes" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_install-dry-run_*.howto.md' -type f 2>/dev/null | grep -q . && echo yes || echo no)"
check "R3 uninstall-dry-run im Namen" "yes" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_uninstall-dry-run_*.howto.md' -type f 2>/dev/null | grep -q . && echo yes || echo no)"

# (15) .env.p2d2-addon zwei Ebenen höher wird gefunden (K4)
scenario "15"
reset_state
ENV_TREE="$T/envtree/p2d2-addon/supplement"
mkdir -p "$ENV_TREE"
printf 'ADDON_DOMAIN=udp.envtest.example\n' > "$T/envtree/.env.p2d2-addon"
rc="$(run_script_in "$ENV_TREE" --dry-run --ns "$NS")"
check "K4 env 2 Ebenen Exit 0" "0" "$rc"
check "K4 env Domain gefunden" "yes" "$(grep -q 'udp.envtest.example' "$T/out.log" && echo yes || echo no)"

}

[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

gs_group_end

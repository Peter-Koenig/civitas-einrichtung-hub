#!/usr/bin/env bash
# Suite 44: addon_25_iam.sh — Keycloak-Metadaten-Provisionierung (Profil, Mapper, Jule).
# Offline: curl-/kubectl-Stubs simulieren die Keycloak-Admin-API.

begin_suite "addon_iam_metadata"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

export ADDON_DOMAIN="example.org"
export IAM_STATE_DIR="$T/state"; mkdir -p "$IAM_STATE_DIR"
export IAM_REQ_LOG="$T/req.log"; : > "$IAM_REQ_LOG"

# shellcheck source=../../modules_addon_V1s/addon_25_iam.sh
source "$REPO/modules_addon_V1s/addon_25_iam.sh"

# ── Stubs ─────────────────────────────────────────────────────────────────────
cat > "$STUBS/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
  *"jsonpath={.data.MASTER_USERNAME}"*) printf 'YWRtaW4=' ;;  # base64 "admin"
  *"jsonpath={.data.MASTER_PASSWORD}"*) printf 'cGFzcw==' ;;  # base64 "pass"
  *) exit 0 ;;
esac
KUBECTL
chmod +x "$STUBS/kubectl"

cat > "$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
url=""; method="GET"; body=""; has_w=0; prev=""
for a in "$@"; do
  case "$a" in
    https://*) url="$a" ;;
    -X) prev="X" ;;
    -d) prev="D" ;;
    -w) has_w=1 ;;
    *)  [ "$prev" = "X" ] && { method="$a"; prev=""; }
        [ "$prev" = "D" ] && { body="$a"; prev=""; } ;;
  esac
done
ST="${IAM_STATE_DIR:?}"; REQ="${IAM_REQ_LOG:?}"
echo "${method} ${url}" >> "$REQ"
code=200; out=""
case "$url" in
  *"/protocol/openid-connect/token") out='{"access_token":"STUB_TOKEN"}' ;;
  *"/clients") out='[{"id":"client-1","clientId":"p2d2"}]' ;;
  *"/users/profile")
    if [ "$method" = "GET" ]; then out=$(cat "$ST/profile.json"); else printf '%s' "$body" > "$ST/profile.json"; code=204; fi ;;
  *"/protocol-mappers/models"*)
    case "$method" in
      GET) out=$(cat "$ST/mappers.json") ;;
      POST)
        n=$(cat "$ST/mapper_count" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$ST/mapper_count"
        out=$(printf '%s' "$body" | jq -c --arg id "mapper-$n" '. + {id:$id}')
        cat "$ST/mappers.json" | jq -c --argjson m "$out" '. + [$m]' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"
        code=201 ;;
      PUT)
        id="${url##*/}"
        cat "$ST/mappers.json" | jq -c --arg id "$id" --argjson m "$body" 'map(if .id==$id then $m else . end)' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"
        code=204 ;;
    esac ;;
  *"/users?email="*) out=$(cat "$ST/users.json") ;;
  *"/users/jule-1")
    if [ "$method" = "GET" ]; then out=$(cat "$ST/user_jule.json"); else printf '%s' "$body" > "$ST/user_jule.json"; code=204; fi ;;
esac
if [ "$has_w" = "1" ]; then printf '%s\n%s' "$out" "$code"; else printf '%s' "$out"; fi
CURL
chmod +x "$STUBS/curl"

# ── Fixture-/Reset-Helfer ─────────────────────────────────────────────────────
reset_state() {
  rm -rf "$IAM_STATE_DIR"; mkdir -p "$IAM_STATE_DIR"
  printf '%s' '{"attributes":[],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
  printf '%s' '[]' > "$IAM_STATE_DIR/mappers.json"
  printf '%s' '0' > "$IAM_STATE_DIR/mapper_count"
  printf '%s' '[{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","enabled":true,"firstName":"Jule","lastName":"Kovalenko"}]' > "$IAM_STATE_DIR/users.json"
  printf '%s' '{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","enabled":true,"firstName":"Jule","lastName":"Kovalenko","attributes":{}}' > "$IAM_STATE_DIR/user_jule.json"
  : > "$IAM_REQ_LOG"
  : > "$LOGBUF"
}

# ── T1: frischer Zustand -> Profil + 2 Mapper + Jule-Werte ────────────────────
reset_state
ensure_metadata_profile  >/dev/null 2>&1; rc1=$?
ensure_metadata_mappers  >/dev/null 2>&1; rc2=$?
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc3=$?
check "T1 profile rc=0" "0" "$rc1"
check "T1 mapper rc=0" "0" "$rc2"
check "T1 seed rc=0" "0" "$rc3"
check "T1 zwei Profil-Definitionen" "2" "$(jq '.attributes | length' "$IAM_STATE_DIR/profile.json")"
check "T1 zwei Mapper" "2" "$(jq 'length' "$IAM_STATE_DIR/mappers.json")"
check "T1 Jule memberships vorhanden" "yes" "$(jq -e '.attributes["p2d2.memberships"]' "$IAM_STATE_DIR/user_jule.json" >/dev/null 2>&1 && echo yes || echo no)"
check "T1 Jule home_region vorhanden" "yes" "$(jq -e '.attributes["p2d2.preferences.home_region_key"]' "$IAM_STATE_DIR/user_jule.json" >/dev/null 2>&1 && echo yes || echo no)"

# ── T2: zweiter Lauf -> keine neuen POST/PUT ──────────────────────────────────
before=$(grep -cE ' (POST|PUT) ' "$IAM_REQ_LOG" || true)
ensure_metadata_profile >/dev/null 2>&1
ensure_metadata_mappers >/dev/null 2>&1
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
after=$(grep -cE ' (POST|PUT) ' "$IAM_REQ_LOG" || true)
check "T2 keine neuen POST/PUT" "$before" "$after"

# ── T3/T4: fremde Profil-/User-Werte bleiben erhalten ─────────────────────────
reset_state
printf '%s' '{"attributes":[{"name":"fremd.attr","displayName":"fremd","permissions":{"view":["admin"],"edit":["admin"]}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
printf '%s' '{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","attributes":{"p2d2.preferences.home_region_key":["de-Berlin"],"fremd.attr":["x"]}}' > "$IAM_STATE_DIR/user_jule.json"
ensure_metadata_profile >/dev/null 2>&1
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
check "T3 fremde Profil-Definition erhalten" "yes" "$(jq -e '.attributes[] | select(.name=="fremd.attr")' "$IAM_STATE_DIR/profile.json" >/dev/null 2>&1 && echo yes || echo no)"
check "T4 persoenliche Region erhalten" "de-Berlin" "$(jq -r '.attributes["p2d2.preferences.home_region_key"][0]' "$IAM_STATE_DIR/user_jule.json")"

# ── T5: UTF-8, genau ein JSON-String, dekodiert zu zwei Objekten ──────────────
reset_state
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
memberships=$(jq -r '.attributes["p2d2.memberships"] | type' "$IAM_STATE_DIR/user_jule.json")
check "T5 memberships ist Array" "array" "$memberships"
check "T5 genau ein Element" "1" "$(jq '.attributes["p2d2.memberships"] | length' "$IAM_STATE_DIR/user_jule.json")"
decoded=$(jq -r '.attributes["p2d2.memberships"][0] | fromjson | length' "$IAM_STATE_DIR/user_jule.json")
check "T5 dekodiert zu zwei Objekten" "2" "$decoded"
check "T5 UTF-8 de-Köln" "de-Köln" "$(jq -r '.attributes["p2d2.memberships"][0] | fromjson | .[0].wp_name' "$IAM_STATE_DIR/user_jule.json")"

# ── T6: Mapper-Drift (id.token.claim) korrigieren ──────────────────────────────
reset_state
printf '%s' '[{"id":"mapper-9","name":"p2d2 memberships","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"id.token.claim":"false","user.attribute":"p2d2.memberships","claim.name":"user_metadata.p2d2.memberships"}}]' > "$IAM_STATE_DIR/mappers.json"
printf '%s' '9' > "$IAM_STATE_DIR/mapper_count"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T6 Drift korrigiert rc=0" "0" "$rc"
check "T6 id.token.claim true" "true" "$(jq -r '.[0].config["id.token.claim"]' "$IAM_STATE_DIR/mappers.json")"

# ── T6b: Duplikat-Name -> Fehler ───────────────────────────────────────────────
reset_state
printf '%s' '[{"id":"a","name":"p2d2 memberships","protocolMapper":"oidc-usermodel-attribute-mapper"},{"id":"b","name":"p2d2 memberships","protocolMapper":"oidc-usermodel-attribute-mapper"}]' > "$IAM_STATE_DIR/mappers.json"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T6b Duplikat -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T7: unsichere Membership-Editrechte -> Fehler ──────────────────────────────
reset_state
printf '%s' '{"attributes":[{"name":"p2d2.memberships","permissions":{"view":["admin"],"edit":["admin","user"]}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
ensure_metadata_profile >/dev/null 2>&1; rc=$?
check "T7 unsafe memberships edit -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T8: fehlender Jule (0 Treffer) -> Fehler ──────────────────────────────────
reset_state
printf '%s' '[]' > "$IAM_STATE_DIR/users.json"
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T8 Jule fehlt -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T9: kein Token/Passwort in der Konsole ────────────────────────────────────
reset_state
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
check "T9 kein Token im Log" "no" "$(grep -q 'STUB_TOKEN' "$LOGBUF" && echo yes || echo no)"
check "T9 kein Passwort im Log" "no" "$(grep -q 'pass' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

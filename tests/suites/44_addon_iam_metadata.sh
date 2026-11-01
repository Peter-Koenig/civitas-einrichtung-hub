#!/usr/bin/env bash
# Suite 44: addon_25_iam.sh — Keycloak-Metadaten-Provisionierung (Profil, Mapper, Jule).
# Offline: curl-/kubectl-Stubs simulieren die Keycloak-Admin-API (inkl. Fault-Injection).

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

# Wrapper: seed_user_metadata mit Jule-Fixture (Suite prüft den generischen Seed-Pfad).
JULE_ACCOUNT='{"email":"jule.kovalenko@nospam.scanea.de","memberships":[{"type":"kommune","key":"koeln","role":"verwaltung","wp_name":"de-Köln"},{"type":"community","key":"osm","role":"osm"}],"home_region_key":"de-Bonn"}'
seed_jule_metadata() { seed_user_metadata "$1" "$JULE_ACCOUNT"; }

# ── Stubs ─────────────────────────────────────────────────────────────────────
cat > "$STUBS/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
  *"jsonpath={.data.MASTER_USERNAME}"*) printf 'YWRtaW4=' ;;       # base64 "admin"
  *"jsonpath={.data.MASTER_PASSWORD}"*) printf 'U1RVQi1QVy03ZjNh' ;; # base64 "STUB-PW-7f3a"
  *) exit 0 ;;
esac
KUBECTL
chmod +x "$STUBS/kubectl"

cat > "$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
url=""; method="GET"; body=""; has_w=0; has_o=0; prev=""
for a in "$@"; do
  case "$a" in
    https://*) url="$a" ;;
    -X) prev="X" ;;
    -d) prev="D" ;;
    -w) has_w=1 ;;
    -o) has_o=1 ;;
    *)  [ "$prev" = "X" ] && { method="$a"; prev=""; }
        [ "$prev" = "D" ] && { body="$a"; prev=""; } ;;
  esac
done
ST="${IAM_STATE_DIR:?}"; REQ="${IAM_REQ_LOG:?}"
echo "${method} ${url}" >> "$REQ"
code=200; out=""

# Fault-Injection (Methode, URL-Glob, Code, Body)
fault_hit=0
if [ -f "$ST/faults.tsv" ]; then
  while IFS="$(printf '\t')" read -r fm fu fc fb; do
    [ -n "$fm" ] || continue
    [ "$fm" = "$method" ] || continue
    case "$url" in $fu) code="$fc"; out="$fb"; fault_hit=1; break ;; esac
  done < "$ST/faults.tsv"
fi

# STUB_NOOP_PUT: PUT antwortet 204, persistiert aber nicht (Read-back-Tests).
if [ "$fault_hit" = "0" ] && [ "${STUB_NOOP_PUT:-0}" = "1" ] && [ "$method" = "PUT" ]; then
  code=204; out=""; fault_hit=1
fi

if [ "$fault_hit" = "0" ]; then
  case "$url" in
    *"/protocol/openid-connect/token")
      out='{"access_token":"STUB_TOKEN"}' ;;

    *"/clients")
      out=$(cat "$ST/clients.json") ;;

    *"/clients/"*"/roles/"*)
      role="${url##*/}"
      out=$(jq -cn --arg r "$role" --arg id "role-$role" '{id:$id,name:$r}') ;;

    *"/users/profile")
      if [ "$method" = "GET" ]; then
        out=$(cat "$ST/profile.json")
      else
        printf '%s' "$body" > "$ST/profile.json"; code=204
      fi ;;

    *"/protocol-mappers/models"*)
      case "$method" in
        GET) out=$(cat "$ST/mappers.json") ;;
        POST)
          n=$(cat "$ST/mapper_count"); n=$((n+1)); printf '%s' "$n" > "$ST/mapper_count"
          out=$(printf '%s' "$body" | jq -c --arg id "mapper-$n" '. + {id:$id}')
          cat "$ST/mappers.json" | jq -c --argjson m "$out" '. + [$m]' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"
          code=201 ;;
        PUT)
          id="${url##*/}"
          cat "$ST/mappers.json" | jq -c --arg id "$id" --argjson m "$body" 'map(if .id==$id then $m else . end)' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"
          code=204 ;;
      esac ;;

    *"/users?email="*)
      q="${url#*email=}"; q="${q%%&*}"
      email=$(printf '%s' "$q" | sed 's/%40/@/g')
      out=$(jq -c --arg e "$email" '[.[] | select(.email == $e)]' "$ST/users.json") ;;

    *"/users/"*"/reset-password")
      out=""; code=204 ;;

    *"/users/"*"/role-mappings/clients/"*)
      out=""; code=204 ;;

    *"/users")
      n=$(cat "$ST/user_count"); n=$((n+1)); printf '%s' "$n" > "$ST/user_count"
      newuser=$(printf '%s' "$body" | jq -c --arg id "user-$n" '. + {id:$id}')
      cat "$ST/users.json" | jq -c --argjson u "$newuser" '. + [$u]' > "$ST/users.json.new"; mv "$ST/users.json.new" "$ST/users.json"
      code=201 ;;

    *"/users/"*)
      id="${url##*/}"
      if [ "$method" = "GET" ]; then
        out=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$ST/users.json")
      else
        cat "$ST/users.json" | jq -c --arg id "$id" --argjson m "$body" 'map(if .id==$id then $m else . end)' > "$ST/users.json.new"; mv "$ST/users.json.new" "$ST/users.json"
        code=204
      fi ;;
  esac
fi

if [ "$has_w" = "1" ] && [ "$has_o" = "1" ]; then
  printf '%s' "$code"
elif [ "$has_w" = "1" ]; then
  printf '%s\n%s' "$out" "$code"
else
  printf '%s' "$out"
fi
CURL
chmod +x "$STUBS/curl"

# ── Fixture-/Reset-Helfer ─────────────────────────────────────────────────────
reset_state() {
  rm -rf "$IAM_STATE_DIR"; mkdir -p "$IAM_STATE_DIR"
  printf '%s' '{"attributes":[],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
  printf '%s' '[]' > "$IAM_STATE_DIR/mappers.json"
  printf '%s' '0' > "$IAM_STATE_DIR/mapper_count"
  printf '%s' '[{"id":"client-1","clientId":"p2d2"}]' > "$IAM_STATE_DIR/clients.json"
  printf '%s' '[{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","enabled":true,"firstName":"Jule","lastName":"Kovalenko","attributes":{}}]' > "$IAM_STATE_DIR/users.json"
  printf '%s' '1' > "$IAM_STATE_DIR/user_count"
  : > "$IAM_STATE_DIR/faults.tsv"
  export STUB_NOOP_PUT=0
  : > "$IAM_REQ_LOG"
  : > "$LOGBUF"
}

inject_fault() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$IAM_STATE_DIR/faults.tsv"; }

count_writes() { grep -E '^(POST|PUT) ' "$IAM_REQ_LOG" | grep -v '/protocol/openid-connect/token' | wc -l | tr -d '[:space:]'; }

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
check "T1 Jule memberships vorhanden" "yes" "$(jq -e '.[0].attributes["p2d2.memberships"]' "$IAM_STATE_DIR/users.json" >/dev/null 2>&1 && echo yes || echo no)"
check "T1 Jule home_region vorhanden" "yes" "$(jq -e '.[0].attributes["p2d2.preferences.home_region_key"]' "$IAM_STATE_DIR/users.json" >/dev/null 2>&1 && echo yes || echo no)"

# ── T2: zweiter Lauf -> keine neuen Schreiboperationen (Positivkontrolle) ─────
w1=$(count_writes)
ensure_metadata_profile >/dev/null 2>&1
ensure_metadata_mappers >/dev/null 2>&1
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
w2=$(count_writes)
check "T2 Positivkontrolle: Lauf 1 schreibt" "yes" "$([ "$w1" -gt 0 ] && echo yes || echo no)"
check "T2 keine zusätzlichen Schreiboperationen" "$w1" "$w2"

# ── T3/T4: fremde Profil-/User-Werte bleiben erhalten ─────────────────────────
reset_state
printf '%s' '{"attributes":[{"name":"fremd.attr","displayName":"fremd","permissions":{"view":["admin"],"edit":["admin"]}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
printf '%s' '[{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","enabled":true,"firstName":"Jule","lastName":"Kovalenko","attributes":{"p2d2.preferences.home_region_key":["de-Berlin"],"fremd.attr":["x"]}}]' > "$IAM_STATE_DIR/users.json"
ensure_metadata_profile >/dev/null 2>&1
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
check "T3 fremde Profil-Definition erhalten" "yes" "$(jq -e '.attributes[] | select(.name=="fremd.attr")' "$IAM_STATE_DIR/profile.json" >/dev/null 2>&1 && echo yes || echo no)"
check "T4 persoenliche Region erhalten" "de-Berlin" "$(jq -r '.[0].attributes["p2d2.preferences.home_region_key"][0]' "$IAM_STATE_DIR/users.json")"

# ── T5: UTF-8, genau ein JSON-String, dekodiert zu zwei Objekten ──────────────
reset_state
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
check "T5 memberships ist Array" "array" "$(jq -r '.[0].attributes["p2d2.memberships"] | type' "$IAM_STATE_DIR/users.json")"
check "T5 genau ein Element" "1" "$(jq '.[0].attributes["p2d2.memberships"] | length' "$IAM_STATE_DIR/users.json")"
check "T5 dekodiert zu zwei Objekten" "2" "$(jq -r '.[0].attributes["p2d2.memberships"][0] | fromjson | length' "$IAM_STATE_DIR/users.json")"
check "T5 UTF-8 de-Köln" "de-Köln" "$(jq -r '.[0].attributes["p2d2.memberships"][0] | fromjson | .[0].wp_name' "$IAM_STATE_DIR/users.json")"

# ── T6: Mapper-Drift (id.token.claim) korrigieren ──────────────────────────────
reset_state
printf '%s' '[{"id":"mapper-9","name":"p2d2 memberships","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","consentRequired":false,"config":{"id.token.claim":"false","user.attribute":"p2d2.memberships","claim.name":"user_metadata.p2d2.memberships","jsonType.label":"String","multivalued":"false","aggregate.attrs":"false","access.token.claim":"false","userinfo.token.claim":"false"}}]' > "$IAM_STATE_DIR/mappers.json"
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

# ── T9: kein Token/Passwort in Konsole und Log ────────────────────────────────
reset_state
ensure_metadata_profile  >>"$T/out.txt" 2>&1
ensure_metadata_mappers  >>"$T/out.txt" 2>&1
seed_jule_metadata "$( _iam_get_token )" >>"$T/out.txt" 2>&1
check "T9 kein Token/Passwort (out)" "no" "$(grep -qE 'STUB_TOKEN|Bearer|STUB-PW-7f3a' "$T/out.txt" && echo yes || echo no)"
check "T9 kein Token/Passwort (log)" "no" "$(grep -qE 'STUB_TOKEN|Bearer|STUB-PW-7f3a' "$LOGBUF" && echo yes || echo no)"

# ── T10: GET Profile 401/403/500 -> Fehler, kein PUT ─────────────────────────
for c in 401 403 500; do
  reset_state
  inject_fault GET '*/users/profile' "$c" '{}'
  ensure_metadata_profile >/dev/null 2>&1; rc=$?
  check "T10 GET profile $c -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
  check "T10 GET profile $c kein PUT" "no" "$(grep -q '^PUT ' "$IAM_REQ_LOG" && echo yes || echo no)"
done

# ── T11: GET Profile 200 mit kaputter Form -> Fehler, kein PUT ────────────────
for bad in '[]' '{}' '<html>'; do
  reset_state
  inject_fault GET '*/users/profile' 200 "$bad"
  ensure_metadata_profile >/dev/null 2>&1; rc=$?
  check "T11 GET profile $bad -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
  check "T11 GET profile $bad kein PUT" "no" "$(grep -q '^PUT ' "$IAM_REQ_LOG" && echo yes || echo no)"
done

# ── T12: vorhandenes memberships mit multivalued=true -> Fehler ───────────────
reset_state
printf '%s' '{"attributes":[{"name":"p2d2.memberships","permissions":{"view":["admin"],"edit":["admin"]},"multivalued":true,"validations":{"length":{"max":4096}}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
ensure_metadata_profile >/dev/null 2>&1; rc=$?
check "T12 multivalued=true -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T13: vorhandenes memberships mit view=["admin","user"] -> Fehler ──────────
reset_state
printf '%s' '{"attributes":[{"name":"p2d2.memberships","permissions":{"view":["admin","user"],"edit":["admin"]},"multivalued":false,"validations":{"length":{"max":4096}}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
ensure_metadata_profile >/dev/null 2>&1; rc=$?
check "T13 view mit user -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T14: home_region_key mit edit=["admin"] (ohne user) -> Fehler ─────────────
reset_state
printf '%s' '{"attributes":[{"name":"p2d2.preferences.home_region_key","permissions":{"view":["admin","user"],"edit":["admin"]},"multivalued":false,"validations":{"length":{"max":200}}}],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
ensure_metadata_profile >/dev/null 2>&1; rc=$?
check "T14 home edit ohne user -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T14 Meldung nennt Feld" "yes" "$(grep -q 'home_region_key' "$LOGBUF" && echo yes || echo no)"

# ── T15: Profil-PUT mit STUB_NOOP_PUT -> Read-back schlaegt fehl ──────────────
reset_state
export STUB_NOOP_PUT=1
ensure_metadata_profile >/dev/null 2>&1; rc=$?
check "T15 noop-PUT -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T15 kein sichergestellt" "no" "$(grep -q 'sichergestellt' "$LOGBUF" && echo yes || echo no)"

# ── T16: GET Mapper 500 -> Fehler, kein POST ──────────────────────────────────
reset_state
inject_fault GET '*/protocol-mappers/models' 500 '{}'
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T16 GET mapper 500 -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T16 kein POST mapper" "no" "$(grep -q '^POST ' "$IAM_REQ_LOG" && echo yes || echo no)"

# ── T17: Mapper-Drift (mehrere Felder) + Fremdschluessel -> PUT korrigiert ────
reset_state
printf '%s' '[{"id":"mapper-7","name":"p2d2 memberships","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","consentRequired":true,"config":{"jsonType.label":"int","multivalued":"true","aggregate.attrs":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"false","user.attribute":"p2d2.memberships","claim.name":"user_metadata.p2d2.memberships","foreign.key":"keepme","introspection.token.claim":"false"}}]' > "$IAM_STATE_DIR/mappers.json"
printf '%s' '7' > "$IAM_STATE_DIR/mapper_count"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T17 Drift korrigiert rc=0" "0" "$rc"
check "T17 consentRequired false" "false" "$(jq -r '.[0].consentRequired' "$IAM_STATE_DIR/mappers.json")"
check "T17 jsonType String" "String" "$(jq -r '.[0].config["jsonType.label"]' "$IAM_STATE_DIR/mappers.json")"
check "T17 multivalued false" "false" "$(jq -r '.[0].config.multivalued' "$IAM_STATE_DIR/mappers.json")"
check "T17 access.token.claim false" "false" "$(jq -r '.[0].config["access.token.claim"]' "$IAM_STATE_DIR/mappers.json")"
check "T17 Fremdschluessel erhalten" "keepme" "$(jq -r '.[0].config["foreign.key"]' "$IAM_STATE_DIR/mappers.json")"
check "T17 introspection erhalten" "false" "$(jq -r '.[0].config["introspection.token.claim"]' "$IAM_STATE_DIR/mappers.json")"

# ── T18: Mapper mit fremdem Typ -> Fehler, kein PUT ────────────────────────────
reset_state
printf '%s' '[{"id":"mapper-8","name":"p2d2 memberships","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"user_metadata.p2d2.memberships"}}]' > "$IAM_STATE_DIR/mappers.json"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T18 fremder Typ -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T18 kein PUT" "no" "$(grep -q '^PUT ' "$IAM_REQ_LOG" && echo yes || echo no)"

# ── T19: Client-Lookup 0 und 2 Treffer -> Fehler ──────────────────────────────
reset_state
printf '%s' '[]' > "$IAM_STATE_DIR/clients.json"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T19 Client 0 Treffer -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
reset_state
printf '%s' '[{"id":"client-1","clientId":"p2d2"},{"id":"client-2","clientId":"p2d2"}]' > "$IAM_STATE_DIR/clients.json"
ensure_metadata_mappers >/dev/null 2>&1; rc=$?
check "T19 Client 2 Treffer -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T20: User-Lookup 0/2 Treffer, Objekt statt Array -> Fehler ────────────────
reset_state
printf '%s' '[]' > "$IAM_STATE_DIR/users.json"
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T20 User 0 Treffer -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
reset_state
printf '%s' '[{"id":"a","email":"jule.kovalenko@nospam.scanea.de"},{"id":"b","email":"jule.kovalenko@nospam.scanea.de"}]' > "$IAM_STATE_DIR/users.json"
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T20 User 2 Treffer -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
reset_state
inject_fault GET '*/users?email=*' 200 '{"id":"obj"}'
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T20 User Objekt statt Array -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T21: GET User liefert abweichende id/E-Mail -> Fehler, kein PUT ───────────
reset_state
printf '%s' '[{"id":"jule-1","username":"jule","email":"anderer@example.org","enabled":true,"firstName":"Jule","lastName":"Kovalenko","attributes":{}}]' > "$IAM_STATE_DIR/users.json"
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T21 abweichende E-Mail -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T21 kein PUT" "no" "$(grep -q '^PUT ' "$IAM_REQ_LOG" && echo yes || echo no)"

# ── T22: Seed bei vorhandenen/abweichenden/ungueltigen memberships ────────────
for val in '"different"' '[]' '[""]' '["a","b"]'; do
  reset_state
  printf '%s' "[{\"id\":\"jule-1\",\"username\":\"jule\",\"email\":\"jule.kovalenko@nospam.scanea.de\",\"attributes\":{\"p2d2.memberships\":$val,\"p2d2.preferences.home_region_key\":[\"de-Bonn\"]}}]" > "$IAM_STATE_DIR/users.json"
  seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
  check "T22 memberships $val rc=0" "0" "$rc"
  check "T22 memberships $val unverändert" "$val" "$(jq -c '.[0].attributes["p2d2.memberships"]' "$IAM_STATE_DIR/users.json")"
  check "T22 memberships $val log_warn" "yes" "$(grep -q 'p2d2.memberships' "$LOGBUF" && echo yes || echo no)"
done

# ── T23: Seed mit STUB_NOOP_PUT -> Read-back schlaegt fehl ────────────────────
reset_state
export STUB_NOOP_PUT=1
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1; rc=$?
check "T23 noop-PUT Seed -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

# ── T24: Seed erhaelt Fremdattribute von Jule ──────────────────────────────────
reset_state
printf '%s' '[{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","attributes":{"fremd.attr":["x"]}}]' > "$IAM_STATE_DIR/users.json"
seed_jule_metadata "$( _iam_get_token )" >/dev/null 2>&1
check "T24 Fremdattribute erhalten" "x" "$(jq -r '.[0].attributes["fremd.attr"][0]' "$IAM_STATE_DIR/users.json")"

rm -rf "$T"
# ── T26: install_addon_iam mit Profil-Fault -> kein Gesamterfolg ──────────────
reset_state
ensure_p2d2_oidc_client() { return 0; }
ensure_p2d2_client_roles() { return 0; }
ensure_p2d2_role_token_mapper() { return 0; }
inject_fault GET '*/users/profile' 500 '{}'
install_addon_iam >/dev/null 2>&1; rc=$?
check "T26 Profil-Fault rc!=0" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "T26 kein Gesamterfolg" "no" "$(grep -q 'AddOn 25 IAM abgeschlossen' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

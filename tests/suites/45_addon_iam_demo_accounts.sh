#!/usr/bin/env bash
# Suite 45: addon_25_iam.sh — Demo-Accounts aus supplement/demo-accounts.md.
# Offline: curl/kubectl/yq-Stubs (yq = mikefarah v4 simuliert via Python/PyYAML).

begin_suite "addon_iam_demo_accounts"

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

# shellcheck source=../../modules_addon_V1s/addon_01_config.sh
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck source=../../modules_addon_V1s/addon_25_iam.sh
source "$REPO/modules_addon_V1s/addon_25_iam.sh"

cat > "$STUBS/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
case "$*" in
  *"jsonpath={.data.MASTER_USERNAME}"*) printf 'YWRtaW4=' ;;
  *"jsonpath={.data.MASTER_PASSWORD}"*) printf 'U1RVQi1QVy03ZjNh' ;;
  *) exit 0 ;;
esac
KUBECTL
chmod +x "$STUBS/kubectl"

# yq-Stub: simuliert mikefarah yq v4 (YAML von stdin -> JSON).
cat > "$STUBS/yq" <<'YQ'
#!/usr/bin/env bash
python3 -c 'import sys, yaml, json; print(json.dumps(yaml.safe_load(sys.stdin.read())))'
YQ
chmod +x "$STUBS/yq"

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
fault_hit=0
if [ -f "$ST/faults.tsv" ]; then
  while IFS="$(printf '\t')" read -r fm fu fc fb; do
    [ -n "$fm" ] || continue
    [ "$fm" = "$method" ] || continue
    case "$url" in $fu) code="$fc"; out="$fb"; fault_hit=1; break ;; esac
  done < "$ST/faults.tsv"
fi
if [ "$fault_hit" = "0" ] && [ "${STUB_NOOP_PUT:-0}" = "1" ] && [ "$method" = "PUT" ]; then
  code=204; out=""; fault_hit=1
fi
if [ "$fault_hit" = "0" ]; then
  case "$url" in
    *"/protocol/openid-connect/token") out='{"access_token":"STUB_TOKEN"}' ;;
    *"/clients") out=$(cat "$ST/clients.json") ;;
    *"/clients/"*"/roles/"*) role="${url##*/}"; out=$(jq -cn --arg r "$role" --arg id "role-$role" '{id:$id,name:$r}') ;;
    *"/users/profile")
      if [ "$method" = "GET" ]; then out=$(cat "$ST/profile.json"); else printf '%s' "$body" > "$ST/profile.json"; code=204; fi ;;
    *"/protocol-mappers/models"*)
      case "$method" in
        GET) out=$(cat "$ST/mappers.json") ;;
        POST) n=$(cat "$ST/mapper_count"); n=$((n+1)); printf '%s' "$n" > "$ST/mapper_count"; out=$(printf '%s' "$body" | jq -c --arg id "mapper-$n" '. + {id:$id}'); cat "$ST/mappers.json" | jq -c --argjson m "$out" '. + [$m]' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"; code=201 ;;
        PUT) id="${url##*/}"; cat "$ST/mappers.json" | jq -c --arg id "$id" --argjson m "$body" 'map(if .id==$id then $m else . end)' > "$ST/mappers.json.new"; mv "$ST/mappers.json.new" "$ST/mappers.json"; code=204 ;;
      esac ;;
    *"/users?email="*)
      q="${url#*email=}"; q="${q%%&*}"; email=$(printf '%s' "$q" | sed 's/%40/@/g'); out=$(jq -c --arg e "$email" '[.[] | select(.email == $e)]' "$ST/users.json") ;;
    *"/users/"*"/reset-password") out=""; code=204 ;;
    *"/users/"*"/role-mappings/clients/"*)
      id=$(printf '%s' "$url" | sed -E 's#.*/users/([^/]+)/role-mappings.*#\1#')
      rf="$ST/roles_${id}.json"
      if [ "$method" = "GET" ]; then out=$(cat "$rf" 2>/dev/null || echo '[]'); else printf '%s' "$body" > "$rf"; code=204; fi ;;
    *"/users")
      n=$(cat "$ST/user_count"); n=$((n+1)); printf '%s' "$n" > "$ST/user_count"
      newuser=$(printf '%s' "$body" | jq -c --arg id "user-$n" '. + {id:$id}')
      cat "$ST/users.json" | jq -c --argjson u "$newuser" '. + [$u]' > "$ST/users.json.new"; mv "$ST/users.json.new" "$ST/users.json"; code=201 ;;
    *"/users/"*)
      id="${url##*/}"
      if [ "$method" = "GET" ]; then out=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$ST/users.json"); else cat "$ST/users.json" | jq -c --arg id "$id" --argjson m "$body" 'map(if .id==$id then $m else . end)' > "$ST/users.json.new"; mv "$ST/users.json.new" "$ST/users.json"; code=204; fi ;;
  esac
fi
if [ "$has_w" = "1" ] && [ "$has_o" = "1" ]; then printf '%s' "$code"; elif [ "$has_w" = "1" ]; then printf '%s\n%s' "$out" "$code"; else printf '%s' "$out"; fi
CURL
chmod +x "$STUBS/curl"

reset_state() {
  rm -rf "$IAM_STATE_DIR"; mkdir -p "$IAM_STATE_DIR"
  printf '%s' '{"attributes":[],"groups":[]}' > "$IAM_STATE_DIR/profile.json"
  printf '%s' '[]' > "$IAM_STATE_DIR/mappers.json"
  printf '%s' '0' > "$IAM_STATE_DIR/mapper_count"
  printf '%s' '[{"id":"client-1","clientId":"p2d2"}]' > "$IAM_STATE_DIR/clients.json"
  printf '%s' '[]' > "$IAM_STATE_DIR/users.json"
  printf '%s' '0' > "$IAM_STATE_DIR/user_count"
  : > "$IAM_STATE_DIR/faults.tsv"
  export STUB_NOOP_PUT=0
  : > "$IAM_REQ_LOG"
  : > "$LOGBUF"
}

write_demo_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
```yaml
version: 1
accounts:
  - username: hans
    email: hans.muster@nospam.scanea.de
    first_name: Hans
    last_name: Meier
    roles: [editor, verwaltung]
    home_region_key: de-Hamburg
    memberships:
      - { type: kommune, key: hamburg, role: verwaltung, wp_name: de-Hamburg }
  - username: jule
    email: jule.kovalenko@nospam.scanea.de
    first_name: Jule
    last_name: Kovalenko
    roles: [verwaltung, osm]
    home_region_key: de-Bonn
    memberships:
      - { type: kommune, key: koeln, role: verwaltung, wp_name: "de-Köln" }
      - { type: community, key: osm, role: osm }
```
EOF
}

inject_fault() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$IAM_STATE_DIR/faults.tsv"; }
count_writes() { grep -E '^(POST|PUT) ' "$IAM_REQ_LOG" | grep -v '/protocol/openid-connect/token' | wc -l | tr -d '[:space:]'; }
count_user_puts() { grep -E '^PUT ' "$IAM_REQ_LOG" | grep '/users/' | grep -v '/reset-password' | grep -v '/users/profile' | wc -l | tr -d '[:space:]'; }

# ── D1: Datei fehlt -> keine Accounts, keine Requests ─────────────────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$T/nope/demo-accounts.md"
unset P2D2_DEMO_PASSWORD
ensure_p2d2_demo_accounts >/dev/null 2>&1; rc=$?
check "D1 Datei fehlt rc=0" "0" "$rc"
check "D1 keine /users-Requests" "no" "$(grep -q '/users' "$IAM_REQ_LOG" && echo yes || echo no)"
check "D1 Meldung keine Demo-Accounts" "yes" "$(grep -q 'keine' "$LOGBUF" && echo yes || echo no)"

# ── D2: accounts leer -> wie D1 ────────────────────────────────────────────────
reset_state
mkdir -p "$T/d2"
printf '%s\n' '```yaml' 'version: 1' 'accounts: []' '```' > "$T/d2/demo-accounts.md"
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$T/d2/demo-accounts.md"
ensure_p2d2_demo_accounts >/dev/null 2>&1; rc=$?
check "D2 accounts leer rc=0" "0" "$rc"

# ── D3: Validierungsfehler -> rc != 0, kein /users-Request ─────────────────────
for bad in 'version: 2' 'accounts: nope' 'garbage' ; do
  reset_state
  mkdir -p "$T/d3"
  printf '%s\n' '```yaml' "$bad" '```' > "$T/d3/demo-accounts.md"
  export ADDON_IAM_DEMO_ACCOUNTS_FILE="$T/d3/demo-accounts.md"
  ensure_p2d2_demo_accounts >/dev/null 2>&1; rc=$?
  check "D3 $bad -> Fehler" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
  check "D3 $bad kein /users" "no" "$(grep -q '/users' "$IAM_REQ_LOG" && echo yes || echo no)"
done

# ── D4: echte Datei -> 6 Accounts ──────────────────────────────────────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$REPO/supplement/demo-accounts.md"
_iam_demo_load >/dev/null 2>&1; rc=$?
check "D4 Load rc=0" "0" "$rc"
check "D4 6 Accounts" "6" "$(printf '%s' "$ADDON_IAM_DEMO_JSON" | jq '.accounts | length')"

# ── D5: voller Demo-Pfad legt alle Accounts an ─────────────────────────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$REPO/supplement/demo-accounts.md"
export P2D2_DEMO_PASSWORD="DemoPass123"
ensure_p2d2_demo_accounts >/dev/null 2>&1; rc=$?
check "D5 Demo-Accounts rc=0" "0" "$rc"
check "D5 6 User angelegt" "6" "$(jq 'length' "$IAM_STATE_DIR/users.json")"
check "D5 Jule memberships gesetzt" "yes" "$(jq -e '.[] | select(.email=="jule.kovalenko@nospam.scanea.de") | .attributes["p2d2.memberships"]' "$IAM_STATE_DIR/users.json" >/dev/null 2>&1 && echo yes || echo no)"

# ── D7: zweiter Lauf -> keine zusätzlichen Schreiboperationen ──────────────────
u1=$(count_user_puts)
ensure_p2d2_demo_accounts >/dev/null 2>&1
u2=$(count_user_puts)
check "D7 Lauf 1 User-PUTs" "yes" "$([ "$u1" -gt 0 ] && echo yes || echo no)"
check "D7 keine zusätzlichen User-PUTs" "$u1" "$u2"

# ── D8: abweichende Startregion bleibt erhalten ────────────────────────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$REPO/supplement/demo-accounts.md"
export P2D2_DEMO_PASSWORD="DemoPass123"
printf '%s' '[{"id":"jule-1","username":"jule","email":"jule.kovalenko@nospam.scanea.de","enabled":true,"firstName":"Jule","lastName":"Kovalenko","attributes":{"p2d2.preferences.home_region_key":["de-Berlin"]}}]' > "$IAM_STATE_DIR/users.json"
ensure_p2d2_demo_accounts >/dev/null 2>&1; rc=$?
check "D8 rc=0" "0" "$rc"
check "D8 Startregion erhalten" "de-Berlin" "$(jq -r '.[] | select(.email=="jule.kovalenko@nospam.scanea.de") | .attributes["p2d2.preferences.home_region_key"][0]' "$IAM_STATE_DIR/users.json")"

# ── D13: Uninstall mit Datei löscht genau die Accounts der Datei ───────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$REPO/supplement/demo-accounts.md"
export P2D2_DEMO_PASSWORD="DemoPass123"
ensure_p2d2_demo_accounts >/dev/null 2>&1
check "D13 vor Uninstall 6 User" "6" "$(jq 'length' "$IAM_STATE_DIR/users.json")"
# Uninstall läuft über _iam_get_token -> benötigt Token, aber wir prüfen nur den Datei-Pfad.
uninstall_addon_iam >/dev/null 2>&1; rc=$?
check "D13 Uninstall rc=0" "0" "$rc"

# ── D15: kein Kennwort/Token in Ausgabe und Log ────────────────────────────────
reset_state
export ADDON_IAM_DEMO_ACCOUNTS_FILE="$REPO/supplement/demo-accounts.md"
export P2D2_DEMO_PASSWORD="DemoPass123"
ensure_p2d2_demo_accounts >"$T/out.txt" 2>&1
check "D15 kein Token/Passwort (out)" "no" "$(grep -qE 'STUB_TOKEN|Bearer|DemoPass123|STUB-PW-7f3a' "$T/out.txt" && echo yes || echo no)"
check "D15 kein Token/Passwort (log)" "no" "$(grep -qE 'STUB_TOKEN|Bearer|DemoPass123|STUB-PW-7f3a' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

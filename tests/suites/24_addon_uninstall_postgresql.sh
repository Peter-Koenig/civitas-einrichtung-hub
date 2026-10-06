#!/usr/bin/env bash
# Suite 24: addon_00_postgresql.sh Uninstall (T1/T2) + supplement/verify-uninstall.sh
# (T4). Nur Stubs, kein Cluster/Netz.
#
# Szenarien:
#   a) CR+DB vorhanden: Patch vor DROP DATABASE, dann Rollen, dann Secrets.
#   b) DB fehlt: kein psql mit -d p2d2; P2D2-*-Rollen über postgres; Erfolg.
#   c) DROP DATABASE schlägt fehl / DB bleibt: return 1, kein "abgeschlossen".
#   d) Rolle oder Secret bleibt: return 1.
#   e) exakte Rollen-/Secretnamen, kein Treffer auf fremde Namen.
#   f) verify-uninstall.sh: Exit 2 ohne DOMAIN; Reste -> Exit 1; DB weg + Rolle
#      übrig -> gemeldeter Rest; TLS-Secrets mit KEEP_TLS=auto sind kein Rest;
#      GeoServer-HTTP != 200 -> "nicht pruefbar".

begin_suite "addon_uninstall_postgresql"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"

# ── Modul-Tests ────────────────────────────────────────────────────────────────
LOG_BUF="$T/module.log"
KUBECTL_CALL_LOG="$T/kubectl_calls.log"
STATE_DIR="$T/state"

log()      { echo "L:$*" >> "$LOG_BUF"; }
log_ok()   { echo "O:$*" >> "$LOG_BUF"; }
log_warn() { echo "W:$*" >> "$LOG_BUF"; }
log_error(){ echo "E:$*" >> "$LOG_BUF"; }

export ADDON_DB_NS="cc-prd-database-stack"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_00_postgresql.sh"
set +e

# Zustands-gesteuerter kubectl-Stub (Dateien unter STATE_DIR).
cat > "$T/kubectl.sh" << 'KUBECTL_EOF'
#!/usr/bin/env bash
set -u
STATE_DIR="${STATE_DIR:?}"
args="$*"
case "$args" in
  *"get pods"*"spilo-role=master"*"-o name"*)
    echo "pod/central-db-0"; exit 0 ;;
  *"jsonpath={.data.username}"*)
    printf 'cG9zdGdyZXM='; exit 0 ;;
  *"get postgresql central-db"*"preparedDatabases.p2d2"*)
    cat "$STATE_DIR/cr" 2>/dev/null || true; exit 0 ;;
  *"get postgresql central-db"*)
    [[ "$(cat "$STATE_DIR/cr_absent" 2>/dev/null)" == "yes" ]] && exit 1 || exit 0 ;;
  *"patch postgresql central-db"*)
    [[ "$(cat "$STATE_DIR/patch_fail" 2>/dev/null)" == "yes" ]] && exit 1
    : > "$STATE_DIR/cr"; exit 0 ;;
  *"exec"*"psql"*"SELECT 1 FROM pg_database WHERE datname='p2d2'"*)
    [[ "$(cat "$STATE_DIR/db" 2>/dev/null)" == "yes" ]] && echo "1"
    exit 0 ;;
  *"exec"*"psql"*"SHOW server_version_num"*)
    echo "160003"; exit 0 ;;
  *"exec"*"psql"*"DROP DATABASE p2d2"*)
    [[ "$(cat "$STATE_DIR/drop_fail" 2>/dev/null)" == "yes" ]] && { echo "ERROR: drop" >&2; exit 1; }
    [[ "$(cat "$STATE_DIR/drop_noop" 2>/dev/null)" == "yes" ]] || : > "$STATE_DIR/db"
    exit 0 ;;
  *"exec"*"psql"*"pg_roles WHERE rolname IN"*)
    if [[ "$args" == *"p2d2_owner"* ]]; then
      cat "$STATE_DIR/op_roles" 2>/dev/null || true
    else
      cat "$STATE_DIR/p2d2_roles" 2>/dev/null || true
    fi
    exit 0 ;;
  *"exec"*"psql"*)
    exit 0 ;;
  *"delete secret"*)
    exit 0 ;;
  *"get secret"*)
    name="$(printf '%s' "$args" | sed -n 's/.*get secret \([^ ]*\).*/\1/p')"
    grep -qx "$name" "$STATE_DIR/secrets" 2>/dev/null && exit 0 || exit 1 ;;
esac
exit 0
KUBECTL_EOF
chmod +x "$T/kubectl.sh"

init_state() {
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/db"
  : > "$STATE_DIR/cr"
  printf 'no' > "$STATE_DIR/cr_absent"
  printf 'no' > "$STATE_DIR/patch_fail"
  printf 'no' > "$STATE_DIR/drop_fail"
  printf 'no' > "$STATE_DIR/drop_noop"
  : > "$STATE_DIR/op_roles"
  : > "$STATE_DIR/p2d2_roles"
  : > "$STATE_DIR/secrets"
  local kv
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$STATE_DIR/${kv%%=*}"; done
}

run_remove() {
  : > "$LOG_BUF"; : > "$KUBECTL_CALL_LOG"
  (
    export ADDON_DB_NS="cc-prd-database-stack"
    export STATE_DIR="$STATE_DIR"
    export KUBECTL_SCRIPT="$T/kubectl.sh"
    export KUBECTL_CALL_LOG="$KUBECTL_CALL_LOG"
    remove_p2d2_database
  )
}

run_uninstall() {
  : > "$LOG_BUF"; : > "$KUBECTL_CALL_LOG"
  (
    export ADDON_DB_NS="cc-prd-database-stack"
    export STATE_DIR="$STATE_DIR"
    export KUBECTL_SCRIPT="$T/kubectl.sh"
    export KUBECTL_CALL_LOG="$KUBECTL_CALL_LOG"
    uninstall_addon_postgresql
  )
}

order_ok() {
  local a b
  a=$(grep -nF "$1" "$KUBECTL_CALL_LOG" | head -1 | cut -d: -f1)
  b=$(grep -nF "$2" "$KUBECTL_CALL_LOG" | head -1 | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]
}

# a) CR+DB vorhanden: Reihenfolge Patch -> DROP DATABASE -> Rollen -> Secrets
init_state db=yes cr='{"defaultUsers":true}'
run_remove
check "a happy path: rc=0" "0" "$?"
check "a Patch vor DROP DATABASE" "yes" "$(order_ok 'patch postgresql central-db' 'DROP DATABASE p2d2' && echo yes || echo no)"
check "a DROP DATABASE vor Rollen" "yes" "$(order_ok 'DROP DATABASE p2d2' 'DROP ROLE IF EXISTS' && echo yes || echo no)"
check "a Rollen vor Secrets" "yes" "$(order_ok 'DROP ROLE IF EXISTS' 'delete secret' && echo yes || echo no)"
check "a Erfolgsmeldung" "yes" "$(grep -q 'PostgreSQL-Datenbank p2d2 + Operator-Rollen/-Secrets entfernt' "$LOG_BUF" && echo yes || echo no)"

# b) DB fehlt: kein -d p2d2; P2D2-Rollen über postgres; Erfolg ohne Fehlerlärm
init_state db=no cr=
run_uninstall
check "b DB fehlt: rc=0" "0" "$?"
check "b kein psql -d p2d2" "0" "$(grep -c -- '-d p2d2' "$KUBECTL_CALL_LOG")"
check "b P2D2-Rolle über postgres gedroppt" "yes" "$(grep -q -- '-d postgres' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "b Datenbank-nicht-vorhanden-Hinweis" "yes" "$(grep -q 'bereits nicht vorhanden' "$LOG_BUF" && echo yes || echo no)"
check "b kein Fehlerlaerm" "0" "$(grep -c '^E:' "$LOG_BUF")"

# c1) DROP DATABASE schlägt fehl -> return 1
init_state db=yes cr='{"defaultUsers":true}' drop_fail=yes
run_remove
check "c1 DROP fail: rc=1" "1" "$?"
check "c1 kein abgeschlossen" "no" "$(grep -q 'entfernt"' "$LOG_BUF" && echo yes || echo no)"

# c2) DB bleibt nach DROP -> return 1
init_state db=yes cr='{"defaultUsers":true}' drop_noop=yes
run_remove
check "c2 DB bleibt: rc=1" "1" "$?"
check "c2 Meldung weiterhin vorhanden" "yes" "$(grep -q 'nach DROP weiterhin vorhanden' "$LOG_BUF" && echo yes || echo no)"

# d) Rolle oder Secret bleibt -> return 1
init_state db=no cr= op_roles="p2d2_owner"
run_remove
check "d Rolle bleibt: rc=1" "1" "$?"

init_state db=no cr= secrets="p2d2-owner-user.central-db.credentials.postgresql.acid.zalan.do"
run_remove
check "d Secret bleibt: rc=1" "1" "$?"

# e) exakte Namen, kein Treffer auf fremde Namen
init_state db=yes cr='{"defaultUsers":true}'
run_remove
check "e genau 6 Operator-Rollen gedroppt" "6" "$(grep -c -- 'DROP ROLE IF EXISTS' "$KUBECTL_CALL_LOG")"
check "e Rolle p2d2_owner_user exakt" "yes" "$(grep -q -- 'DROP ROLE IF EXISTS "p2d2_owner_user"' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "e Rolle p2d2_owner exakt" "yes" "$(grep -q -- 'DROP ROLE IF EXISTS "p2d2_owner"' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "e Secret exakt" "yes" "$(grep -q -- 'delete secret p2d2-reader-user.central-db.credentials.postgresql.acid.zalan.do' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "e kein fremder Name (keycloak)" "0" "$(grep -c -- 'keycloak_owner\|keycloak_reader\|keycloak_writer' "$KUBECTL_CALL_LOG")"

# ── verify-uninstall.sh Tests ─────────────────────────────────────────────────
VU_STUBS="$T/vu_stubs"; mkdir -p "$VU_STUBS"
VU_SCRIPT="$T/verify-uninstall.sh"
cp "$REPO/supplement/verify-uninstall.sh" "$VU_SCRIPT"
chmod +x "$VU_SCRIPT"
VU_LOG="$T/vu.log"

cat > "$VU_STUBS/kubectl" << 'VU_KUBECTL_EOF'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *"get deploy,svc,cm,secret,ingress,pvc,jobs -o name"*)
    printf '%s\n' ${FE_RESOURCES:-}; exit 0 ;;
  *"get secret -o name"*)
    printf '%s\n' ${SECRET_NAMES:-}; exit 0 ;;
  *"get secret cc-prd-keycloak-admin"*"MASTER_USERNAME"*)
    printf 'YWRtaW4='; exit 0 ;;
  *"get secret cc-prd-keycloak-admin"*"MASTER_PASSWORD"*)
    printf 'cHc='; exit 0 ;;
  *"get secret cc-prd-keycloak-admin"*)
    [[ "${IAM_SECRET_READABLE:-yes}" == "yes" ]] && exit 0 || exit 1 ;;
  *"get deploy,svc,cm,pvc -o name"*)
    printf '%s\n' ${MP_RESOURCES:-}; exit 0 ;;
  *"get secret geoserver-geoserver"*"geoserver-user"*)
    printf 'YWRtaW4='; exit 0 ;;
  *"get secret geoserver-geoserver"*"geoserver-password"*)
    printf 'cHc='; exit 0 ;;
  *"get pods -o jsonpath"*)
    printf '%s' "${GS_POD_NAME:-}"; exit 0 ;;
  *"exec"*"ls -A"*)
    exit 0 ;;
  *"get postgresql central-db"*)
    printf '%s' "${DB_CR:-}"; exit 0 ;;
  *"get secret postgres.central-db.credentials.postgresql.acid.zalan.do"*"username"*)
    printf 'cG9zdGdyZXM='; exit 0 ;;
  *"get pods"*"spilo-role=master"*"-o name"*)
    echo "pod/central-db-0"; exit 0 ;;
  *"exec"*"psql"*"SELECT 1 FROM pg_database WHERE datname='p2d2'"*)
    [[ "${DB_PRESENT:-no}" == "yes" ]] && echo "1"
    exit 0 ;;
  *"exec"*"psql"*"pg_namespace WHERE nspname LIKE"*)
    printf '%s\n' ${DB_SCHEMAS:-}; exit 0 ;;
  *"exec"*"psql"*"pg_roles WHERE rolname IN"*)
    if [[ "$args" == *"p2d2_owner"* ]]; then
      printf '%s\n' ${DB_OP_ROLES:-}
    else
      printf '%s\n' ${DB_P2D2_ROLES:-}
    fi
    exit 0 ;;
  *"get secret p2d2-"*)
    name="$(printf '%s' "$args" | sed -n 's/.*get secret \([^ ]*\).*/\1/p')"
    for s in ${DB_OP_SECRETS:-}; do [[ "$s" == "$name" ]] && exit 0; done
    exit 1 ;;
esac
exit 0
VU_KUBECTL_EOF
chmod +x "$VU_STUBS/kubectl"

cat > "$VU_STUBS/curl" << 'VU_CURL_EOF'
#!/usr/bin/env bash
url=""
has_w=0
for a in "$@"; do
  case "$a" in
    https://*) url="$a" ;;
    -w) has_w=1 ;;
  esac
done
code=200
body=""
case "$url" in
  *"/protocol/openid-connect/token"*) body='{"access_token":"STUB_TOKEN"}' ;;
  *"/admin/realms/"*"/clients"*) body='[]' ;;
  *"/identity-provider/instances/osm"*) code=404 ;;
  *"/users?email="*) body='[]' ;;
  *"/geoserver/rest/workspaces.json"*)
    code="${GS_HTTP:-200}"
    body="${GS_BODY:-{\"workspaces\":{\"workspace\":[]}}}"
    ;;
esac
if [ "$has_w" = "1" ]; then printf '%s' "$code"; else printf '%s' "$body"; fi
VU_CURL_EOF
chmod +x "$VU_STUBS/curl"

run_vu() {
  : > "$VU_LOG"
  (
    export PATH="$VU_STUBS:$PATH"
    local kv
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    "$VU_SCRIPT" > "$VU_LOG" 2>&1
  )
}

# f1) kein DOMAIN -> Exit 2
run_vu DOMAIN= DOMAIN_NAME= ADDON_DOMAIN=
check "f1 kein DOMAIN: rc=2" "2" "$?"

# f4) TLS-Secrets mit KEEP_TLS=auto sind kein Rest -> Exit 0
run_vu DOMAIN=udp.example.com \
  FE_RESOURCES="secret/f-de1.udp.example.com-tls" \
  SECRET_NAMES="secret/f-de1.udp.example.com-tls" \
  KEEP_TLS=auto
check "f4 TLS-Secret kein Rest: rc=0" "0" "$?"
check "f4 bewusst behalten gemeldet" "yes" "$(grep -q 'bewusst behalten' "$VU_LOG" && echo yes || echo no)"
check "f4 kein Frontend-Rest" "no" "$(grep -q 'Frontend-Ressourcen vorhanden' "$VU_LOG" && echo yes || echo no)"

# f2) Reste -> Exit 1 (Datenbank vorhanden)
run_vu DOMAIN=udp.example.com DB_PRESENT=yes
check "f2 Reste: rc=1" "1" "$?"

# f3) DB weg + Rolle übrig -> gemeldeter Rest, nicht grün
run_vu DOMAIN=udp.example.com DB_PRESENT=no DB_P2D2_ROLES="P2D2-Admin"
check "f3 DB weg + Rolle: rc=1" "1" "$?"
check "f3 Rolle als Rest gemeldet" "yes" "$(grep -qF 'P2D2-*-Rollen vorhanden' "$VU_LOG" && echo yes || echo no)"
check "f3 nicht gruen (keine-Rollen)" "no" "$(grep -qF 'keine P2D2-*-Rollen' "$VU_LOG" && echo yes || echo no)"
check "f3 Schema n/a" "yes" "$(grep -q 'n/a (Datenbank nicht vorhanden)' "$VU_LOG" && echo yes || echo no)"

# f5) GeoServer-HTTP != 200 -> nicht pruefbar (Rest)
run_vu DOMAIN=udp.example.com GS_HTTP=500
check "f5 GeoServer != 200: rc=1" "1" "$?"
check "f5 nicht pruefbar gemeldet" "yes" "$(grep -q 'nicht pruefbar' "$VU_LOG" && echo yes || echo no)"

rm -rf "$T"

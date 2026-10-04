#!/usr/bin/env bash
# Suite 02: 06b_idm_provisioning.sh — Login-Test, Passwort-Reset, Client-Rollen,
# Token-Retry, Fail-Closed-Skip-Pfade, 401-Erneuerung.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "idm_provisioning"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGBUF=$(mktemp)
SC=$(mktemp -d)

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1/06b_idm_provisioning.sh
source "$REPO/modules_V1/06b_idm_provisioning.sh"
set +e

idm="https://idm.example"; tok="STUB_TOKEN"; realm="cc-prd"; uid="USER1"
ADMIN_EMAIL="admin@data-dna.eu"; ADMIN_PASS="TEST_PASS_DO_NOT_USE"
CC_ENVIRONMENT="cc-prd"; DOMAIN="example"
IDM_TOKEN_RETRIES=3; IDM_TOKEN_RETRY_DELAY=0
master_user="admin"; master_pass="MASTER_PASS_DO_NOT_USE"
CLIENTS='[{"id":"geo-client","clientId":"geostack"},{"id":"superset-client","clientId":"superset"},{"id":"grafana-client","clientId":"grafana"},{"id":"operator-client","clientId":"operator-app"}]'
export CURL_TOKEN CURL_CLIENTS CURL_ASSIGN CURL_ASSIGNED CURL_TOKEN_FAILS CURL_401_ONCE STUB_CONTROL KUBECTL_MODE
STUB_CONTROL="$SC"
export STUB_CONTROL

# reset_curl setzt die curl-Stub-Umgebung auf einen neutralen Zustand zurück.
reset_curl() {
  CURL_TOKEN=ok; CURL_CLIENTS=four; CURL_ASSIGN=ok; CURL_ASSIGNED='[]'
  CURL_TOKEN_FAILS=; CURL_401_ONCE=0
  rm -f "$SC/token_fails" "$SC/roles_401"
}

# A: Login ok
reset_curl
keycloak_login_ok "$idm" "$realm" "$ADMIN_EMAIL" "$ADMIN_PASS"; rc=$?
check "A Login ok -> 0" "0" "$rc"

# B: Login fail, error_description geloggt, kein Passwort
: > "$LOGBUF"
reset_curl; CURL_TOKEN=fail
keycloak_login_ok "$idm" "$realm" "$ADMIN_EMAIL" "$ADMIN_PASS"; rc=$?
check "B Login fail -> 1" "1" "$rc"
check "B error_description geloggt" "yes" "$(grep -q 'Invalid user credentials' "$LOGBUF" && echo yes || echo no)"
check "B kein Passwort im Log" "no" "$(grep -q 'TEST_PASS_DO_NOT_USE' "$LOGBUF" && echo yes || echo no)"

# C: alle 4 Rollen in je einem Client → alle neu zugewiesen, rc=0
: > "$LOGBUF"
reset_curl
assign_admin_roles "$idm" "$realm" "$uid" "$CLIENTS" "$master_user" "$master_pass"; rc=$?
check "C rc=0" "0" "$rc"
check "C gefunden=4" "yes" "$(grep -q 'gefunden=4' "$LOGBUF" && echo yes || echo no)"
check "C neu zugewiesen=4" "yes" "$(grep -q 'neu zugewiesen=4' "$LOGBUF" && echo yes || echo no)"

# D: keine Rolle gefunden → fehlend=4, rc=1
: > "$LOGBUF"
reset_curl
assign_admin_roles "$idm" "$realm" "$uid" '[]' "$master_user" "$master_pass"; rc=$?
check "D rc=1" "1" "$rc"
check "D fehlend=4" "yes" "$(grep -q 'fehlend=4' "$LOGBUF" && echo yes || echo no)"

# E: geoAdmin in zwei Clients → mehrdeutig, rc=1
: > "$LOGBUF"
reset_curl
assign_admin_roles "$idm" "$realm" "$uid" '[{"id":"geo-client"},{"id":"geo-client2"}]' "$master_user" "$master_pass"; rc=$?
check "E rc=1" "1" "$rc"
check "E mehrdeutig=1" "yes" "$(grep -q 'mehrdeutig=1' "$LOGBUF" && echo yes || echo no)"

# F: bereits zugewiesen (Idempotenz)
: > "$LOGBUF"
reset_curl
CURL_ASSIGNED='[{"id":"geo-role-id","name":"geoAdmin"},{"id":"superset-role-id","name":"supersetAdmin"},{"id":"grafana-role-id","name":"grafanaAdmin"},{"id":"operator-role-id","name":"operator"}]'
assign_admin_roles "$idm" "$realm" "$uid" "$CLIENTS" "$master_user" "$master_pass"; rc=$?
check "F rc=0" "0" "$rc"
check "F bereits zugewiesen=4" "yes" "$(grep -q 'bereits zugewiesen=4' "$LOGBUF" && echo yes || echo no)"

# G: Token-Retry — erst der dritte Versuch klappt
: > "$LOGBUF"
reset_curl; CURL_TOKEN_FAILS=2
fetch_master_token "$idm" "$master_user" "$master_pass" >/dev/null; rc=$?
check "G Token-Retry -> 0" "0" "$rc"
check "G drei Token-Versuche" "2" "$(cat "$SC/token_fails" 2>/dev/null || echo 0)"

# H: Token nie — fetch_master_token gibt 1
: > "$LOGBUF"
reset_curl; CURL_TOKEN=fail
fetch_master_token "$idm" "$master_user" "$master_pass" >/dev/null; rc=$?
check "H Token nie -> 1" "1" "$rc"

# I: Namespace fehlt → ensure_keycloak_admin_user gibt 1
: > "$LOGBUF"
reset_curl; KUBECTL_MODE=no_ns
ensure_keycloak_admin_user >/dev/null; rc=$?
check "I Namespace fehlt -> 1" "1" "$rc"

# J: Secret fehlt → ensure_keycloak_admin_user gibt 1
: > "$LOGBUF"
reset_curl; KUBECTL_MODE=no_secret
ensure_keycloak_admin_user >/dev/null; rc=$?
check "J Secret fehlt -> 1" "1" "$rc"

# K: 401 mitten in der Rollenabfrage → Token-Erneuerung, Zähler unverändert
: > "$LOGBUF"
reset_curl; CURL_401_ONCE=1
assign_admin_roles "$idm" "$realm" "$uid" "$CLIENTS" "$master_user" "$master_pass"; rc=$?
check "K 401-Erneuerung rc=0" "0" "$rc"
check "K gefunden=4 (trotz 401)" "yes" "$(grep -q 'gefunden=4' "$LOGBUF" && echo yes || echo no)"
check "K kein Passwort/Token im Log" "no" "$(grep -qE 'TEST_PASS_DO_NOT_USE|MASTER_PASS_DO_NOT_USE|STUB_TOKEN' "$LOGBUF" && echo yes || echo no)"

rm -f "$LOGBUF"; rm -rf "$SC"

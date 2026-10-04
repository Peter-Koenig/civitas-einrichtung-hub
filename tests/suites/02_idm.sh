#!/usr/bin/env bash
# Suite 02: 06b_idm_provisioning.sh — Login-Test, Passwort-Reset, Client-Rollen.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "idm_provisioning"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOGBUF=$(mktemp)

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1/06b_idm_provisioning.sh
source "$REPO/modules_V1/06b_idm_provisioning.sh"
set +e

idm="https://idm.example"; tok="STUB_TOKEN"; realm="cc-prd"; uid="USER1"
ADMIN_EMAIL="admin@data-dna.eu"; ADMIN_PASS="TEST_PASS_DO_NOT_USE"
# CURL_*-Variablen exportieren, damit der curl-Stub (eigener Prozess) sie sieht.
export CURL_TOKEN CURL_CLIENTS CURL_ASSIGN CURL_ASSIGNED

# A: Login ok
CURL_TOKEN=ok
keycloak_login_ok "$idm" "$realm" "$ADMIN_EMAIL" "$ADMIN_PASS"; rc=$?
check "A Login ok -> 0" "0" "$rc"

# B: Login fail, error_description geloggt, kein Passwort
: > "$LOGBUF"
CURL_TOKEN=fail
keycloak_login_ok "$idm" "$realm" "$ADMIN_EMAIL" "$ADMIN_PASS"; rc=$?
check "B Login fail -> 1" "1" "$rc"
check "B error_description geloggt" "yes" "$(grep -q 'Invalid user credentials' "$LOGBUF" && echo yes || echo no)"
check "B kein Passwort im Log" "no" "$(grep -q 'TEST_PASS_DO_NOT_USE' "$LOGBUF" && echo yes || echo no)"

# C: alle 4 Rollen in je einem Client → alle neu zugewiesen, rc=0
: > "$LOGBUF"
CURL_CLIENTS=four; CURL_ASSIGN=ok; CURL_ASSIGNED='[]'
assign_admin_roles "$idm" "$tok" "$realm" "$uid"; rc=$?
check "C rc=0" "0" "$rc"
check "C gefunden=4" "yes" "$(grep -q 'gefunden=4' "$LOGBUF" && echo yes || echo no)"
check "C neu zugewiesen=4" "yes" "$(grep -q 'neu zugewiesen=4' "$LOGBUF" && echo yes || echo no)"

# D: keine Rolle gefunden → fehlend=4, rc=1
: > "$LOGBUF"
CURL_CLIENTS=none; CURL_ASSIGN=ok; CURL_ASSIGNED='[]'
assign_admin_roles "$idm" "$tok" "$realm" "$uid"; rc=$?
check "D rc=1" "1" "$rc"
check "D fehlend=4" "yes" "$(grep -q 'fehlend=4' "$LOGBUF" && echo yes || echo no)"

# E: geoAdmin in zwei Clients → mehrdeutig, rc=1
: > "$LOGBUF"
CURL_CLIENTS=geo_dup; CURL_ASSIGN=ok; CURL_ASSIGNED='[]'
assign_admin_roles "$idm" "$tok" "$realm" "$uid"; rc=$?
check "E rc=1" "1" "$rc"
check "E mehrdeutig=1" "yes" "$(grep -q 'mehrdeutig=1' "$LOGBUF" && echo yes || echo no)"

# F: bereits zugewiesen (Idempotenz)
: > "$LOGBUF"
CURL_CLIENTS=four; CURL_ASSIGN=ok
CURL_ASSIGNED='[{"id":"geo-role-id","name":"geoAdmin"},{"id":"superset-role-id","name":"supersetAdmin"},{"id":"grafana-role-id","name":"grafanaAdmin"},{"id":"operator-role-id","name":"operator"}]'
assign_admin_roles "$idm" "$tok" "$realm" "$uid"; rc=$?
check "F rc=0" "0" "$rc"
check "F bereits zugewiesen=4" "yes" "$(grep -q 'bereits zugewiesen=4' "$LOGBUF" && echo yes || echo no)"

rm -f "$LOGBUF"

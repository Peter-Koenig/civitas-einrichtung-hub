#!/usr/bin/env bash
# Suite 27: Turn 6 — APISIX-Key-Lader (Aufgabe A) und Portal-Icons (Aufgabe B).
# Nur Stubs, kein Cluster/Netz, keine Secrets in Ausgaben.

begin_suite "addon_apisix_portal"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"

log()      { :; }
log_ok()   { :; }
log_warn() { :; }
log_error(){ :; }

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_20_mapproxy.sh"
set +e

# ── Aufgabe A: addon_apisix_admin_key ─────────────────────────────────────────
CREDS_FILE="$T/creds"
mk_creds() { printf '%b' "$1" > "$CREDS_FILE"; }

mk_creds 'APISIX_ADMIN_ROLE_KEY=secret-key-123'
check "A unquoted" "secret-key-123" "$(addon_apisix_admin_key "$CREDS_FILE")"

mk_creds 'APISIX_ADMIN_ROLE_KEY="secret-key-123"'
check "A doppelt quotiert" "secret-key-123" "$(addon_apisix_admin_key "$CREDS_FILE")"

mk_creds "APISIX_ADMIN_ROLE_KEY='secret-key-123'"
check "A einfach quotiert" "secret-key-123" "$(addon_apisix_admin_key "$CREDS_FILE")"

mk_creds 'export APISIX_ADMIN_ROLE_KEY=secret-key-123'
check "A export" "secret-key-123" "$(addon_apisix_admin_key "$CREDS_FILE")"

# 401-Ursache: export + doppelt quotiert (realistische credentials.env).
mk_creds 'export APISIX_ADMIN_ROLE_KEY="secret-key-123"'
check "A export+doppelt quotiert" "secret-key-123" "$(addon_apisix_admin_key "$CREDS_FILE")"

mk_creds 'APISIX_ADMIN_ROLE_KEY='
check "A leer: rc=1" "1" "$(addon_apisix_admin_key "$CREDS_FILE" >/dev/null 2>&1; echo $?)"

rm -f "$CREDS_FILE"
check "A fehlt: rc=1" "1" "$(addon_apisix_admin_key "$CREDS_FILE" >/dev/null 2>&1; echo $?)"

mk_creds 'APISIX_ADMIN_ROLE_KEY=a\nAPISIX_ADMIN_ROLE_KEY=b'
check "A mehrdeutig: rc=1" "1" "$(addon_apisix_admin_key "$CREDS_FILE" >/dev/null 2>&1; echo $?)"

# Keine separate abweichende sed-Regel mehr.
check "A mapproxy: keine separate sed-Regel" "0" "$(grep -cF "sed -n 's/^APISIX_ADMIN_ROLE_KEY" "$REPO/modules_addon_V1s/addon_20_mapproxy.sh")"
check "A verify: keine separate sed-Regel" "0" "$(grep -cF "sed -n 's/^APISIX_ADMIN_ROLE_KEY" "$REPO/supplement/verify-uninstall.sh")"

# ── Aufgabe B: Portal-Icons ───────────────────────────────────────────────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_35_portal.sh"
WORK="$T/work"; mkdir -p "$WORK"
BLOCK="$WORK/block.js"

unset PORTAL_ICON
_portal_build_block "$WORK"
check "B default: 5 stage-Icons" "5" "$(grep -cF 'images/p2d2-logo.svg' "$BLOCK")"
check "B default: kein data-dna" "0" "$(grep -cF 'data-dna.eu' "$BLOCK")"
check "B default: www-Icon aus eigenem Pod" "1" "$(grep -cF 'https://www.${DOMAIN}/images/p2d2-logo.svg' "$BLOCK")"
check "B default: f-fv-Icon aus eigenem Pod" "1" "$(grep -cF 'https://f-fv.${DOMAIN}/images/p2d2-logo.svg' "$BLOCK")"

export PORTAL_ICON="https://custom.example/icon.svg"
_portal_build_block "$WORK"
check "B override: alle 5" "5" "$(grep -cF 'https://custom.example/icon.svg' "$BLOCK")"
check "B override: kein stage-Icon" "0" "$(grep -cF 'images/p2d2-logo.svg' "$BLOCK")"

rm -rf "$T"

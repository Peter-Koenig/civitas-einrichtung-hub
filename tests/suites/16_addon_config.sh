#!/usr/bin/env bash
# Suite 16: addon_01_config.sh — zentrale Validierung des Konfigurationsvertrags.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "addon_config"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
set +e

# valid_env — setzt alle Variablen eines gültigen Konfigurationsvertrags.
valid_env() {
  export DOMAIN_NAME="example.org"
  unset ADDON_DOMAIN

  export P2D2_BASE_APP_DEBUG="false"
  export P2D2_BASE_DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"
  export P2D2_BASE_DB_HOST="central-db.svc.cluster.local"
  export P2D2_BASE_DB_PORT="5432"
  export P2D2_BASE_DB_NAME="p2d2"
  export P2D2_BASE_WFST_NAMESPACE="urn:example:govdata"
  export P2D2_BASE_PUBLIC_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ows"
  export P2D2_BASE_PUBLIC_MAPSERVER_URL="https://geoportal.udp.example.org/mapserver"
  export P2D2_BASE_SMTP_HOST="smtp.example.org"
  export P2D2_BASE_SMTP_PORT="587"
  export P2D2_BASE_SMTP_SECURE="false"
  export P2D2_BASE_SMTP_USER="smtp-user"
  export P2D2_BASE_CONTACT_EMAIL_TO="admin@example.org"
  export P2D2_BASE_CONTACT_EMAIL_FROM="noreply@example.org"

  export P2D2_BASE_ALTCHA_HMAC_KEY="hmac-key"
  export P2D2_BASE_SMTP_PASS="smtp-pass"
  export P2D2_BASE_OIDC_ISSUER="https://idm.udp.example.org/realms/cc-prd"
  export P2D2_DEMO_PASSWORD="DemoPass1"
  export P2D2_OSM_IDP_CLIENT_ID="osm-client"
  export P2D2_OSM_IDP_CLIENT_SECRET="osm-secret"
  export P2D2_GITHUB_TOKEN="gh-token"
  export P2D2_GITLAB_TOKEN="gl-token"

  export P2D2_DEMO_ACCOUNTS="false"
  export P2D2_OSM_IDP_ENABLE="false"

  local key
  for key in MAIN DEVELOP DE1 DE2 FV; do
    export "P2D2_${key}_DB_USER=P2D2-${key}"
    export "P2D2_${key}_WFST_WORKSPACE=ws"
    export "P2D2_${key}_PUBLIC_SITE_URL=https://site.udp.example.org"
    export "P2D2_${key}_WFST_ENDPOINT=https://geoportal.udp.example.org/geoserver/ws/ows"
    export "P2D2_${key}_WFST_USERNAME=wfst-user"
    export "P2D2_${key}_DB_PASSWORD=db-pass"
    export "P2D2_${key}_WFST_PASSWORD=wfst-pass"
    export "P2D2_${key}_SESSION_SECRET=session-secret"
  done
}

# rc_of <modifikation...> — valid_env + Modifikation, dann addon_validate_config.
# Gibt den Exit-Code zurück (0 = valid, 1 = Fehler).
rc_of() {
  ( valid_env; "$@"; addon_validate_config >/dev/null 2>&1; echo $? )
}

# _preflight_env — Delegation wie im Hauptskript (für Test 9).
_preflight_env() { addon_validate_config || return 1; }

# ── Test 1: vollständige minimale Konfiguration ist valid ─────────────────────
check "1 minimale Konfiguration valid" "0" "$(rc_of true)"

# ── Test 2: DOMAIN_NAME beginnt mit udp. → Fehler ─────────────────────────────
check "2 DOMAIN_NAME=udp. Fehler" "1" "$(rc_of export DOMAIN_NAME='udp.example.org')"

# ── Test 3: DOMAIN_NAME CHANGEME / Leerzeichen / unzulässiges Zeichen ──────────
check "3 DOMAIN_NAME CHANGEME Fehler" "1" "$(rc_of export DOMAIN_NAME='CHANGEME.example.org')"
check "3 DOMAIN_NAME Leerzeichen Fehler" "1" "$(rc_of export DOMAIN_NAME=' example.org')"
check "3 DOMAIN_NAME unzulässig Fehler" "1" "$(rc_of export DOMAIN_NAME='exa_mple.org')"

# ── Test 4: ADDON_DOMAIN leer → valid ──────────────────────────────────────────
check "4 ADDON_DOMAIN leer valid" "0" "$(rc_of export ADDON_DOMAIN='')"

# ── Test 5: ADDON_DOMAIN exakt udp.${DOMAIN_NAME} → valid ──────────────────────
check "5 ADDON_DOMAIN passend valid" "0" "$(rc_of export ADDON_DOMAIN='udp.example.org')"

# ── Test 6: abweichendes ADDON_DOMAIN → Fehler ─────────────────────────────────
check "6 ADDON_DOMAIN abweichend Fehler" "1" "$(rc_of export ADDON_DOMAIN='udp.other.org')"

# ── Test 7: Schalter normalisieren; leer/ungültig Fehler ───────────────────────
b="true";  addon_normalize_bool b; check "7 true→true" "true" "$b"
b="false"; addon_normalize_bool b; check "7 false→false" "false" "$b"
b="TRUE";  addon_normalize_bool b; check "7 TRUE→true" "true" "$b"
b="FALSE"; addon_normalize_bool b; check "7 FALSE→false" "false" "$b"
check "7 bool leer Fehler" "1" "$(rc_of export P2D2_DEMO_ACCOUNTS='')"
check "7 bool ungültig Fehler" "1" "$(rc_of export P2D2_DEMO_ACCOUNTS='maybe')"

# ── Test 8: fehlender/CHANGEME nicht-sensitiver Stage-Wert → Fehler ────────────
check "8 Stage-Wert fehlt Fehler" "1" "$(rc_of unset P2D2_MAIN_DB_USER)"
check "8 Stage-Wert CHANGEME Fehler" "1" "$(rc_of export P2D2_MAIN_PUBLIC_SITE_URL='CHANGEME')"

# ── Test 9: fehlender Pflichtsecret-Wert → _preflight_env schlägt fehl ─────────
check "9 _preflight_env fehlender Secret" "1" \
  "$( ( valid_env; unset P2D2_BASE_SMTP_PASS; _preflight_env >/dev/null 2>&1; echo $? ) )"

# ── Test 10: ADDON_SSH_KEY_FILE bleibt Pfad, kein Pflicht-/Secret-Wert ─────────
check "10 SSH_KEY_FILE Pfad valid" "0" "$(rc_of export ADDON_SSH_KEY_FILE='/root/.ssh/admin_key')"
check "10 Modul referenziert SSH_KEY_FILE nicht" "0" \
  "$(grep -c 'ADDON_SSH_KEY_FILE' "$REPO/modules_addon_V1s/addon_01_config.sh")"

# ── Test 11: Vorlage enthält nur erwartete Platzhalter, keine Secrets ──────────
TEMPLATE="$REPO/.env.p2d2-addon.example"
check "11 Vorlage vorhanden" "yes" "$([[ -f "$TEMPLATE" ]] && echo yes || echo no)"
check "11 Vorlage nutzt CHANGEME-Platzhalter" "yes" "$(grep -q 'CHANGEME' "$TEMPLATE" && echo yes || echo no)"
check "11 kein privater Schlüssel" "0" "$(grep -cE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' "$TEMPLATE")"
check "11 kein GitLab-Token" "0" "$(grep -cE 'glpat-[A-Za-z0-9_-]+' "$TEMPLATE")"
check "11 kein GitHub-Token" "0" "$(grep -cE 'gh[pousr]_[A-Za-z0-9]+' "$TEMPLATE")"
check "11 kein AWS-Key" "0" "$(grep -cE 'AKIA[0-9A-Z]{16}' "$TEMPLATE")"

rm -rf "$T"

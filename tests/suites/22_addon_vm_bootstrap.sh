#!/usr/bin/env bash
# Suite 22: Host→VM-Bootstrap-Reihenfolge (Turn 14). Die .env wird im VM-Kontext
# vor den Domain-Modulen geladen; der Host-Kontext bindet die Fachmodule nicht ein.

begin_suite "addon_vm_bootstrap"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"

# Zeilennummer einer festen Zeichenkette im Hauptskript.
lnum() { grep -nF "$1" "$MAIN" | head -1 | cut -d: -f1; }

# ── 1) Statisch: Bootstrap-Reihenfolge im Hauptskript ──────────────────────────
host_line="$(lnum 'if [[ "${ADDON_CONTEXT}" == "host" ]]')"
derive_line="$(grep -nE '^addon_derive_domain$' "$MAIN" | head -1 | cut -d: -f1)"
validate_line="$(lnum 'addon_validate_config || exit 1')"
env_load_line="$(lnum 'source "${ADDON_ENV_FILE}"')"
ssh_line="$(lnum 'addon_05_ssh.sh')"
config_line="$(lnum 'addon_01_config.sh')"
geo_line="$(lnum 'addon_10_geoserver.sh')"
iam_line="$(lnum 'addon_25_iam.sh')"
portal_line="$(lnum 'addon_35_portal.sh')"

check "SSH/Config vor Host-Block" "yes" \
  "$([[ "${ssh_line}" -lt "${host_line}" && "${config_line}" -lt "${host_line}" ]] && echo yes || echo no)"
check "Fachmodule nach Host-Block" "yes" \
  "$([[ "${geo_line}" -gt "${host_line}" && "${iam_line}" -gt "${host_line}" && "${portal_line}" -gt "${host_line}" ]] && echo yes || echo no)"
check "Fachmodule nach addon_derive_domain" "yes" "$([[ "${geo_line}" -gt "${derive_line}" ]] && echo yes || echo no)"
check "addon_validate_config vor Fachmodulen" "yes" "$([[ "${validate_line}" -lt "${geo_line}" ]] && echo yes || echo no)"
check ".env vor Fachmodulen geladen" "yes" "$([[ "${env_load_line}" -lt "${geo_line}" ]] && echo yes || echo no)"

# ── 2) Statisch: Remote-Aufruf ohne Domain/Secret ─────────────────────────────
check "remote_cmd install nur ADDON_CONTEXT=vm" "1" "$(grep -cF 'remote_cmd="ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh"' "$MAIN")"
check "remote_cmd uninstall nur ADDON_CONTEXT=vm" "1" "$(grep -cF 'remote_cmd="ADDON_CONTEXT=vm ./p2d2-civitas-addon-v1s.sh --uninstall"' "$MAIN")"
check "remote_cmd ohne DOMAIN_NAME" "0" "$(grep -cE 'remote_cmd=.*DOMAIN_NAME' "$MAIN")"
check "remote_cmd ohne ADDON_DOMAIN" "0" "$(grep -cE 'remote_cmd=.*ADDON_DOMAIN' "$MAIN")"

# ── 3) addon_derive_domain ────────────────────────────────────────────────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"

export DOMAIN_NAME="example.org"; unset ADDON_DOMAIN
addon_derive_domain
check "nur DOMAIN_NAME -> udp.example.org" "udp.example.org" "${ADDON_DOMAIN:-}"

export DOMAIN_NAME="example.org"; export ADDON_DOMAIN="udp.custom.org"
addon_derive_domain
check "explizites ADDON_DOMAIN bleibt" "udp.custom.org" "${ADDON_DOMAIN}"

unset DOMAIN_NAME ADDON_DOMAIN
addon_derive_domain
check "ohne DOMAIN_NAME bleibt leer" "" "${ADDON_DOMAIN:-}"

# ── 4) Verhaltens-Test: Hauptskript im VM-Kontext ─────────────────────────────
# Vollständige .env (nur DOMAIN_NAME als Domain-Basis, kein ADDON_DOMAIN).
write_env() {
  # $1 = Datei; $2 = optionale Zusatzzeile.
  cat > "$1" <<'ENVEOF'
DOMAIN_NAME="example.org"
P2D2_BASE_APP_DEBUG="false"
P2D2_BASE_DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"
P2D2_BASE_DB_HOST="central-db.svc.cluster.local"
P2D2_BASE_DB_PORT="5432"
P2D2_BASE_DB_NAME="p2d2"
P2D2_BASE_WFST_NAMESPACE="urn:example:govdata"
P2D2_BASE_PUBLIC_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ows"
P2D2_BASE_PUBLIC_MAPSERVER_URL="https://geoportal.udp.example.org/mapserver"
P2D2_BASE_SMTP_HOST="smtp.example.org"
P2D2_BASE_SMTP_PORT="587"
P2D2_BASE_SMTP_SECURE="false"
P2D2_BASE_SMTP_USER="smtp-user"
P2D2_BASE_CONTACT_EMAIL_TO="admin@example.org"
P2D2_BASE_CONTACT_EMAIL_FROM="noreply@example.org"
P2D2_BASE_ALTCHA_HMAC_KEY="hmac-key"
P2D2_BASE_SMTP_PASS="smtp-pass"
P2D2_BASE_OIDC_ISSUER="https://idm.udp.example.org/realms/cc-prd"
P2D2_DEMO_PASSWORD="DemoPass1"
P2D2_OSM_IDP_CLIENT_ID="osm-client"
P2D2_OSM_IDP_CLIENT_SECRET="osm-secret"
P2D2_GITHUB_TOKEN="gh-token"
P2D2_GITLAB_TOKEN="gl-token"
P2D2_DEMO_ACCOUNTS="false"
P2D2_OSM_IDP_ENABLE="false"
P2D2_MAIN_DB_USER="P2D2-MAIN"
P2D2_MAIN_WFST_WORKSPACE="ws"
P2D2_MAIN_PUBLIC_SITE_URL="https://www.udp.example.org"
P2D2_MAIN_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ws/ows"
P2D2_MAIN_WFST_USERNAME="wfst-user"
P2D2_MAIN_DB_PASSWORD="db-pass"
P2D2_MAIN_WFST_PASSWORD="wfst-pass"
P2D2_MAIN_SESSION_SECRET="session-secret"
P2D2_DEVELOP_DB_USER="P2D2-DEVELOP"
P2D2_DEVELOP_WFST_WORKSPACE="ws"
P2D2_DEVELOP_PUBLIC_SITE_URL="https://dev.udp.example.org"
P2D2_DEVELOP_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ws/ows"
P2D2_DEVELOP_WFST_USERNAME="wfst-user"
P2D2_DEVELOP_DB_PASSWORD="db-pass"
P2D2_DEVELOP_WFST_PASSWORD="wfst-pass"
P2D2_DEVELOP_SESSION_SECRET="session-secret"
P2D2_DE1_DB_USER="P2D2-DE1"
P2D2_DE1_WFST_WORKSPACE="ws"
P2D2_DE1_PUBLIC_SITE_URL="https://f-de1.udp.example.org"
P2D2_DE1_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ws/ows"
P2D2_DE1_WFST_USERNAME="wfst-user"
P2D2_DE1_DB_PASSWORD="db-pass"
P2D2_DE1_WFST_PASSWORD="wfst-pass"
P2D2_DE1_SESSION_SECRET="session-secret"
P2D2_DE2_DB_USER="P2D2-DE2"
P2D2_DE2_WFST_WORKSPACE="ws"
P2D2_DE2_PUBLIC_SITE_URL="https://f-de2.udp.example.org"
P2D2_DE2_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ws/ows"
P2D2_DE2_WFST_USERNAME="wfst-user"
P2D2_DE2_DB_PASSWORD="db-pass"
P2D2_DE2_WFST_PASSWORD="wfst-pass"
P2D2_DE2_SESSION_SECRET="session-secret"
P2D2_FV_DB_USER="P2D2-FV"
P2D2_FV_WFST_WORKSPACE="ws"
P2D2_FV_PUBLIC_SITE_URL="https://f-fv.udp.example.org"
P2D2_FV_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ws/ows"
P2D2_FV_WFST_USERNAME="wfst-user"
P2D2_FV_DB_PASSWORD="db-pass"
P2D2_FV_WFST_PASSWORD="wfst-pass"
P2D2_FV_SESSION_SECRET="session-secret"
ENVEOF
  [[ -n "${2:-}" ]] && printf '%s\n' "$2" >> "$1"
}

# Namespace-Check schlägt fehl → preflight bricht nach dem Laden der Fachmodule ab
# (vor jeder echten Cluster-/SSH-Aktion).
export KUBECTL_MODE="no_ns"
export KUBECONFIG="$T/kubeconfig"

ENVFILE="$T/.env.p2d2-addon"
OUT="$T/out.log"

# 4a: nur DOMAIN_NAME, kein ADDON_DOMAIN → Ableitung vor den Fachmodulen.
write_env "$ENVFILE" ""
( ADDON_CONTEXT=vm ADDON_ENV_FILE="$ENVFILE" bash "$MAIN" ) >"$OUT" 2>&1; rc=$?
check "VM nur DOMAIN_NAME: rc=1 (preflight)" "1" "$rc"
check "VM nur DOMAIN_NAME: addon_validate_config gelaufen" "yes" "$(grep -q 'validiert (Konfigurationsvertrag)' "$OUT" && echo yes || echo no)"
check "VM nur DOMAIN_NAME: preflight erreicht" "yes" "$(grep -q 'Vorprüfung (Fail-Fast)' "$OUT" && echo yes || echo no)"
check "VM nur DOMAIN_NAME: kein Source-Time-Guard" "no" "$(grep -q 'nicht isoliert sourcen' "$OUT" && echo yes || echo no)"

# 4b: abweichendes ADDON_DOMAIN → Validierungsfehler, nicht Source-Time-Fehler.
write_env "$ENVFILE" 'ADDON_DOMAIN="udp.other.org"'
( ADDON_CONTEXT=vm ADDON_ENV_FILE="$ENVFILE" bash "$MAIN" ) >"$OUT" 2>&1; rc=$?
check "abweichendes ADDON_DOMAIN: rc=1" "1" "$rc"
check "abweichendes ADDON_DOMAIN: Validierungsfehler" "yes" "$(grep -q 'ADDON_DOMAIN muss exakt' "$OUT" && echo yes || echo no)"
check "abweichendes ADDON_DOMAIN: kein Source-Time-Guard" "no" "$(grep -q 'nicht isoliert sourcen' "$OUT" && echo yes || echo no)"

# 4c: --uninstall lädt .env + Ableitung ebenfalls (keine volle Validierung).
write_env "$ENVFILE" ""
( ADDON_CONTEXT=vm ADDON_ENV_FILE="$ENVFILE" bash "$MAIN" --uninstall ) >"$OUT" 2>&1; rc=$?
check "VM --uninstall: .env geladen" "yes" "$(grep -q '.env.p2d2-addon geladen' "$OUT" && echo yes || echo no)"
check "VM --uninstall: kein Install-Validierungsfehler" "no" "$(grep -q 'validiert (Konfigurationsvertrag)' "$OUT" && echo yes || echo no)"

rm -rf "$T"

#!/usr/bin/env bash
# Suite 18: addon_30_frontend.sh + addon_01_config.sh — Schritt 2c (Zertifikats-Issuer
# und Sperre). Nur synthetische Werte, kein Cluster/Netz; kubectl/jq über Stubs.

begin_suite "addon_cert_issuer"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"
KUBECTL_CALL_LOG="$T/kubectl.log"
export KUBECTL_CALL_LOG

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
set +e

export ADDON_NS="my-ns"
export ADDON_DOMAIN="udp.example.org"
export ADDON_IAM_NS="cc-prd-access-stack"

# valid_env — synthetische, vollständige Konfiguration für addon_validate_config.
valid_env() {
  export DOMAIN_NAME="example.org"
  export ADDON_DOMAIN="udp.example.org"
  export P2D2_CERT_ISSUER="auto"
  export P2D2_CERT_BLOCK_NEW_REQUESTS="false"
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
  local key site_prefix
  for key in MAIN DEVELOP DE1 DE2 FV; do
    case "${key}" in
      MAIN)    site_prefix="www"   ;;
      DEVELOP) site_prefix="dev"   ;;
      DE1)     site_prefix="f-de1" ;;
      DE2)     site_prefix="f-de2" ;;
      FV)      site_prefix="f-fv"  ;;
    esac
    export "P2D2_${key}_DB_USER=P2D2-${key}"
    export "P2D2_${key}_WFST_WORKSPACE=ws"
    export "P2D2_${key}_PUBLIC_SITE_URL=https://${site_prefix}.udp.example.org"
    export "P2D2_${key}_WFST_ENDPOINT=https://geoportal.udp.example.org/geoserver/ws/ows"
    export "P2D2_${key}_WFST_USERNAME=wfst-user"
    export "P2D2_${key}_DB_PASSWORD=db-pass"
    export "P2D2_${key}_WFST_PASSWORD=wfst-pass"
    export "P2D2_${key}_SESSION_SECRET=session-secret"
  done
}

# ── addon_pick_cert_issuer (U1, rein) ─────────────────────────────────────────
pick()    { addon_pick_cert_issuer "$@" 2>/dev/null; }
pick_rc() { addon_pick_cert_issuer "$@" >/dev/null 2>&1; echo $?; }

check "1 staging einheitlich" "letsencrypt-staging" "$(pick auto letsencrypt-staging letsencrypt-staging)"
check "1 prod einheitlich" "letsencrypt-prod" "$(pick auto letsencrypt-prod letsencrypt-prod)"
check "1 selfsigned einheitlich" "selfsigned-issuer" "$(pick auto selfsigned-issuer selfsigned-issuer)"
check "1 gemischt -> Fehler" "1" "$(pick_rc auto letsencrypt-prod selfsigned-issuer)"
check "1 keine Core-Ingresses -> Fehler" "1" "$(pick_rc auto)"
check "1 fehlende Annotation -> Fehler" "1" "$(pick_rc auto letsencrypt-prod '')"
check "1 explizit überschreibt auto" "letsencrypt-prod" "$(pick letsencrypt-prod)"
check "1 explizit überschreibt gemischt" "letsencrypt-staging" "$(pick letsencrypt-staging letsencrypt-prod letsencrypt-prod)"

# ── addon_cert_is_acme ────────────────────────────────────────────────────────
addon_cert_is_acme letsencrypt-staging; check "2 staging ist ACME" "0" "$?"
addon_cert_is_acme letsencrypt-prod;    check "2 prod ist ACME" "0" "$?"
addon_cert_is_acme selfsigned-issuer;   check "2 selfsigned nicht ACME" "1" "$?"

# ── Stage-Mapping (addon_frontend_host/svc) ───────────────────────────────────
check "3 host main" "www.udp.example.org"   "$(addon_frontend_host main)"
check "3 host dev"  "dev.udp.example.org"   "$(addon_frontend_host dev)"
check "3 host de1"  "f-de1.udp.example.org" "$(addon_frontend_host de1)"
check "3 host de2"  "f-de2.udp.example.org" "$(addon_frontend_host de2)"
check "3 host fv"   "f-fv.udp.example.org"  "$(addon_frontend_host fv)"
check "3 svc main"  "p2d2-main"   "$(addon_frontend_svc main)"
check "3 svc de1"   "p2d2-f-de1"  "$(addon_frontend_svc de1)"

# ── addon_render_ingress (U4, rein) ───────────────────────────────────────────
R="$(addon_render_ingress main selfsigned-issuer)"
check "4 Annotation folgt Parameter" "yes" "$(grep -qF 'cert-manager.io/cluster-issuer: selfsigned-issuer' <<< "$R" && echo yes || echo no)"
check "4 kein festes letsencrypt-prod" "0" "$(grep -cF 'letsencrypt-prod' <<< "$R")"
check "4 secretName" "yes" "$(grep -qF 'secretName: www.udp.example.org-tls' <<< "$R" && echo yes || echo no)"
check "4 namespace ADDON_NS" "yes" "$(grep -qF 'namespace: my-ns' <<< "$R" && echo yes || echo no)"
check "4 host" "yes" "$(grep -qF 'host: www.udp.example.org' <<< "$R" && echo yes || echo no)"

# ── addon_ensure_cert_issuer_ready (U2, Stub) ────────────────────────────────
: > "$KUBECTL_CALL_LOG"
export KUBECTL_MODE="ok"
addon_ensure_cert_issuer_ready letsencrypt-prod >/dev/null 2>&1; rc=$?
check "5 nicht Ready -> Fehler" "1" "$rc"
export KUBECTL_MODE="no_clusterissuer"
addon_ensure_cert_issuer_ready letsencrypt-prod >/dev/null 2>&1; rc=$?
check "5 fehlt -> Fehler" "1" "$rc"
export KUBECTL_MODE="issuer_ready"
addon_ensure_cert_issuer_ready letsencrypt-prod >/dev/null 2>&1; rc=$?
check "5 Ready -> ok" "0" "$rc"
check "5 kein create/apply ClusterIssuer" "0" \
  "$(grep -cE 'create clusterissuer|apply .*clusterissuer' "$KUBECTL_CALL_LOG")"
export KUBECTL_MODE="ok"

# ── Validierung (U6, addon_validate_config) ───────────────────────────────────
rc_of() { ( valid_env; "$@"; addon_validate_config >/dev/null 2>&1; echo $? ); }
check "6 auto/false valid" "0" "$(rc_of true)"
check "6 explicit selfsigned valid" "0" "$(rc_of export P2D2_CERT_ISSUER='selfsigned-issuer')"
check "6 ungültiger Issuer Fehler" "1" "$(rc_of export P2D2_CERT_ISSUER='letsencrypt')"
check "6 ungültige Sperre Fehler" "1" "$(rc_of export P2D2_CERT_BLOCK_NEW_REQUESTS='maybe')"

# ── Statisch: Modul legt nie einen ClusterIssuer an ───────────────────────────
MODULE="$REPO/modules_addon_V1s/addon_30_frontend.sh"
check "7 Modul ohne create clusterissuer" "0" "$(grep -cE 'create clusterissuer' "$MODULE")"
check "7 Modul ohne apply clusterissuer" "0" "$(grep -cE 'apply .*clusterissuer' "$MODULE")"
check "7 Literal letsencrypt-prod nur als Auflösung" "yes" \
  "$(grep -qE 'letsencrypt-prod\)' "$MODULE" && echo yes || echo no)"

rm -rf "$T"

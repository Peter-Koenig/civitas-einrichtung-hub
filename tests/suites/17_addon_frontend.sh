#!/usr/bin/env bash
# Suite 17: addon_30_frontend.sh + addon_01_config.sh — Schritt 2b (Domain,
# ConfigMaps, Manifeste, Image-Tags). Nur synthetische Testwerte, kein Cluster/Netz.

begin_suite "addon_frontend"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
set +e

# set_env <domain> — synthetische Umgebung (keine echten Betreiberdaten).
set_env() {
  local domain="${1:-example.org}"
  export DOMAIN_NAME="${domain}"
  export ADDON_NS="my-ns"
  unset ADDON_DOMAIN

  export P2D2_BASE_APP_DEBUG="false"
  export P2D2_BASE_DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"
  export P2D2_BASE_DB_HOST="central-db.svc.cluster.local"
  export P2D2_BASE_DB_PORT="5432"
  export P2D2_BASE_DB_NAME="p2d2"
  export P2D2_BASE_WFST_NAMESPACE="urn:example:govdata"
  export P2D2_BASE_PUBLIC_WFST_ENDPOINT="https://geoportal.udp.${domain}/geoserver/ows"
  export P2D2_BASE_PUBLIC_MAPSERVER_URL="https://geoportal.udp.${domain}/mapserver"
  export P2D2_BASE_SMTP_HOST="smtp.example.org"
  export P2D2_BASE_SMTP_PORT="587"
  export P2D2_BASE_SMTP_SECURE="false"
  export P2D2_BASE_SMTP_USER="smtp-user"
  export P2D2_BASE_CONTACT_EMAIL_TO="admin@example.org"
  export P2D2_BASE_CONTACT_EMAIL_FROM="noreply@example.org"

  # Secrets (F1: dürfen nie in ConfigMaps/Hash auftauchen).
  export P2D2_BASE_ALTCHA_HMAC_KEY="SECRET-HMAC-VALUE"
  export P2D2_BASE_SMTP_PASS="SECRET-SMTP-PASS"
  export P2D2_BASE_OIDC_ISSUER="https://idm.udp.${domain}/realms/cc-prd"
  export P2D2_BASE_OIDC_CLIENT_ID="SECRET-OIDC-CLIENT"
  export P2D2_BASE_OIDC_CLIENT_SECRET="SECRET-OIDC-SECRET"

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
    export "P2D2_${key}_WFST_WORKSPACE=ws-${key}"
    export "P2D2_${key}_PUBLIC_SITE_URL=https://${site_prefix}.udp.${domain}"
    export "P2D2_${key}_WFST_ENDPOINT=https://geoportal.udp.${domain}/geoserver/ws-${key}/ows"
    export "P2D2_${key}_WFST_USERNAME=wfst-user-${key}"
    export "P2D2_${key}_DB_PASSWORD=SECRET-DB-PASS-${key}"
    export "P2D2_${key}_WFST_PASSWORD=SECRET-WFST-PASS-${key}"
    export "P2D2_${key}_SESSION_SECRET=SECRET-SESSION-${key}"
  done
}

set_env "example.org"

# ── Domainableitung (B1) ─────────────────────────────────────────────────────
check "1 leer -> udp.\${DOMAIN_NAME}" "udp.example.org" \
  "$( ( set_env; unset ADDON_DOMAIN; addon_derive_domain; echo "${ADDON_DOMAIN:-}" ) )"
check "1 explizit -> unverändert" "udp.custom.org" \
  "$( ( set_env; export ADDON_DOMAIN='udp.custom.org'; addon_derive_domain; echo "${ADDON_DOMAIN:-}" ) )"
check "1 kein DOMAIN_NAME -> leer" "" \
  "$( ( set_env; unset ADDON_DOMAIN; unset DOMAIN_NAME; addon_derive_domain; echo "${ADDON_DOMAIN:-}" ) )"
check "1 kein data-dna-Default" "yes" \
  "$( ( set_env; unset ADDON_DOMAIN; unset DOMAIN_NAME; addon_derive_domain; [[ "${ADDON_DOMAIN:-}" != *data-dna* ]] && echo yes || echo no ) )"

# ── Stage-Key-Mapping ─────────────────────────────────────────────────────────
check "2 main->MAIN"    "MAIN"    "$(addon_stage_key main)"
check "2 dev->DEVELOP"  "DEVELOP" "$(addon_stage_key dev)"
check "2 de1->DE1"      "DE1"     "$(addon_stage_key de1)"
check "2 de2->DE2"      "DE2"     "$(addon_stage_key de2)"
check "2 fv->FV"        "FV"      "$(addon_stage_key fv)"

# ── Basis-ConfigMap (F1/F2) ──────────────────────────────────────────────────
BASE_CM="$(addon_configmap_base)"
check "3 Basis-Name" "yes" "$(grep -qF 'name: p2d2-base-config' <<< "$BASE_CM" && echo yes || echo no)"
check "3 Basis-Namespace=ADDON_NS" "yes" "$(grep -qF 'namespace: my-ns' <<< "$BASE_CM" && echo yes || echo no)"
check "3 Basis-Label" "yes" "$(grep -qF 'app.kubernetes.io/managed-by: p2d2-addon' <<< "$BASE_CM" && echo yes || echo no)"
# Alle 14 Allowlist-Keys vorhanden.
for k in APP_DEBUG DEFAULT_CATEGORY_ICON DB_HOST DB_PORT DB_NAME WFST_NAMESPACE \
         PUBLIC_WFST_ENDPOINT PUBLIC_MAPSERVER_URL SMTP_HOST SMTP_PORT SMTP_SECURE \
         SMTP_USER CONTACT_EMAIL_TO CONTACT_EMAIL_FROM; do
  check "3 Basis-Key ${k}" "yes" "$(grep -qE "^  ${k}:" <<< "$BASE_CM" && echo yes || echo no)"
done
# Keine Secrets (F1): weder Secret-Namen noch Secret-Werte.
check "3 kein ALTCHA_HMAC_KEY" "0" "$(grep -cF 'ALTCHA_HMAC_KEY' <<< "$BASE_CM")"
check "3 kein SMTP_PASS" "0" "$(grep -cF 'SMTP_PASS' <<< "$BASE_CM")"
check "3 kein OIDC" "0" "$(grep -cF 'OIDC' <<< "$BASE_CM")"
check "3 kein Secret-Wert" "0" "$(grep -cF 'SECRET-' <<< "$BASE_CM")"
check "3 deterministisch" "yes" "$([[ "$(addon_configmap_base)" == "$BASE_CM" ]] && echo yes || echo no)"

# ── Stage-ConfigMap (B4/B8, F2) ──────────────────────────────────────────────
STAGE_CM="$(addon_configmap_stage MAIN)"
check "4 Stage-Name" "yes" "$(grep -qF 'name: p2d2-main-config' <<< "$STAGE_CM" && echo yes || echo no)"
check "4 Stage-Namespace" "yes" "$(grep -qF 'namespace: my-ns' <<< "$STAGE_CM" && echo yes || echo no)"
for k in DB_USER WFST_WORKSPACE PUBLIC_WFST_WORKSPACE PUBLIC_SITE_URL WFST_ENDPOINT \
         WFST_ENDPOINT_MAIN WFST_USERNAME WFST_USER_MAIN; do
  check "4 Stage-Key ${k}" "yes" "$(grep -qE "^  ${k}:" <<< "$STAGE_CM" && echo yes || echo no)"
done
check "4 PUBLIC_WFST_WORKSPACE==WFST_WORKSPACE" "yes" \
  "$(grep -qE '^  PUBLIC_WFST_WORKSPACE: "ws-MAIN"' <<< "$STAGE_CM" && echo yes || echo no)"
check "4 kein Secret-Wert" "0" "$(grep -cF 'SECRET-' <<< "$STAGE_CM")"
check "4 deterministisch" "yes" "$([[ "$(addon_configmap_stage MAIN)" == "$STAGE_CM" ]] && echo yes || echo no)"

# Stage-Namen B8 für alle Stages.
check "4 dev-Name"  "yes" "$(grep -qF 'name: p2d2-dev-config'   <<< "$(addon_configmap_stage DEVELOP)" && echo yes || echo no)"
check "4 de1-Name"  "yes" "$(grep -qF 'name: p2d2-f-de1-config' <<< "$(addon_configmap_stage DE1)" && echo yes || echo no)"
check "4 de2-Name"  "yes" "$(grep -qF 'name: p2d2-f-de2-config' <<< "$(addon_configmap_stage DE2)" && echo yes || echo no)"
check "4 fv-Name"   "yes" "$(grep -qF 'name: p2d2-f-fv-config'  <<< "$(addon_configmap_stage FV)" && echo yes || echo no)"

# ── Quotierung (Wert mit Doppelpunkt, #, Leerzeichen, Anführungszeichen) ─────
export P2D2_BASE_DEFAULT_CATEGORY_ICON='A "weird" #icon.svg'
QUOTED="$(addon_configmap_base)"
check "5 Quotierung" "yes" "$(grep -qF 'DEFAULT_CATEGORY_ICON: "A \"weird\" #icon.svg"' <<< "$QUOTED" && echo yes || echo no)"
set_env "example.org"

# ── ConfigMap-Hash (F3) ───────────────────────────────────────────────────────
H1="$(addon_configmap_hash MAIN)"
H2="$(addon_configmap_hash MAIN)"
check "6 Hash deterministisch" "yes" "$([[ "$H1" == "$H2" ]] && echo yes || echo no)"
export P2D2_MAIN_PUBLIC_SITE_URL="https://www.changed.org"
H3="$(addon_configmap_hash MAIN)"
check "6 Hash ändert sich bei ConfigMap-Änderung" "yes" "$([[ "$H1" != "$H3" ]] && echo yes || echo no)"
set_env "example.org"

# ── Image-Tag (F4) ────────────────────────────────────────────────────────────
tag_args() {
  addon_compute_image_tag "$@"
}
TAG_BASE=( "de1" "github.com" "Peter-Koenig/p2d2-hub.git" "feature/team-de1/main" \
  "commit-abc" "script-sha" "build:de1" \
  "https://f-de1.udp.example.org" "https://geoportal.udp.example.org/geoserver/ows" \
  "de1" "https://geoportal.udp.example.org/mapserver" "Fahnenmasten.svg" )
T1="$(tag_args "${TAG_BASE[@]}")"
check "7 Format cfg-<12-hex>" "yes" "$(grep -Eq '^cfg-[0-9a-f]{12}$' <<< "$T1" && echo yes || echo no)"
check "7 deterministisch" "yes" "$([[ "$(tag_args "${TAG_BASE[@]}")" == "$T1" ]] && echo yes || echo no)"
check "7 Stage-Änderung -> anderer Tag" "yes" "$([[ "$(tag_args "de2" "${TAG_BASE[@]:1}")" != "$T1" ]] && echo yes || echo no)"
check "7 Commit-Änderung -> anderer Tag" "yes" "$([[ "$(tag_args "de1" "github.com" "Peter-Koenig/p2d2-hub.git" "feature/team-de1/main" "commit-xyz" "script-sha" "build:de1" "https://f-de1.udp.example.org" "https://geoportal.udp.example.org/geoserver/ows" "de1" "https://geoportal.udp.example.org/mapserver" "Fahnenmasten.svg")" != "$T1" ]] && echo yes || echo no)"
check "7 Skript-Hash-Änderung -> anderer Tag" "yes" "$([[ "$(tag_args "de1" "github.com" "Peter-Koenig/p2d2-hub.git" "feature/team-de1/main" "commit-abc" "other-sha" "build:de1" "https://f-de1.udp.example.org" "https://geoportal.udp.example.org/geoserver/ows" "de1" "https://geoportal.udp.example.org/mapserver" "Fahnenmasten.svg")" != "$T1" ]] && echo yes || echo no)"
check "7 Buildwert-Änderung -> anderer Tag" "yes" "$([[ "$(tag_args "de1" "github.com" "Peter-Koenig/p2d2-hub.git" "feature/team-de1/main" "commit-abc" "script-sha" "build:de1" "https://f-de1.udp.example.org" "https://geoportal.udp.example.org/geoserver/ows" "de1" "https://geoportal.udp.example.org/mapserver" "Other.svg")" != "$T1" ]] && echo yes || echo no)"
# Secret-Änderung (Env) ändert den Tag nicht (Funktion liest keine Env).
export P2D2_DE1_DB_PASSWORD="SECRET-CHANGED"
check "7 Secret-Änderung -> gleicher Tag" "yes" "$([[ "$(tag_args "${TAG_BASE[@]}")" == "$T1" ]] && echo yes || echo no)"
set_env "example.org"

# ── Rendering (B2/B6, F3/F6) ──────────────────────────────────────────────────
TPL="$REPO/overlay_addon_V1s/k8s/stages/de1.yaml"
RENDERED="$(addon_render_stage_manifest "$TPL" "my-ns" "p2d2-frontend-de1:cfg-abcdef123456" "hash123")"
check "8 kein fester Tag" "0" "$(grep -cF 'v1s-2026-09-18' <<< "$RENDERED")"
check "8 kein fester Namespace" "0" "$(grep -cF 'cc-prd-geodata-stack' <<< "$RENDERED")"
check "8 kein Platzhalter IMAGE" "0" "$(grep -cF '__P2D2_IMAGE__' <<< "$RENDERED")"
check "8 kein Platzhalter NAMESPACE" "0" "$(grep -cF '__P2D2_NAMESPACE__' <<< "$RENDERED")"
check "8 kein Platzhalter HASH" "0" "$(grep -cF '__P2D2_CONFIG_HASH__' <<< "$RENDERED")"
check "8 Image ersetzt" "yes" "$(grep -qF 'image: p2d2-frontend-de1:cfg-abcdef123456' <<< "$RENDERED" && echo yes || echo no)"
check "8 Namespace ersetzt" "yes" "$(grep -qF 'namespace: my-ns' <<< "$RENDERED" && echo yes || echo no)"
check "8 Hash-Annotation" "yes" "$(grep -qF 'p2d2-addon/config-hash: "hash123"' <<< "$RENDERED" && echo yes || echo no)"

# ── Gegenprobe projekte-koenig.eu: keine data-dna.eu-Referenz ─────────────────
set_env "projekte-koenig.eu"
addon_derive_domain
PK_CM="$(addon_configmap_base; addon_configmap_stage MAIN)"
PK_RENDER="$(addon_render_stage_manifest "$TPL" "my-ns" "p2d2-frontend-de1:cfg-abcdef123456" "hash123")"
check "9 ConfigMap ohne data-dna.eu" "0" "$(grep -cF 'data-dna.eu' <<< "$PK_CM")"
check "9 Rendering ohne data-dna.eu" "0" "$(grep -cF 'data-dna.eu' <<< "$PK_RENDER")"
check "9 ADDON_DOMAIN abgeleitet" "udp.projekte-koenig.eu" "${ADDON_DOMAIN:-}"
set_env "example.org"

# ── Fail-fast: Stage-Manifest fehlt Platzhalter nicht (statisch) ─────────────
check "10 Manifest ist Template (kein hartes Image)" "0" \
  "$(grep -cE 'image: p2d2-frontend-[a-z0-9-]+:' "$TPL")"

rm -rf "$T"

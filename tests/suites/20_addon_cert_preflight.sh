#!/usr/bin/env bash
# Suite 20: addon_30_frontend.sh + preflight_addon — Schritt 2c-3 Korrekturen
# (F1/F2: Issuer + Sperre im Preflight). Nur synthetische Werte, kubectl gemockt.

begin_suite "addon_cert_preflight"

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

export ADDON_NS="my-ns"
export ADDON_DOMAIN="udp.example.org"

# ── kubectl-Mock ──────────────────────────────────────────────────────────────
KUBECTL_CALLS=()
INGRESS_EXISTS=0        # 0 = vorhanden, 1 = fehlt
CLUSTERISSUER_EXISTS=0  # 0 = vorhanden, 1 = fehlt
CLUSTERISSUER_READY="True"
MISSING_TLS_SECRET=""   # Secret-Name, der als fehlend gilt
kubectl() {
  KUBECTL_CALLS+=("$*")
  case "$*" in
    *"get ingress"*) return "$INGRESS_EXISTS" ;;
    *"get secret"*)
      if [[ -n "$MISSING_TLS_SECRET" && "$*" == *"$MISSING_TLS_SECRET"* ]]; then
        return 1
      fi
      return 0 ;;
    *"get clusterissuer"*"-o jsonpath"*) printf '%s' "$CLUSTERISSUER_READY"; return 0 ;;
    *"get clusterissuer"*) return "$CLUSTERISSUER_EXISTS" ;;
    *"get namespace"*) return 0 ;;
    *) return 0 ;;
  esac
}

reset_case() {
  KUBECTL_CALLS=()
  INGRESS_EXISTS=0
  CLUSTERISSUER_EXISTS=0
  CLUSTERISSUER_READY="True"
  MISSING_TLS_SECRET=""
  unset ADDON_CERT_ISSUER_RESOLVED
  export P2D2_CERT_ISSUER="letsencrypt-prod"
  export P2D2_CERT_BLOCK_NEW_REQUESTS="false"
}

# ── addon_preflight_cert_issuer (F1) ─────────────────────────────────────────
reset_case
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "1 Ready -> rc 0" "0" "$rc"
check "1 exportiert ADDON_CERT_ISSUER_RESOLVED" "letsencrypt-prod" "${ADDON_CERT_ISSUER_RESOLVED:-}"

reset_case; CLUSTERISSUER_READY=""
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "2 nicht Ready -> Fehler" "1" "$rc"

reset_case; CLUSTERISSUER_EXISTS=1
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "3 ClusterIssuer fehlt -> Fehler" "1" "$rc"

reset_case; P2D2_CERT_BLOCK_NEW_REQUESTS="true"; INGRESS_EXISTS=1; MISSING_TLS_SECRET="www.udp.example.org-tls"
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "4 Sperre ACME ohne Secret -> Fehler" "1" "$rc"
check "4 Hostliste im Fehler" "yes" "$(grep -qF 'TLS-Secret fehlt für:' "$LOGBUF" && echo yes || echo no)"
check "4 kein apply/create im Preflight" "0" "$(printf '%s\n' "${KUBECTL_CALLS[@]}" | grep -cE 'apply|create')"

reset_case; P2D2_CERT_BLOCK_NEW_REQUESTS="true"; P2D2_CERT_ISSUER="selfsigned-issuer"; INGRESS_EXISTS=1; MISSING_TLS_SECRET="www.udp.example.org-tls"
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "5 selfsigned -> weiter" "0" "$rc"

reset_case; P2D2_CERT_BLOCK_NEW_REQUESTS="true"; INGRESS_EXISTS=0; MISSING_TLS_SECRET="www.udp.example.org-tls"
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "6 vorhandener Ingress -> nicht blockiert" "0" "$rc"

reset_case; P2D2_CERT_BLOCK_NEW_REQUESTS="true"; INGRESS_EXISTS=1; MISSING_TLS_SECRET="www.udp.example.org-tls"
addon_preflight_cert_issuer >/dev/null 2>&1; rc=$?
check "7 alles-oder-nichts: ein Host ohne Secret -> Fehler" "1" "$rc"

# ── addon_install_cert_issuer (F1) ───────────────────────────────────────────
RESOLVE_MARKER="$T/resolve_called"
addon_resolve_cert_issuer() { touch "$RESOLVE_MARKER"; printf 'letsencrypt-prod'; }
reset_case; rm -f "$RESOLVE_MARKER"; export ADDON_CERT_ISSUER_RESOLVED="letsencrypt-prod"
check "8 nutzt ADDON_CERT_ISSUER_RESOLVED" "letsencrypt-prod" "$(addon_install_cert_issuer 2>/dev/null)"
check "8 keine erneute Auflösung" "no" "$([[ -e "$RESOLVE_MARKER" ]] && echo yes || echo no)"
reset_case; rm -f "$RESOLVE_MARKER"; unset ADDON_CERT_ISSUER_RESOLVED
check "9 ohne Variable selbst auflösen" "letsencrypt-prod" "$(addon_install_cert_issuer 2>/dev/null)"
check "9 Auflösung erfolgt" "yes" "$([[ -e "$RESOLVE_MARKER" ]] && echo yes || echo no)"

# ── ensure_addon_frontend_ingress: Sperre -> Rückgabewert 2 (F2) ─────────────
reset_case; P2D2_CERT_BLOCK_NEW_REQUESTS="true"; INGRESS_EXISTS=1; MISSING_TLS_SECRET="www.udp.example.org-tls"
ensure_addon_frontend_ingress main letsencrypt-prod >/dev/null 2>&1; rc=$?
check "10 Sperre in ensure -> 2" "2" "$rc"

# ── addon_clear_frontend_tags (U7a unter set -euo pipefail) ──────────────────
addon_clear_frontend_tags "$T/no-such-dir"; rc=$?
check "11 kein Treffer -> kein Abbruch" "0" "$rc"
mkdir -p "$T/tags"; touch "$T/tags/.frontend-tag-main"
addon_clear_frontend_tags "$T/tags"; rc=$?
check "11 mit Datei -> kein Abbruch" "0" "$rc"
check "11 Datei gelöscht" "no" "$([[ -e "$T/tags/.frontend-tag-main" ]] && echo yes || echo no)"

# ── Statisch: preflight_addon ruft die Issuer-Prüfung nur im Install-Zweig ───
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"
check "12 preflight ruft addon_preflight_cert_issuer" "yes" "$(grep -qF 'addon_preflight_cert_issuer' "$MAIN" && echo yes || echo no)"

rm -rf "$T"

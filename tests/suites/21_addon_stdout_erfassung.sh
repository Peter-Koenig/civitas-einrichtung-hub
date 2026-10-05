#!/usr/bin/env bash
# Suite 21: Korrekturen zu Turn 11 — stdout-Erfassung (G1), Rückgabewerte (G3),
# Preflight-Extraktion (G4). Log-Funktionen wie im Hauptskript (stdout/stderr).

begin_suite "addon_stdout_erfassung"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"

# Log-Funktionen exakt wie im Hauptskript: log/log_ok -> stdout, log_warn/log_error -> stderr.
log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ── kubectl-Mock (für Preflight-Tests) ───────────────────────────────────────
INGRESS_EXISTS=0
CLUSTERISSUER_EXISTS=0
CLUSTERISSUER_READY="True"
MISSING_SECRETS=""
kubectl() {
  case "$*" in
    *"get ingress"*) return "$INGRESS_EXISTS" ;;
    *"get secret"*)
      local s
      for s in $MISSING_SECRETS; do
        [[ "$*" == *"$s"* ]] && return 1
      done
      return 0 ;;
    *"get clusterissuer"*"-o jsonpath"*) printf '%s' "$CLUSTERISSUER_READY"; return 0 ;;
    *"get clusterissuer"*) return "$CLUSTERISSUER_EXISTS" ;;
    *"get namespace"*) return 0 ;;
    *) return 0 ;;
  esac
}

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
set +e

export ADDON_NS="my-ns"
export ADDON_DOMAIN="udp.example.org"

# ── B1: addon_install_cert_issuer liefert nur den Wert ───────────────────────
export ADDON_CERT_ISSUER_RESOLVED="selfsigned-issuer"
x="$(addon_install_cert_issuer)"
check "1 preflight-Zweig: reiner Wert" "selfsigned-issuer" "$x"
check "1 kein Log-Text im Wert" "0" "$(grep -cF '[' <<< "$x")"

unset ADDON_CERT_ISSUER_RESOLVED
addon_resolve_cert_issuer() { printf 'letsencrypt-staging'; }
x="$(addon_install_cert_issuer)"
check "1 fallback-Zweig: reiner Wert" "letsencrypt-staging" "$x"

# ── Rendering: Issuer genau einmal, kein '[' ─────────────────────────────────
R="$(addon_render_ingress main letsencrypt-prod)"
check "2 Issuer genau einmal" "1" "$(grep -cF 'cert-manager.io/cluster-issuer: letsencrypt-prod' <<< "$R")"
check "2 kein '[' im Manifest" "0" "$(grep -cF '[' <<< "$R")"

# ── install_addon_frontend: Rückgabewerte (G3) ───────────────────────────────
apply_addon_secrets() { return 0; }
addon_configmap_base() { :; }
addon_configmap_stage() { :; }
addon_configmap_hash() { printf 'hash'; }
addon_render_stage_manifest() { printf 'yaml'; }
addon_install_cert_issuer() { printf 'letsencrypt-prod'; }
addon_ensure_cert_issuer_ready() { return 0; }
INGRESS_RC=0
ensure_addon_frontend_ingress() { return "$INGRESS_RC"; }

export VM_REMOTE_INSTALL_DIR="$T/tags"
mkdir -p "$VM_REMOTE_INSTALL_DIR"
for st in main dev de1 de2 fv; do echo "cfg-deadbeef0001" > "$VM_REMOTE_INSTALL_DIR/.frontend-tag-$st"; done

rc_install() { INGRESS_RC="$1"; ( install_addon_frontend >/dev/null 2>&1; echo $? ); }

check "3 ensure=2 -> install 2" "2" "$(rc_install 2)"
check "3 ensure=3 -> install 3" "3" "$(rc_install 3)"
check "3 ensure=0 -> install 0" "0" "$(rc_install 0)"

ERR="$T/err.log"
INGRESS_RC=1
install_addon_frontend >/dev/null 2>"$ERR"; rc=$?
check "3 ensure=1 -> weiter (rc 0)" "0" "$rc"
check "3 ehrliche Abschlussmeldung" "yes" "$(grep -qF 'Ingress fehlt für:' "$ERR" && echo yes || echo no)"

# ── keep_mode-Wert (G2) ──────────────────────────────────────────────────────
keep_mode="$(addon_validate_uninstall_keep_tls)"
check "4 keep_mode reiner Wert" "auto" "$keep_mode"

# ── Alles-oder-nichts mit zwei fehlenden Hosts ───────────────────────────────
export P2D2_CERT_ISSUER="letsencrypt-prod"
export P2D2_CERT_BLOCK_NEW_REQUESTS="true"
INGRESS_EXISTS=1
MISSING_SECRETS="www.udp.example.org-tls dev.udp.example.org-tls"
LOGF="$T/preflight.log"
# shellcheck disable=SC2218  # Funktion kommt aus dem gesourcten Modul
addon_preflight_cert_issuer >"$LOGF" 2>&1; rc=$?
check "5 zwei fehlende Hosts -> Fehler" "1" "$rc"
check "5 beide Hosts genannt" "yes" "$(grep -qF 'www.udp.example.org' "$LOGF" && grep -qF 'dev.udp.example.org' "$LOGF" && echo yes || echo no)"

# ── preflight_addon: Install vs. --uninstall (G4-Extraktion) ─────────────────
_preflight_masterportal() { return 0; }
_preflight_portal() { return 0; }
CERT_PREFLIGHT_CALLED=0
addon_preflight_cert_issuer() { CERT_PREFLIGHT_CALLED=$((CERT_PREFLIGHT_CALLED + 1)); return 0; }
# Funktionsgrenzen aus dem Hauptskript extrahieren (ohne es umzubauen).
eval "$(awk '/^preflight_addon\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$MAIN")"

CERT_PREFLIGHT_CALLED=0
preflight_addon "" >/dev/null 2>&1
check "6 Install ruft cert preflight" "1" "$CERT_PREFLIGHT_CALLED"

CERT_PREFLIGHT_CALLED=0
preflight_addon "--uninstall" >/dev/null 2>&1
check "6 --uninstall ruft cert preflight nicht" "0" "$CERT_PREFLIGHT_CALLED"

# ── Statisch: Log-Funktionen des Hauptskripts (stdout/stderr) ────────────────
check "7 main log_ok -> stdout" "0" "$(grep -c '^log_ok().*>&2' "$MAIN")"
check "7 main log_error -> stderr" "1" "$(grep -c '^log_error().*>&2' "$MAIN")"

rm -rf "$T"

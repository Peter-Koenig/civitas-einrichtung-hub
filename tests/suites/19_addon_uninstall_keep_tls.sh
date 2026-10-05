#!/usr/bin/env bash
# Suite 19: addon_30_frontend.sh + addon_01_config.sh — Schritt 2c-3 (Uninstall
# behält TLS-Secrets). Nur synthetische Werte, kein Cluster/Netz.

begin_suite "addon_uninstall_keep_tls"

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

# ── addon_tls_provenance (rein) ───────────────────────────────────────────────
check "1 acme via annotation staging" "acme" "$(addon_tls_provenance letsencrypt-staging '')"
check "1 acme via annotation prod" "acme" "$(addon_tls_provenance letsencrypt-prod '')"
check "1 selfsigned via annotation" "selfsigned" "$(addon_tls_provenance selfsigned-issuer '')"
check "1 bootstrap-selfsigned via annotation" "selfsigned" "$(addon_tls_provenance civitas-bootstrap-selfsigned '')"
LE_ISSUER="issuer=O = Let's Encrypt, CN = R11"
check "1 acme via openssl fallback" "acme" "$(addon_tls_provenance '' "$LE_ISSUER")"
check "1 unbekannter Aussteller -> unknown" "unknown" "$(addon_tls_provenance '' 'issuer=CN = Self-Signed')"
check "1 gar nichts -> unknown" "unknown" "$(addon_tls_provenance '' '')"

# ── addon_uninstall_keep_tls (rein) ───────────────────────────────────────────
addon_uninstall_keep_tls auto acme;        check "2 auto+acme -> behalten" "0" "$?"
addon_uninstall_keep_tls auto selfsigned;  check "2 auto+selfsigned -> löschen" "1" "$?"
addon_uninstall_keep_tls auto unknown;     check "2 auto+unknown -> löschen" "1" "$?"
addon_uninstall_keep_tls true acme;        check "2 true -> behalten" "0" "$?"
addon_uninstall_keep_tls true selfsigned;  check "2 true+selfsigned -> behalten" "0" "$?"
addon_uninstall_keep_tls false acme;       check "2 false -> löschen" "1" "$?"
addon_uninstall_keep_tls false selfsigned; check "2 false+selfsigned -> löschen" "1" "$?"

# ── Enum-Prüfung (Uninstall-Pfad, V6) ────────────────────────────────────────
check "3 auto valid" "auto" "$( ( unset P2D2_UNINSTALL_KEEP_TLS; addon_validate_uninstall_keep_tls ) )"
check "3 true valid" "true" "$( ( export P2D2_UNINSTALL_KEEP_TLS=true; addon_validate_uninstall_keep_tls ) )"
check "3 false valid" "false" "$( ( export P2D2_UNINSTALL_KEEP_TLS=false; addon_validate_uninstall_keep_tls ) )"
check "3 ungültig -> Fehler" "1" "$( ( export P2D2_UNINSTALL_KEEP_TLS=maybe; addon_validate_uninstall_keep_tls >/dev/null 2>&1; echo $? ) )"

# ── Statisch: Ingress + Certificate werden gelöscht (V2) ─────────────────────
MODULE="$REPO/modules_addon_V1s/addon_30_frontend.sh"
check "4 Ingress-Löschung vorhanden" "yes" "$(grep -qF 'delete ingress' "$MODULE" && echo yes || echo no)"
check "4 Certificate-Löschung vorhanden" "yes" "$(grep -qF 'delete certificate' "$MODULE" && echo yes || echo no)"
check "4 TLS-Secret nur als <host>-tls" "yes" "$(grep -qF 'tls_secret="${host}-tls"' "$MODULE" && echo yes || echo no)"

# ── Statisch: keine Zertifikatsinhalte in Logs (V3) ──────────────────────────
check "5 cert_pem nie im Log" "0" "$(grep -cE '(log_ok|log|log_warn|log_error).*cert_pem' "$MODULE")"
check "5 nur Aussteller/Ablauf im Log" "yes" "$(grep -qF 'Aussteller: ${issuer:-unbekannt}' "$MODULE" && echo yes || echo no)"

# ── verify-uninstall.sh: KEEP_TLS-Handhabung vorhanden ───────────────────────
VUS="$REPO/supplement/verify-uninstall.sh"
check "6 verify: KEEP_TLS Default" "yes" "$(grep -qF 'KEEP_TLS="${KEEP_TLS:-auto}"' "$VUS" && echo yes || echo no)"
check "6 verify: strikt bei false" "yes" "$(grep -qF 'KEEP_TLS=false — Rest' "$VUS" && echo yes || echo no)"
check "6 verify: bewusst behalten sonst" "yes" "$(grep -qF 'bewusst behalten, KEEP_TLS=' "$VUS" && echo yes || echo no)"

rm -rf "$T"

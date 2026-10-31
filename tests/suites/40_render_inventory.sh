#!/usr/bin/env bash
# Suite 40: render_inventory — Escaping (Punkte 6+7).
# Feindliche Werte (a&b|c\d"e$f) dürfen Inventory und Credentials nicht
# verfälschen; ein Zeilenumbruch muss zum Abbruch führen.

begin_suite "render_inventory"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)

HOSTILE='a&b|c\d"e$f'

# Führt render_inventory in einer isolierten Umgebung aus. 01_config/02_lib/
# 06_civitas werden nur hier (Subshell) gesourct, damit das `check` der
# Harness nicht überschrieben wird.
# $1 = SMTP_PASS-Wert, $2 = TENANT_ADMIN_PASS-Wert, $3 = Label.
run_render() {
  local smtp="$1" tenant="$2" label="$3"
  (
    set -euo pipefail
    export DOMAIN_NAME=example.org SMTP_HOST=h SMTP_USER=u \
           ADMIN_PASS='Aa1!aaaaaaaa' WG_ENABLE=false
    export SMTP_PASS="$smtp"
    export TENANT_ADMIN_PASS="$tenant"
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/01_config.sh"
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/02_lib.sh"
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/06_civitas.sh"
    # Overrides NACH config: 01_config.sh setzt CC_CLI_PLAYBOOK_DIR fest.
    export SCRIPT_DIR="$T/script-$label"
    export CC_CLI_PLAYBOOK_DIR="$T/playbook-$label"
    export CREDENTIALS_OUTPUT_PATH="$T/credentials-$label.env"
    mkdir -p "$SCRIPT_DIR/templates_V1s"
    printf '%s\n' \
      '---' \
      'smtp:' \
      '  password: "PLACEHOLDER_SMTP_PASS"' \
      'tenant:' \
      '  password: "PLACEHOLDER_TENANT_ADMIN_PASSWORD"' \
      > "$SCRIPT_DIR/templates_V1s/inventory.yml.tpl"
    render_inventory
  )
}

# ── 1) Normaler Lauf mit feindlichen Werten ───────────────────────────────────
run_render "$HOSTILE" "$HOSTILE" norm >"$T/norm.log" 2>&1; rc=$?
check "render_inventory rc=0" "0" "$rc"
OUT="$T/playbook-norm/cc_cli_inventory.yml"
CRED="$T/credentials-norm.env"
check "Inventory erzeugt" "yes" "$([[ -f "$OUT" ]] && echo yes || echo no)"
check "kein PLACEHOLDER_-Rest" "no" "$(grep -q 'PLACEHOLDER_' "$OUT" 2>/dev/null && echo yes || echo no)"

# ── 2) YAML-Parse liefert den Rohwert (nur mikefarah-yq, sonst SKIP) ─────────
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q mikefarah; then
  smtp_val="$(yq eval '.smtp.password' "$OUT" 2>/dev/null || true)"
  check "YAML smtp.password == Rohwert" "$HOSTILE" "$smtp_val"
  tenant_val="$(yq eval '.tenant.password' "$OUT" 2>/dev/null || true)"
  check "YAML tenant.password == Rohwert" "$HOSTILE" "$tenant_val"
else
  echo "SKIP: mikefarah-yq nicht vorhanden (yq=$(yq --version 2>&1))"
fi

# ── 3) source credentials.env liefert den Rohwert ─────────────────────────────
(
  # shellcheck disable=SC1090
  source "$CRED" && printf '%s' "${TENANT_ADMIN_PASSWORD}"
) >"$T/got.txt" 2>/dev/null; rc=$?
check "credentials.env sourcebar (rc=0)" "0" "$rc"
check "source liefert Rohwert" "$HOSTILE" "$(cat "$T/got.txt")"

# ── 4) Dateirechte 600 ────────────────────────────────────────────────────────
check "Inventory-Modus 600" "600" "$(stat -c %a "$OUT" 2>/dev/null || echo 0)"
check "Credentials-Modus 600" "600" "$(stat -c %a "$CRED" 2>/dev/null || echo 0)"

# ── 5) Zeilenumbruch -> Abbruch mit Klartext ──────────────────────────────────
run_render $'line1\nline2' "$HOSTILE" nl >"$T/nl.log" 2>"$T/nl.err"; rc=$?
check "Zeilenumbruch -> Abbruch" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"
check "Klartext-Meldung" "yes" "$(grep -q 'Zeilenumbruch' "$T/nl.err" && echo yes || echo no)"

rm -rf "$T"

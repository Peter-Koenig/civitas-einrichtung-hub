#!/usr/bin/env bash
# Suite 13: Velero location_name schema-konform bei deaktiviertem Velero.
# minLength:1 (inventory_schema.json) verlangt einen nichtleeren String.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "velero_schema"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS" >> "${TEST_RESULTS_FILE}"
    echo "PASS: ${name}"
  else
    echo "FAIL" >> "${TEST_RESULTS_FILE}"
    echo "FAIL: ${name} (erwartet=${expected}, ist=${actual})"
  fi
}

# 1 + 2: Beide Templates enthalten exakt location_name: "disabled", ohne Guard-Literal.
for tpl in "$REPO/templates_V1/inventory.yml.tpl" "$REPO/templates_V1s/inventory.yml.tpl"; do
  name="$(basename "$(dirname "$tpl")")"
  line="$(grep -E '^[[:space:]]+location_name:' "$tpl" | head -1)"
  check "$name: location_name disabled" '              location_name: "disabled"' "$line"
  check "$name: kein Guard-Literal" "no" "$(printf '%s' "$line" | grep -qE 'TODO:PLEASE|TODO_PLEASE|CHANGE_ME' && echo yes || echo no)"
done

# 3: Schema-Fixture (minLength:1) — "" abgelehnt, "disabled" akzeptiert.
schema_check() {
  python3 - "$1" <<'PYEOF'
import sys
val = sys.argv[1]
print("ACCEPT" if len(val) >= 1 else "REJECT")
PYEOF
}
check "Schema lehnt leeren location_name ab" "REJECT" "$(schema_check '')"
check "Schema akzeptiert 'disabled'" "ACCEPT" "$(schema_check 'disabled')"

rm -rf "$T"

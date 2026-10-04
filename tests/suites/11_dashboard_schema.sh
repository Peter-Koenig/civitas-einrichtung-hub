#!/usr/bin/env bash
# Suite 11: APISIX-Dashboard schema-konform rendern (nur enable), kein
# Dashboard-Passwort/JWT in credentials.env. Nur Testwerte, kein Cluster/Netz.

begin_suite "dashboard_schema"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

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

gen_policy_password() { echo "GenPass-zzz-42"; }

# ── V1: Inventory + Credentials rendern ──────────────────────────────────────
(
  DOMAIN="udp.example.com"; DOMAIN_NAME="example.com"
  ADMIN_PASS="TestPassw0rt!"; ADMIN_EMAIL="admin@example.com"
  SMTP_HOST="smtp.example.com"; SMTP_USER="u"; SMTP_PASS="p"
  RUSTFS_ENDPOINT=""; RUSTFS_ACCESS_KEY=""; RUSTFS_SECRET_KEY=""
  RUSTFS_BUCKET_NAME="portal-config"; RUSTFS_REGION="eu-north-1"; RUSTFS_FORCE_PATH_STYLE="true"
  CC_API_MAX_RETRIES="60"; CC_DEPLOYMENT_MAX_RETRIES="30"
  CREDENTIALS_OUTPUT_PATH="$T/credentials_v1.env"; CC_CLI_PLAYBOOK_DIR="$T/pb_v1"
  mkdir -p "$CC_CLI_PLAYBOOK_DIR"
  SCRIPT_DIR="$REPO"
  # shellcheck source=../../modules_V1/06_civitas.sh
  source "$REPO/modules_V1/06_civitas.sh"
  set +e
  render_inventory >/dev/null 2>&1
  inv="$CC_CLI_PLAYBOOK_DIR/cc_cli_inventory.yml"
  block="$(sed -n '/dashboard:/,/etcd:/p' "$inv")"
  check "V1 dashboard enthält enable" "yes" "$(printf '%s' "$block" | grep -q 'enable:' && echo yes || echo no)"
  check "V1 dashboard ohne admin/jwt_secret/password" "no" "$(printf '%s' "$block" | grep -qE 'jwt_secret|admin|password' && echo yes || echo no)"
  check "V1 credentials ohne APISIX_DASHBOARD" "no" "$(grep -q 'APISIX_DASHBOARD' "$CREDENTIALS_OUTPUT_PATH" && echo yes || echo no)"
)

# ── V1s: Inventory + Credentials rendern ─────────────────────────────────────
(
  DOMAIN="udp.example.com"; DOMAIN_NAME="example.com"
  ADMIN_PASS="TestPassw0rt!"; ADMIN_EMAIL="admin@example.com"
  SMTP_HOST="smtp.example.com"; SMTP_USER="u"; SMTP_PASS="p"
  V1S_IMAGE_REF="geoportal:v1s-local"
  CC_API_MAX_RETRIES="60"; CC_DEPLOYMENT_MAX_RETRIES="30"
  CREDENTIALS_OUTPUT_PATH="$T/credentials_v1s.env"; CC_CLI_PLAYBOOK_DIR="$T/pb_v1s"
  mkdir -p "$CC_CLI_PLAYBOOK_DIR"
  SCRIPT_DIR="$REPO"
  # shellcheck source=../../modules_V1s/06_civitas.sh
  source "$REPO/modules_V1s/06_civitas.sh"
  set +e
  render_inventory >/dev/null 2>&1
  inv="$CC_CLI_PLAYBOOK_DIR/cc_cli_inventory.yml"
  block="$(sed -n '/dashboard:/,/etcd:/p' "$inv")"
  check "V1s dashboard enthält enable" "yes" "$(printf '%s' "$block" | grep -q 'enable:' && echo yes || echo no)"
  check "V1s dashboard ohne admin/jwt_secret/password" "no" "$(printf '%s' "$block" | grep -qE 'jwt_secret|admin|password' && echo yes || echo no)"
  check "V1s credentials ohne APISIX_DASHBOARD" "no" "$(grep -q 'APISIX_DASHBOARD' "$CREDENTIALS_OUTPUT_PATH" && echo yes || echo no)"
)

# ── Schema-Fixture: additionalProperties=false (enable, resources) ──────────
# Minimaler Nachbau der Upstream-Regel: dashboard erlaubt nur enable/resources.
schema_check() {
  python3 - "$1" <<'PYEOF'
import re, sys
allowed = {"enable", "resources"}
path = sys.argv[1]
child_indent = None
keys = []
for line in open(path):
    s = line.rstrip("\n")
    m = re.match(r"^(\s*)dashboard:\s*$", s)
    if m:
        child_indent = len(m.group(1)) + 2
        continue
    if child_indent is None:
        continue
    km = re.match(r"^(\s+)([A-Za-z_][A-Za-z0-9_]*):", s)
    if km and len(km.group(1)) == child_indent:
        keys.append(km.group(2))
    elif km and len(km.group(1)) < child_indent:
        child_indent = None
print("REJECT" if set(keys) - allowed else "ACCEPT")
PYEOF
}

check "Schema akzeptiert templates_V1" "ACCEPT" "$(schema_check "$REPO/templates_V1/inventory.yml.tpl")"
check "Schema akzeptiert templates_V1s" "ACCEPT" "$(schema_check "$REPO/templates_V1s/inventory.yml.tpl")"

WRONG="$T/wrong_dashboard.yml"
printf 'dashboard:\n  enable: true\n  jwt_secret: "x"\n  admin:\n    username: "u"\n    password: "p"\n' > "$WRONG"
check "Schema lehnt admin/jwt_secret ab" "REJECT" "$(schema_check "$WRONG")"

rm -rf "$T"

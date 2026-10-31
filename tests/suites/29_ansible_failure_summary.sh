#!/usr/bin/env bash
# Suite 29: ansible_failure_summary — Allowlist und Redaction aus dem
# Ansible-Log. Nur Testwerte und Fixtures, kein Cluster/Netz.

begin_suite "ansible_failure_summary"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

summary_of() {
  : > "$LOGBUF"
  ansible_failure_summary "$1" 2>/dev/null
  grep '^E:' "$LOGBUF" | sed 's/^E:  //'
}

# (a) NameError + attempts/rc/pod/namespace sichtbar, kein PGPASSWORD/command.
a=$(summary_of "$REPO/tests/fixtures/ansible_fail_nameerror.log")
check "a NameError sichtbar"      "yes" "$(printf '%s' "$a" | grep -q 'NameError' && echo yes || echo no)"
check "a core_v1_api sichtbar"    "yes" "$(printf '%s' "$a" | grep -q 'core_v1_api' && echo yes || echo no)"
check "a attempts sichtbar"       "yes" "$(printf '%s' "$a" | grep -q 'attempts: 60' && echo yes || echo no)"
check "a rc sichtbar"             "yes" "$(printf '%s' "$a" | grep -q 'rc: 1' && echo yes || echo no)"
check "a pod sichtbar"            "yes" "$(printf '%s' "$a" | grep -q 'central-db-0' && echo yes || echo no)"
check "a namespace sichtbar"      "yes" "$(printf '%s' "$a" | grep -q 'cc-prd-database-stack' && echo yes || echo no)"
check "a kein PGPASSWORD"         "no"  "$(printf '%s' "$a" | grep -q 'PGPASSWORD' && echo yes || echo no)"
check "a kein command-Inhalt"     "no"  "$(printf '%s' "$a" | grep -q 'psql' && echo yes || echo no)"
check "a kein Secretwert"         "no"  "$(printf '%s' "$a" | grep -q 'supersecret' && echo yes || echo no)"

# (b) Secret in msg wird geschwaerzt.
b=$(summary_of "$REPO/tests/fixtures/ansible_fail_secret_msg.log")
check "b Secret geschwaerzt"      "yes" "$(printf '%s' "$b" | grep -q 'password=\*\*\*\*' && echo yes || echo no)"
check "b kein Klartext"           "no"  "$(printf '%s' "$b" | grep -q 'abc123' && echo yes || echo no)"

# (c) "...ignoring" wird uebersprungen, frueherer nicht-ignorierter Block gewaehlt.
c=$(summary_of "$REPO/tests/fixtures/ansible_fail_ignored.log")
check "c frueherer Block gewaehlt" "yes" "$(printf '%s' "$c" | grep -q 'earlier real failure' && echo yes || echo no)"
check "c ignorierter Block fehlt"  "no"  "$(printf '%s' "$c" | grep -q 'ignored failure' && echo yes || echo no)"

# (d) Defektes JSON: Fallback, Exit 0, kein Abbruch unter set -e.
: > "$LOGBUF"
( set -e; ansible_failure_summary "$REPO/tests/fixtures/ansible_fail_broken_json.log" >/dev/null 2>&1 )
check "d Exit 0 unter set -e"    "0"   "$?"
d=$(grep '^E:' "$LOGBUF" | sed 's/^E:  //')
check "d Fallback-Inhalt"        "yes" "$(printf '%s' "$d" | grep -q 'not valid json' && echo yes || echo no)"

# (e) last_fatal_has_policy_signal: Policy-Signal vs. neutral (A4).
mk_fatal_block "$T/policy.log" 'Keycloak password_policy violation'
( last_fatal_has_policy_signal "$T/policy.log" >/dev/null 2>&1 ); rc=$?
check "e Policy-Signal erkannt"   "0" "$rc"

mk_fatal_block "$T/neutral.log" 'Error: looks like chart repository is not valid'
( last_fatal_has_policy_signal "$T/neutral.log" >/dev/null 2>&1 ); rc=$?
check "e neutraler Block nicht erkannt" "1" "$rc"

rm -rf "$T"

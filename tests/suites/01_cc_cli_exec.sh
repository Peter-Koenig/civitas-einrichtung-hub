#!/usr/bin/env bash
# Suite 01: run_cc_cli_exec — Klassifikation (fatal-begrenzt, 404-Idempotenz, Retry).
# Nur Testwerte, kein Cluster/Netz.

begin_suite "cc_cli_exec"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

CC_CLI_PLAYBOOK_DIR="$T/playbook"
mkdir -p "$CC_CLI_PLAYBOOK_DIR"
export TIMEOUT_CC_CLI_EXEC=2700
export CC_CLI_VENV_PATH="$TEST_ROOT/stubs"
export CC_EXEC_ATTEMPTS=2
export CC_EXEC_RETRY_DELAY=0

# shellcheck source=../../modules_V1/06_civitas.sh
source "$REPO/modules_V1/06_civitas.sh"

reset_state() {
  rm -rf "$T/playbook/logs" "$LOGBUF"
  : > "$LOGBUF"
  CC_EXEC_ATTEMPTS=2
}

mk_404()  { mk_fatal_block "$1" 'Status code was 404 and not [204]'; }
mk_503()  { mk_fatal_block "$1" 'Status code was 503 and not [200]: HTTP Error 503: Service Temporarily Unavailable'; }

# T1: 503 nur im Versuch-1-Log → Retry → Erfolg, zwei Logdateien
reset_state
SC="$T/s1"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_503 "$SC/l1.log"
printf 'some non-transient output\n' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T1 zwei Versuche" "2" "$(cat "$SC/count")"
check "T1 Versuch-2-Log existiert" "yes" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/logs/ansible_attempt_2.log" ]] && echo yes || echo no)"

# T2: nur 404-Fatals → toleriert, kein Retry
reset_state
SC="$T/s2"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_404 "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T2 ein Versuch" "1" "$(cat "$SC/count")"
check "T2 kein harter Fehler" "no" "$(grep -q 'Playbook fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

# T3: 404-Fatal + anderer Fatal → nicht toleriert
reset_state
SC="$T/s3"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_404 "$SC/l1.log"
printf '\n' >> "$SC/l1.log"
mk_fatal_block "$SC/f2.log" 'release name is invalid'
cat "$SC/f2.log" >> "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T3 harter Fehler gemeldet" "yes" "$(grep -q 'Playbook fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

# T4: 404 im ignorierten Task + echter 503-Fatal → transient
reset_state
SC="$T/s4"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_404 "$SC/l1.log"
printf '...ignoring\n' >> "$SC/l1.log"
mk_503 "$SC/f2.log"
cat "$SC/f2.log" >> "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T4 transient → zwei Versuche" "2" "$(cat "$SC/count")"

# T5: rc==0 mit 'failed with status: failed', kein Fatal → hart
reset_state
SC="$T/s5"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
printf 'something failed with status: failed\n' > "$SC/o1.txt"
printf '' > "$SC/l1.log"
printf '0\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T5 harter Fehler gemeldet" "yes" "$(grep -q 'Playbook fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

# T6: Rechte + Symlink
reset_state
SC="$T/s6"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_404 "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
LOGDIR="$CC_CLI_PLAYBOOK_DIR/logs"
check "T6 Log-Verzeichnis 0700" "700" "$(stat -c '%a' "$LOGDIR" 2>/dev/null)"
check "T6 Symlink auf Versuch 1" "ansible_attempt_1.log" "$(readlink "$LOGDIR/ansible_run_latest.log" 2>/dev/null)"

# T7: kein Secret auf Konsole
reset_state
SC="$T/s7"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'TEST_SECRET_DO_NOT_USE leaked in log'
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
out=$(run_cc_cli_exec 2>&1)
check "T7 kein Secret auf Konsole" "no" "$(printf '%s' "$out" | grep -q 'TEST_SECRET_DO_NOT_USE' && echo yes || echo no)"

rm -rf "$T"

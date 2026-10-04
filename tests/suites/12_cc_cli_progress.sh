#!/usr/bin/env bash
# Suite 12: run_cc_cli_exec — sicherer Live-Fortschritt (Heartbeat), kein
# Rohoutput, Rohdatei wird gelöscht. Nur Testwerte, kein Cluster/Netz.

begin_suite "cc_cli_progress"

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
export CC_EXEC_HEARTBEAT_INTERVAL=0
export KUBECONFIG_PATH="/dev/null"

# shellcheck source=../../modules_V1/06_civitas.sh
source "$REPO/modules_V1/06_civitas.sh"

mk_503() { mk_fatal_block "$1" 'Status code was 503 and not [200]: HTTP Error 503: Service Temporarily Unavailable'; }

RAWDIR="$CC_CLI_PLAYBOOK_DIR/logs"
reset_state() {
  : > "$LOGBUF"
  rm -f "$RAWDIR"/cc_cli_raw_*.txt
}

# T1: Erfolg (rc=0) — Rohinhalt (Secret/JSON/Inventory/Token) erscheint nicht
# auf der Konsole, Rohdatei wird gelöscht.
reset_state
SC="$T/s1"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
printf 'ok: [localhost]\nskipping: [host]\nfatal: [host]: FAILED => TEST_SECRET_DO_NOT_USE\n{"inventory":"secret_value"}\napi_token: "tok-abc123"\n' > "$SC/o1.txt"
printf '' > "$SC/l1.log"
printf '0\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 ); rc=$?
check "T1 Erfolg rc=0" "0" "$rc"
check "T1 Rohdatei gelöscht" "no" "$([ -f "$RAWDIR/cc_cli_raw_1.txt" ] && echo yes || echo no)"
check "T1 kein Secret auf Konsole" "no" "$(grep -q 'TEST_SECRET_DO_NOT_USE' "$LOGBUF" && echo yes || echo no)"
check "T1 kein JSON/Inventory/Token auf Konsole" "no" "$(grep -qE 'secret_value|tok-abc123|\{"inventory"' "$LOGBUF" && echo yes || echo no)"

# T2: transienter Fehler -> Retry -> Erfolg; beide Rohdateien gelöscht.
reset_state
SC="$T/s2"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_503 "$SC/l1.log"
printf 'try one raw output\n' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T2 zwei Versuche" "2" "$(cat "$SC/count")"
check "T2 Rohdateien gelöscht" "no" "$([ -f "$RAWDIR/cc_cli_raw_1.txt" ] || [ -f "$RAWDIR/cc_cli_raw_2.txt" ] && echo yes || echo no)"
check "T2 Rohinhalt nicht auf Konsole" "no" "$(grep -q 'try one raw output' "$LOGBUF" && echo yes || echo no)"

# T3: finaler Fehler — Rohdatei gelöscht, kein Rohinhalt, sichere Diagnose.
reset_state
SC="$T/s3"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'release name is invalid'
printf 'hard failure raw output\n' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 ); rc=$?
check "T3 finaler Fehler rc=1" "1" "$rc"
check "T3 Rohdatei gelöscht" "no" "$([ -f "$RAWDIR/cc_cli_raw_1.txt" ] && echo yes || echo no)"
check "T3 Rohinhalt nicht auf Konsole" "no" "$(grep -q 'hard failure raw output' "$LOGBUF" && echo yes || echo no)"
check "T3 Ansible-Logpfad in Diagnose" "yes" "$(grep -q 'ansible_attempt_1.log' "$LOGBUF" && echo yes || echo no)"

# T4: Heartbeat erscheint bei langsamem Lauf (Stub schläft, Intervall 1 s).
reset_state
export CC_EXEC_HEARTBEAT_INTERVAL=1
SC="$T/s4"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
printf '' > "$SC/o1.txt"
printf '' > "$SC/l1.log"
printf '0\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
printf '2\n' > "$SC/sleep"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T4 Heartbeat erschienen" "yes" "$(grep -q 'cc_cli läuft:' "$LOGBUF" && echo yes || echo no)"
export CC_EXEC_HEARTBEAT_INTERVAL=0

rm -rf "$T"

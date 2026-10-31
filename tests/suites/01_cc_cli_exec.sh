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

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

reset_state() {
  rm -rf "$T/playbook/logs" "$LOGBUF"
  : > "$LOGBUF"
  CC_EXEC_ATTEMPTS=2
}

mk_404()  { mk_fatal_block "$1" 'Status code was 404 and not [204]'; }
mk_503()  { mk_fatal_block "$1" 'Status code was 503 and not [200]: HTTP Error 503: Service Temporarily Unavailable'; }
mk_geo401() {
  local f="$1"
  printf '%s\n' \
    '2026-10-31 18:12:46,479 p=11442 u=root n=ansible | fatal: [localhost]: FAILED! => {' \
    '    "msg": "Status code was 401 and not [200]: HTTP Error 401: ",' \
    '    "url": "https://geoportal.example.org/geoserver/rest/security/authfilters",' \
    '    "www_authenticate": "Basic realm=\"GeoServer Realm\", charset=\"UTF-8\""' \
    '}' > "$f"
}

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

# T8: connection reset by peer -> transient -> Retry (A3)
reset_state
SC="$T/s8"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'read: connection reset by peer'
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T8 connection reset -> zwei Versuche" "2" "$(cat "$SC/count")"

# T9 (Punkt 3a): frühes "Connection refused" in der Rohdatei + finales Fatal
# "password policy" -> KEIN Retry (die Rohdatei zählt bei vorhandenen Fatals nicht).
reset_state
SC="$T/s9"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'Keycloak password_policy violation'
printf 'FAILED - RETRYING ... Connection refused\nsome other output\n' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T9 frühes Connection refused + Fatal policy -> ein Versuch" "1" "$(cat "$SC/count")"

# T10 (Punkt 3c): zwei Fatals (einer transient, einer nicht) -> KEIN Retry.
reset_state
SC="$T/s10"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'read: connection reset by peer'
printf '\n' >> "$SC/l1.log"
mk_fatal_block "$SC/f2.log" 'Keycloak password_policy violation'
cat "$SC/f2.log" >> "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T10 zwei Fatals gemischt -> ein Versuch" "1" "$(cat "$SC/count")"

# T11 (Punkt 3d): kein Fatal, rc != 0, Ende der Rohdatei enthält connection reset -> Retry.
reset_state
SC="$T/s11"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
printf '' > "$SC/l1.log"; printf '' > "$SC/l2.log"
printf 'some output\nread: connection reset by peer\n' > "$SC/o1.txt"
printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "$SC/l2.log" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T11 kein Fatal, tail connection reset -> zwei Versuche" "2" "$(cat "$SC/count")"

# T12 (Punkt 3e): rc == 124 -> Retry.
reset_state
SC="$T/s12"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
printf '' > "$SC/l1.log"; printf '' > "$SC/l2.log"
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '124\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "$SC/l2.log" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T12 rc 124 -> zwei Versuche" "2" "$(cat "$SC/count")"

# T13 (Turn 11 A): GeoServer-401 (www_authenticate geoserver realm) -> transient -> Retry
reset_state
SC="$T/s13"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_geo401 "$SC/l1.log"
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T13 GeoServer-401 -> zwei Versuche" "2" "$(cat "$SC/count")"
check "T13 Warnung nennt GeoServer" "yes" "$(grep -q 'GeoServer' "$LOGBUF" && echo yes || echo no)"

# T14 (Turn 11 A): Keycloak-401 ohne GeoServer-Realm -> KEIN Retry
reset_state
SC="$T/s14"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_fatal_block "$SC/l1.log" 'Status code was 401 and not [200]: invalid_user_credentials'
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T14 Keycloak-401 -> ein Versuch" "1" "$(cat "$SC/count")"

# T15 (Turn 11 A): zwei Fatals (GeoServer-401 + nicht transient) -> KEIN Retry
reset_state
SC="$T/s15"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_geo401 "$SC/l1.log"
printf '\n' >> "$SC/l1.log"
mk_fatal_block "$SC/f2.log" 'release name is invalid'
cat "$SC/f2.log" >> "$SC/l1.log"
printf '' > "$SC/o1.txt"
printf '1\n' > "$SC/rcs"
printf '%s\n' "$SC/l1.log" > "$SC/logfiles"
printf '%s\n' "$SC/o1.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T15 zwei Fatals gemischt -> ein Versuch" "1" "$(cat "$SC/count")"

# T16 (Turn 11 A): zwei GeoServer-401-Fatals -> Retry
reset_state
SC="$T/s16"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
mk_geo401 "$SC/l1.log"
printf '\n' >> "$SC/l1.log"
mk_geo401 "$SC/f2.log"
cat "$SC/f2.log" >> "$SC/l1.log"
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T16 zwei GeoServer-401 -> zwei Versuche" "2" "$(cat "$SC/count")"

# T17 (Turn 11 B): GeoServer-401 loest den Sammler aus (Datei existiert, 600, gefiltert)
reset_state
SC="$T/s17"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
cat > "$SC/kubectl.sh" <<'KUBE'
#!/usr/bin/env bash
case "$*" in
  *"logs"*)
    printf '2026-10-31 17:12:41 INFO Failed login for user admin from 10.0.0.1\n'
    printf '2026-10-31 17:12:45 INFO Storing user/groups successful for service named default\n'
    printf 'some unrelated line\n'
    ;;
  *".metadata.namespace"*)
    printf 'cc-prd-geodata-stack'
    ;;
  *".metadata.name"*)
    printf 'geoserver-geoserver-abc123'
    ;;
  *)
    printf 'cc-prd-geodata-stack  geoserver-geoserver-abc123  1/1  Running\n'
    ;;
esac
exit 0
KUBE
chmod +x "$SC/kubectl.sh"
export KUBECTL_SCRIPT="$SC/kubectl.sh"
mk_geo401 "$SC/l1.log"
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
DIAG="$CC_CLI_PLAYBOOK_DIR/logs/geoserver_auth_diag_1.txt"
check "T17 Sammler-Datei existiert" "yes" "$([[ -f "$DIAG" ]] && echo yes || echo no)"
check "T17 Sammler-Datei Modus 600" "600" "$(stat -c %a "$DIAG" 2>/dev/null || echo 0)"
check "T17 enthaelt gefilterte Zeile" "yes" "$(grep -q 'Failed login' "$DIAG" 2>/dev/null && echo yes || echo no)"
check "T17 filtert Unerwuenschtes" "no" "$(grep -q 'some unrelated line' "$DIAG" 2>/dev/null && echo yes || echo no)"

# T17b (Turn 11 B): Sammler-Fehler (kubectl rc 1) aendert die Retry-Entscheidung nicht.
reset_state
SC="$T/s17b"; mkdir -p "$SC"; export STUB_CONTROL="$SC"
cat > "$SC/kubectl.sh" <<'KUBE'
#!/usr/bin/env bash
exit 1
KUBE
chmod +x "$SC/kubectl.sh"
export KUBECTL_SCRIPT="$SC/kubectl.sh"
mk_geo401 "$SC/l1.log"
printf '' > "$SC/o1.txt"; printf '' > "$SC/o2.txt"
printf '1\n0\n' > "$SC/rcs"
printf '%s\n%s\n' "$SC/l1.log" "" > "$SC/logfiles"
printf '%s\n%s\n' "$SC/o1.txt" "$SC/o2.txt" > "$SC/outfiles"
( run_cc_cli_exec >/dev/null 2>&1 )
check "T17b Sammler-Fehler -> trotzdem zwei Versuche" "2" "$(cat "$SC/count")"

rm -rf "$T"

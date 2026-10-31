#!/usr/bin/env bash
# Suite 41: run_in_vm — SSH-Hop-Fehler gibt den Exit-Code durch, das LE-Backup
# wird trotzdem zurückgeholt (unter set -e, wie im Hauptskript).

begin_suite "run_in_vm_ssh_exit"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

# ssh-Stub: rc 7 nur für den Hop (enthält CIVITAS_CONTEXT=vm), sonst Erfolg.
cat > "$STUBS/ssh" <<'SSH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *CIVITAS_CONTEXT=vm*) exit 7 ;;
  esac
done
exit 0
SSH
chmod +x "$STUBS/ssh"

# scp-Stub: Erfolg, protokolliert Aufrufe; legt lokale Ziele als Datei an, damit
# nachfolgende mv/cmp im Backup-Pfad nicht unter set -e scheitern.
cat > "$STUBS/scp" <<'SCP'
#!/usr/bin/env bash
printf 'scp %s\n' "$*" >> "${SCP_CALL_LOG:-/dev/null}"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
  *:*) : ;;   # Remote-Ziel (root@host:...) — nicht anfassen
  *) touch "$last" 2>/dev/null || true ;;
esac
exit 0
SCP
chmod +x "$STUBS/scp"

export SCP_CALL_LOG="$T/scp.log"

# run_in_vm aus dem Hauptskript extrahieren (nur die Funktion sourcebar machen).
sed -n '/^run_in_vm()/,/^}/p' "$REPO/install_civitas_core_V1s.sh" > "$T/run_in_vm.sh"

# Stubs für die von run_in_vm aufgerufenen Helfer + benötigte Variablen.
ensure_vm_ssh_access() { :; }
set_root_password() { :; }
find_env_file() { printf '%s\n' "$T/.env.local"; }
VM_SSH_OPTS=()
VM_IP_STATIC=192.0.2.10
VM_REMOTE_INSTALL_DIR=/root/civitas-install
SCRIPT_DIR="$REPO"
CERT_BACKUP_FILE=/root/civitas-install/le-certs-backup.yaml
CERT_BACKUP_HOST_FILE="$T/le-certs-backup.yaml"

# set -e, damit der Test die tatsächliche Hauptskript-Umgebung abbildet.
( set -euo pipefail; source "$T/run_in_vm.sh"; run_in_vm ) >/dev/null 2>&1; rc=$?
check "SSH-Hop-Fehler -> Exit 7" "7" "$rc"
check "Backup-Rückholen lief trotz Hop-Fehler" "yes" \
  "$(grep -q 'le-certs-backup.yaml' "$SCP_CALL_LOG" && echo yes || echo no)"

rm -rf "$T"

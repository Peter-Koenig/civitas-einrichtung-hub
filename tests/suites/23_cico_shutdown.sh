#!/usr/bin/env bash
# Suite 22: cico-shutdown / cico-uncordon — Skriptlogik, Node-Auswahl und
# Update-Regel des Installers. Nur Stubs, kein Cluster/Netz.

begin_suite "cico_shutdown_rework"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)

# ── Helfer ───────────────────────────────────────────────────────────────────
# Here-Doc aus einem Modul extrahieren (open = Markerzeile, term = Abschluss).
extract_heredoc() {
  local file="$1" open="$2" term="$3"
  awk -v open="$open" -v term="$term" '
    index($0, open) { flag=1; next }
    flag && $0 == term { flag=0; next }
    flag
  ' "$file"
}

# Einzelne Funktion aus einem Modul extrahieren.
extract_function() {
  local file="$1" fname="$2"
  awk -v fname="$fname" '
    index($0, fname "() {") { flag=1 }
    flag { print }
    flag && $0 == "}" { exit }
  ' "$file"
}

# ── T0: byte-identische Here-Docs in V1 und V1s ──────────────────────────────
extract_heredoc "$REPO/modules_V1/05_addons.sh" "<< 'CICO_SCRIPT'" "CICO_SCRIPT" > "$T/v1_shutdown"
extract_heredoc "$REPO/modules_V1s/05_addons.sh" "<< 'CICO_SCRIPT'" "CICO_SCRIPT" > "$T/v1s_shutdown"
extract_heredoc "$REPO/modules_V1/05_addons.sh" "<< 'UNCORDON_SCRIPT'" "UNCORDON_SCRIPT" > "$T/v1_uncordon"
extract_heredoc "$REPO/modules_V1s/05_addons.sh" "<< 'UNCORDON_SCRIPT'" "UNCORDON_SCRIPT" > "$T/v1s_uncordon"
extract_heredoc "$REPO/modules_V1/05_addons.sh" "<< 'SERVICE_EOF'" "SERVICE_EOF" > "$T/v1_service"
extract_heredoc "$REPO/modules_V1s/05_addons.sh" "<< 'SERVICE_EOF'" "SERVICE_EOF" > "$T/v1s_service"

check "V1/V1s cico-shutdown byte-identisch" "yes" "$(cmp -s "$T/v1_shutdown" "$T/v1s_shutdown" && echo yes || echo no)"
check "V1/V1s cico-uncordon byte-identisch" "yes" "$(cmp -s "$T/v1_uncordon" "$T/v1s_uncordon" && echo yes || echo no)"
check "V1/V1s Service byte-identisch" "yes" "$(cmp -s "$T/v1_service" "$T/v1s_service" && echo yes || echo no)"

# ── T1: Update-Regel install_or_update_file ──────────────────────────────────
extract_function "$REPO/modules_V1/05_addons.sh" "install_or_update_file" > "$T/helper.sh"
# shellcheck source=/dev/null
source "$T/helper.sh"

LOGBUF="$T/installer.log"
log()    { echo "L:$*" >> "$LOGBUF"; }
log_ok() { echo "O:$*" >> "$LOGBUF"; }

# T1a: identischer Inhalt -> keine Änderung, kein Backup
f="$T/target.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$f"
chmod 0755 "$f"
cp "$f" "$T/expected_same"
: > "$LOGBUF"
printf '#!/usr/bin/env bash\necho hello\n' | install_or_update_file "$f" 0755
check "Update identisch: rc=0" "0" "$?"
check "Update identisch: bereits aktuell geloggt" "yes" "$(grep -q 'bereits aktuell' "$LOGBUF" && echo yes || echo no)"
check "Update identisch: Inhalt unveraendert" "yes" "$(cmp -s "$f" "$T/expected_same" && echo yes || echo no)"
check "Update identisch: kein Backup" "0" "$(ls "$f".bak-* 2>/dev/null | wc -l)"

# T1b: abweichender Inhalt -> Backup + Ersetzen
: > "$LOGBUF"
printf '#!/usr/bin/env bash\necho changed\n' | install_or_update_file "$f" 0755
check "Update abweichend: rc=0" "0" "$?"
check "Update abweichend: Backup angelegt" "1" "$(ls "$f".bak-* 2>/dev/null | wc -l)"
check "Update abweichend: Inhalt ersetzt" "yes" "$(grep -q 'echo changed' "$f" && echo yes || echo no)"
check "Update abweichend: Backup enthaelt alten Inhalt" "yes" "$(grep -q 'echo hello' "$f".bak-* 2>/dev/null && echo yes || echo no)"

# T1c: neue Datei -> anlegen ohne Backup, Modus gesetzt
newf="$T/new.sh"
: > "$LOGBUF"
printf '#!/usr/bin/env bash\necho new\n' | install_or_update_file "$newf" 0755
check "Update neu: Datei angelegt" "yes" "$([[ -f "$newf" ]] && echo yes || echo no)"
check "Update neu: kein Backup" "0" "$(ls "$newf".bak-* 2>/dev/null | wc -l)"
check "Update neu: Modus 0755" "yes" "$([[ -x "$newf" ]] && echo yes || echo no)"

# ── T2: cico-shutdown-Skriptlogik ────────────────────────────────────────────
# Testkopie: root-check neutralisiert (Tests laufen nicht als root).
extract_heredoc "$REPO/modules_V1/05_addons.sh" "<< 'CICO_SCRIPT'" "CICO_SCRIPT" \
  | sed 's/"\${EUID}"/"0"/' > "$T/cico-shutdown"
chmod +x "$T/cico-shutdown"

cat > "$T/kubectl.sh" << 'KUBECTL_EOF'
#!/usr/bin/env bash
case "${KUBECTL_SCENARIO}" in
  single_stuck)
    case "$*" in
      *"get nodes -o name"*) echo "node/test-node" ;;
      *"get node test-node"*) exit 0 ;;
      *"get pods"*"--no-headers"*) echo "StatefulSet Running 30" ;;
      *) exit 0 ;;
    esac
    ;;
  single_empty)
    case "$*" in
      *"get nodes -o name"*) echo "node/test-node" ;;
      *"get node test-node"*) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  multi)
    case "$*" in
      *"get nodes -o name"*) printf 'node/a\nnode/b\n' ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
KUBECTL_EOF

run_shutdown() {
  # $1 = KUBECTL_SCENARIO; weitere Argumente KEY=VALUE (Env für das Skript).
  local scenario="$1"; shift
  (
    export KUBECTL_SCRIPT="$T/kubectl.sh"
    export KUBECTL_SCENARIO="$scenario"
    export LOG_FILE="$T/shutdown.log"
    export LOCK_FILE="$T/shutdown.lock"
    export K3S_KILLALL="$T/killall-missing.sh"
    export KUBECTL_CALL_LOG="$T/kubectl_calls.log"
    export SYSTEMCTL_CALL_LOG="$T/systemctl_calls.log"
    : > "$KUBECTL_CALL_LOG"
    : > "$SYSTEMCTL_CALL_LOG"
    local kv
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    "$T/cico-shutdown"
  )
}

# T2a: DRY_RUN + einzelner Node + Wartezeit-Berechnung
: > "$T/shutdown.log"
run_shutdown single_stuck DRY_RUN=1
check "DRY_RUN: rc=0" "0" "$?"
check "DRY_RUN: Node aus Cluster ermittelt" "yes" "$(grep -q 'Node:.*test-node' "$T/shutdown.log" && echo yes || echo no)"
check "DRY_RUN: Drain-Timeout 60s (Grace 30 + MARGIN 30)" "yes" "$(grep -q 'Drain-Timeout:.*60s' "$T/shutdown.log" && echo yes || echo no)"
check "DRY_RUN: Plan geloggt" "yes" "$(grep -q 'DRY_RUN=1' "$T/shutdown.log" && echo yes || echo no)"
check "DRY_RUN: kein systemctl-Aufruf" "0" "$(wc -l < "$T/systemctl_calls.log")"

# T2b: mehrere Nodes -> Abbruch mit Exit 1
: > "$T/shutdown.log"
run_shutdown multi DRY_RUN=1
check "multi-node: rc=1" "1" "$?"
check "multi-node: Fehlermeldung geloggt" "yes" "$(grep -q 'nicht eindeutig' "$T/shutdown.log" && echo yes || echo no)"

# T2c: K3S_NODE-Override
: > "$T/shutdown.log"
run_shutdown single_stuck DRY_RUN=1 K3S_NODE=my-node
check "K3S_NODE-Override: rc=0" "0" "$?"
check "K3S_NODE-Override: Node uebernommen" "yes" "$(grep -q 'Node:.*my-node' "$T/shutdown.log" && echo yes || echo no)"

# T2d: Timeout-Pfad -> Exit 2 und Uncordon
: > "$T/shutdown.log"
run_shutdown single_stuck
check "Timeout: rc=2" "2" "$?"
check "Timeout: Abbruchmeldung geloggt" "yes" "$(grep -q 'Abbruch ohne Herunterfahren (Exit 2)' "$T/shutdown.log" && echo yes || echo no)"
check "Timeout: uncordon aufgerufen" "yes" "$(grep -q 'uncordon' "$T/kubectl_calls.log" && echo yes || echo no)"
check "Timeout: kein poweroff" "no" "$(grep -q 'poweroff' "$T/systemctl_calls.log" && echo yes || echo no)"

# T2e: FORCE=1 -> trotz laufender Pods herunterfahren
: > "$T/shutdown.log"
run_shutdown single_stuck FORCE=1
check "FORCE=1: rc=0" "0" "$?"
check "FORCE=1: k3s gestoppt" "yes" "$(grep -q 'stop k3s' "$T/systemctl_calls.log" && echo yes || echo no)"
check "FORCE=1: poweroff ausgefuehrt" "yes" "$(grep -q 'poweroff' "$T/systemctl_calls.log" && echo yes || echo no)"

# T2f: NO_POWEROFF=1 -> kein poweroff
: > "$T/shutdown.log"
run_shutdown single_empty NO_POWEROFF=1
check "NO_POWEROFF: rc=0" "0" "$?"
check "NO_POWEROFF: k3s gestoppt" "yes" "$(grep -q 'stop k3s' "$T/systemctl_calls.log" && echo yes || echo no)"
check "NO_POWEROFF: kein poweroff" "no" "$(grep -q 'poweroff' "$T/systemctl_calls.log" && echo yes || echo no)"
check "NO_POWEROFF: Hinweis geloggt" "yes" "$(grep -q 'NO_POWEROFF=1' "$T/shutdown.log" && echo yes || echo no)"

# ── T3: cico-uncordon-Skriptlogik ────────────────────────────────────────────
extract_heredoc "$REPO/modules_V1/05_addons.sh" "<< 'UNCORDON_SCRIPT'" "UNCORDON_SCRIPT" \
  > "$T/cico-uncordon"
chmod +x "$T/cico-uncordon"

cat > "$T/kubectl_uncordon.sh" << 'KUBECTL_EOF'
#!/usr/bin/env bash
case "${KUBECTL_SCENARIO}" in
  cordoned)
    case "$*" in
      *"get nodes -o name"*) echo "node/test-node" ;;
      *"get node test-node"*"jsonpath"*) echo "true" ;;
      *"get node test-node"*) exit 0 ;;
      *"get nodes"*) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  schedulable)
    case "$*" in
      *"get nodes -o name"*) echo "node/test-node" ;;
      *"get node test-node"*"jsonpath"*) echo "false" ;;
      *"get node test-node"*) exit 0 ;;
      *"get nodes"*) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  multi)
    case "$*" in
      *"get nodes -o name"*) printf 'node/a\nnode/b\n' ;;
      *"get nodes"*) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  api_down)
    case "$*" in
      *"get nodes"*) exit 1 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
KUBECTL_EOF

run_uncordon() {
  local scenario="$1"; shift
  (
    export KUBECTL_SCRIPT="$T/kubectl_uncordon.sh"
    export KUBECTL_SCENARIO="$scenario"
    export KUBECTL_CALL_LOG="$T/kubectl_calls.log"
    : > "$KUBECTL_CALL_LOG"
    local kv
    for kv in "$@"; do export "${kv%%=*}=${kv#*=}"; done
    "$T/cico-uncordon"
  )
}

# T3a: cordonierter Node -> uncordon, rc=0
run_uncordon cordoned > "$T/uncordon.out" 2>&1
check "uncordon cordoned: rc=0" "0" "$?"
check "uncordon cordoned: uncordon aufgerufen" "yes" "$(grep -q 'uncordon' "$T/kubectl_calls.log" && echo yes || echo no)"

# T3b: schedulable Node -> kein uncordon, rc=0
run_uncordon schedulable > "$T/uncordon.out" 2>&1
check "uncordon schedulable: rc=0" "0" "$?"
check "uncordon schedulable: kein uncordon" "no" "$(grep -q 'uncordon' "$T/kubectl_calls.log" && echo yes || echo no)"

# T3c: mehrere Nodes -> rc=1
run_uncordon multi > "$T/uncordon.out" 2>&1
check "uncordon multi: rc=1" "1" "$?"
check "uncordon multi: Fehlermeldung" "yes" "$(grep -q 'nicht eindeutig' "$T/uncordon.out" && echo yes || echo no)"

# T3d: K3S_NODE-Override
run_uncordon cordoned K3S_NODE=my-node > "$T/uncordon.out" 2>&1
check "uncordon K3S_NODE: rc=0" "0" "$?"

# T3e: API nicht erreichbar -> rc=1
run_uncordon api_down > "$T/uncordon.out" 2>&1
check "uncordon api_down: rc=1" "1" "$?"
check "uncordon api_down: Fehlermeldung" "yes" "$(grep -q 'API nach' "$T/uncordon.out" && echo yes || echo no)"

rm -rf "$T"

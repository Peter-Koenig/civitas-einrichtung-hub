#!/usr/bin/env bash
# Suite 28: kubernetes-Client-Pin (install_cc_cli/ensure_k8s_pin) und
# Smoke-Test (verify_k8s_import). Nur Testwerte und Stubs, kein Cluster/Netz.

begin_suite "k8s_pin_smoke"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

# ── Szenario (e): T1 Fruehpfad installiert den Pin nach ────────────────────────
EV="$T/venv"
mkdir -p "$EV/bin"
cat > "$EV/bin/pip" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  show)
    case "$2" in
      cc-cli) echo "Version: 1.5.0" ;;
      kubernetes) echo "Version: 37.0.0" ;;
    esac
    ;;
  install)
    printf 'install %s\n' "$*" >> "${PIP_LOG:?}"
    ;;
esac
exit 0
STUB
# venv-python meldet "nicht erfuellt" (Packaging fehlt oder Pin verletzt).
cat > "$EV/bin/python3" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$EV/bin/ansible" <<'STUB'
#!/usr/bin/env bash
echo "ansible [core 2.17.0]"
exit 0
STUB
cat > "$EV/bin/ansible-galaxy" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  echo "kubernetes.core  4.0.0"
fi
exit 0
STUB
touch "$EV/bin/cc_cli"
chmod +x "$EV/bin/pip" "$EV/bin/python3" "$EV/bin/ansible" "$EV/bin/ansible-galaxy" "$EV/bin/cc_cli"

export CC_CLI_VENV_PATH="$EV"
export CC_CLI_VERSION="1.5.0"
export K8S_PY_PIN="kubernetes>=24.2.0,<37"
export PIP_LOG="$T/pip.log"
: > "$PIP_LOG"
: > "$LOGBUF"
install_cc_cli >/dev/null 2>&1
check "e Pin installiert"        "yes" "$(grep -q 'install --quiet kubernetes>=24.2.0,<37' "$PIP_LOG" && echo yes || echo no)"
check "e venv nicht neu erzeugt" "no"  "$(grep -q 'reinstalliere' "$LOGBUF" && echo yes || echo no)"
check "e Versionen geloggt"      "yes" "$(grep -q 'venv-Versionen' "$LOGBUF" && echo yes || echo no)"

# ── Szenario (f): T2 Import-Fehler fuehrt zum Abbruch vor cc_cli exec ─────────
FV="$T/venv_f"
mkdir -p "$FV/bin"
cat > "$FV/bin/python3" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"client.apis"*)
    echo "DeprecationWarning: kubernetes.client.apis is renamed"
    echo "ImportError: cannot import name 'core_v1_api' from 'kubernetes.client.apis'"
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$FV/bin/python3"

export CC_CLI_VENV_PATH="$FV"
: > "$LOGBUF"
( set -e; verify_k8s_import >/dev/null 2>&1 )
check "f Abbruch (Exit 1)"       "1"   "$?"
check "f Hinweis auf K8S_PY_PIN" "yes" "$(grep -q 'K8S_PY_PIN' "$LOGBUF" && echo yes || echo no)"
check "f Importfehler gemeldet"  "yes" "$(grep -q 'fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

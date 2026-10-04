#!/usr/bin/env bash
# Suite 08: 03_preflight.sh check_tools — jq als Pflichtwerkzeug nachinstallieren.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "check_tools_jq"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"
APTLOG="$T/apt-get.log"
JQ_INSTALLED="$T/jq-installed"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Stubs für die externen Abhängigkeiten von check_tools.
wait_for_apt_lock() { :; }
is_installed() {
  [[ "$1" == "jq" ]] || return 0
  [[ -f "$JQ_INSTALLED" ]] && return 0 || return 1
}
dpkg() { return 0; }   # alle optionalen Pakete gelten als installiert
apt-get() {
  echo "apt-get $*" >> "$APTLOG"
  case "$*" in
    *"install -y jq"*) touch "$JQ_INSTALLED" ;;
  esac
  return 0
}
yq() {
  case "$*" in
    *"--version"*) echo "yq (https://github.com/mikefarah/yq) version v4.44.3" ;;
    *) return 0 ;;
  esac
}

WG_ENABLED=false

# shellcheck source=../../modules_V1/03_preflight.sh
source "$REPO/modules_V1/03_preflight.sh"
set +e

check_tools

check "jq als Pflichtpaket installiert" "yes" "$(grep -q 'apt-get install -y jq' "$APTLOG" && echo yes || echo no)"
check "jq nicht als optionales Paket" "no" "$(grep -q 'vim htop plocate' "$APTLOG" && echo yes || echo no)"

rm -rf "$T"

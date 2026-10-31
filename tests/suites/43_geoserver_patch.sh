#!/usr/bin/env bash
# Suite 43: apply_patches — wendet patches_V1s auf den Klon an (GeoServer-Wartezeit).

begin_suite "apply_patches"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

# Fixture: Zielpfad aus dem Upstream-Spiegel (read-only) in ein echtes Git-Repo.
UPSTREAM=/srv/p2d2/repos/CiCo_V1-ressources/civitas-core
if [[ ! -d "$UPSTREAM" ]]; then
  echo "SKIP: Upstream-Spiegel nicht vorhanden ($UPSTREAM)"
  rm -rf "$T"
  exit 0
fi

FIX="$T/repo"
git init -q "$FIX"
git -C "$FIX" config user.email t@t
git -C "$FIX" config user.name t
git -C "$UPSTREAM" archive v1.8.1 core_platform/tasks/geodata/install/geoserver_setup_role_service.yml | tar -x -C "$FIX"
git -C "$FIX" add -A
git -C "$FIX" commit -qm fixture

export SCRIPT_DIR="$REPO"
export CC_V1_REPO_PATH="$FIX"
export CC_V1_REPO_TAG="v1.8.1"

# 1) Patch wird angewendet; der wait_for-Task mit timeout: 10 ist vorhanden.
( apply_patches >/dev/null 2>&1 ); rc=$?
check "Patch angewendet rc=0" "0" "$rc"
check "wait_for-Task vorhanden" "yes" "$(grep -q 'GeoServer: Wait until the new admin password is accepted' "$FIX/core_platform/tasks/geodata/install/geoserver_setup_role_service.yml" && echo yes || echo no)"
check "timeout: 10 vorhanden" "yes" "$(grep -q 'timeout: 10' "$FIX/core_platform/tasks/geodata/install/geoserver_setup_role_service.yml" && echo yes || echo no)"

# 2) Zweiter Aufruf (bereits angewendet) -> rc 0, Meldung "bereits angewendet".
: > "$LOGBUF"
( apply_patches >/dev/null 2>&1 ); rc=$?
check "zweiter Aufruf rc=0" "0" "$rc"
check "bereits angewendet gemeldet" "yes" "$(grep -q 'bereits angewendet' "$LOGBUF" && echo yes || echo no)"

# 3) Veraenderte Upstream-Datei (Kontextzeile geaendert) -> rc 1, Abbruchmeldung.
git -C "$FIX" reset --hard -q
sed -i 's/  delay: 10/  delay: 99/' "$FIX/core_platform/tasks/geodata/install/geoserver_setup_role_service.yml"
git -C "$FIX" add -A
git -C "$FIX" commit -qm changed
: > "$LOGBUF"
( apply_patches >/dev/null 2>&1 ); rc=$?
check "veraenderte Datei -> rc=1" "1" "$rc"
check "Abbruchmeldung" "yes" "$(grep -q 'passt nicht auf den Stand' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

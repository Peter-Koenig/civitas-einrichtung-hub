#!/usr/bin/env bash
# Suite 38: clone_civitas_repo — Release-Pinning (Tag) + Re-Run-Guard (F2).
# Nutzt ein ECHTES lokales Git-Repo (Remote + Tag) als Fixture, kein git-Stub.

begin_suite "release_pinning"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Gemeinsames Patch-Ziel-Array (wie 01_config.sh, für den Guard + Tests).
CIVITAS_PATCH_TARGETS=(
  "tasks/geodata/configure/integrated_keycloak.yml"
  "tasks/geodata/install/geoserver_setup_role_service.yml"
  "tasks/access/keycloak/idm-config/keycloak_8_users.yml"
  "tasks/access/keycloak/idm-config/keycloak_5_clients.yml"
  "tasks/dashboard/superset.yml"
  "tasks/datacatalog/piveau.yml"
  "tasks/geodata/install/components/masterportal.yml"
)

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

# ── Fixture: lokales Remote-Repo mit Tag v1.8.1 ─────────────────────────────
REMOTE="$T/remote"
mkdir -p "$REMOTE"
git -C "$REMOTE" init -q
git -C "$REMOTE" config user.email test@example.org
git -C "$REMOTE" config user.name test
mkdir -p "$REMOTE/core_platform/tasks/geodata/install" \
         "$REMOTE/core_platform/tasks/geodata/configure" \
         "$REMOTE/core_platform/tasks/access/keycloak/idm-config" \
         "$REMOTE/core_platform/tasks/dashboard" \
         "$REMOTE/core_platform/tasks/datacatalog" \
         "$REMOTE/core_platform/templates/access/keycloak" \
         "$REMOTE/core_platform/tasks/geodata/install/components"
printf 'playbook\n' > "$REMOTE/core_platform/playbook.yml"
for f in \
  tasks/geodata/install/portal_backend.yml \
  templates/access/keycloak/keycloak-values.yaml \
  "${CIVITAS_PATCH_TARGETS[@]}"; do
  printf 'original\n' > "$REMOTE/core_platform/$f"
done
git -C "$REMOTE" add -A
git -C "$REMOTE" commit -qm 'fixture v1.8.1'
git -C "$REMOTE" tag v1.8.1
PIN_SHA="$(git -C "$REMOTE" rev-parse 'v1.8.1^{commit}')"

export CC_V1_REPO_URL="$REMOTE"
export CC_V1_REPO_PATH="$T/repo"
export CC_CLI_PLAYBOOK_DIR="$T/repo/core_platform"
export CC_V1_REPO_TAG="v1.8.1"
export CIVITAS_CORE_LINK="$T/civitas-core"
export CC_V1_REPO_FORCE_CLEAN="false"

# ── 1) Frischer Klon ─────────────────────────────────────────────────────────
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "frischer Klon rc=0" "0" "$rc"
check "describe v1.8.1" "yes" "$(grep -q 'CIVITAS/CORE-Stand: v1.8.1' "$LOGBUF" && echo yes || echo no)"
check "playbook.yml vorhanden" "yes" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/playbook.yml" ]] && echo yes || echo no)"

# ── 2) Re-Run mit erwarteten Installer-Änderungen ───────────────────────────
printf 'overlay-modified\n' > "$CC_CLI_PLAYBOOK_DIR/tasks/geodata/install/portal_backend.yml"
printf 'patched\n' > "$CC_CLI_PLAYBOOK_DIR/tasks/geodata/configure/integrated_keycloak.yml"
mkdir -p "$CC_CLI_PLAYBOOK_DIR/logs" "$CC_CLI_PLAYBOOK_DIR/.overlay_backup"
printf 'log\n' > "$CC_CLI_PLAYBOOK_DIR/logs/x.log"
printf 'backup\n' > "$CC_CLI_PLAYBOOK_DIR/.overlay_backup/portal_backend.yml.orig"
printf 'inventory\n' > "$CC_CLI_PLAYBOOK_DIR/cc_cli_inventory.yml"
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "Re-Run (erwartete Änderungen) rc=0" "0" "$rc"
check "Overlay-Datei zurückgesetzt" "original" "$(cat "$CC_CLI_PLAYBOOK_DIR/tasks/geodata/install/portal_backend.yml")"
check "Patch-Datei zurückgesetzt" "original" "$(cat "$CC_CLI_PLAYBOOK_DIR/tasks/geodata/configure/integrated_keycloak.yml")"
check "logs/x.log bleibt" "yes" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/logs/x.log" ]] && echo yes || echo no)"
check "Inventory bleibt" "yes" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/cc_cli_inventory.yml" ]] && echo yes || echo no)"
check ".overlay_backup entfernt" "no" "$([[ -d "$CC_CLI_PLAYBOOK_DIR/.overlay_backup" ]] && echo yes || echo no)"

# ── 3) Unerwartete Änderung → Abbruch ───────────────────────────────────────
printf 'manual edit\n' > "$CC_CLI_PLAYBOOK_DIR/MANUAL.txt"
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "unerwartete Änderung -> rc=1" "1" "$rc"
check "MANUAL.txt in Meldung" "yes" "$(grep -q 'MANUAL.txt' "$LOGBUF" && echo yes || echo no)"
check "MANUAL.txt bleibt" "yes" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/MANUAL.txt" ]] && echo yes || echo no)"

# ── 4) FORCE-CLEAN → Erfolg trotz unerwarteter Änderung ─────────────────────
export CC_V1_REPO_FORCE_CLEAN="true"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "FORCE-CLEAN rc=0" "0" "$rc"
check "MANUAL.txt entfernt" "no" "$([[ -f "$CC_CLI_PLAYBOOK_DIR/MANUAL.txt" ]] && echo yes || echo no)"
export CC_V1_REPO_FORCE_CLEAN="false"

# ── 5) Tag-Wechsel (neuer Commit + neues Tag) ───────────────────────────────
printf 'playbook v1.8.2\n' > "$REMOTE/core_platform/playbook.yml"
git -C "$REMOTE" add -A
git -C "$REMOTE" commit -qm 'fixture v1.8.2'
git -C "$REMOTE" tag v1.8.2
export CC_V1_REPO_TAG="v1.8.2"
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "Tag-Wechsel rc=0" "0" "$rc"
check "describe v1.8.2" "yes" "$(grep -q 'CIVITAS/CORE-Stand: v1.8.2' "$LOGBUF" && echo yes || echo no)"

# ── 5b) Commit-Pin (zusätzlich zum Tag) ─────────────────────────────────────
export CC_V1_REPO_TAG=v1.8.1

# 5b.1 Pin passt.
export CC_V1_REPO_COMMIT="$PIN_SHA"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "Pin passt -> rc=0" "0" "$rc"

# 5b.2 Pin falsch -> rc=1 mit dem tatsächlichen SHA in der Meldung.
export CC_V1_REPO_COMMIT="0000000000000000000000000000000000000000"
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "Pin falsch -> rc=1" "1" "$rc"
check "SHA in Pin-Meldung" "yes" "$(grep -q "$PIN_SHA" "$LOGBUF" && echo yes || echo no)"

# 5b.3 Leerer Pin -> Warnung, ok.
export CC_V1_REPO_COMMIT=""
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "leerer Pin -> rc=0" "0" "$rc"
check "Warnung Kein Commit-Pin" "yes" "$(grep -q 'Kein Commit-Pin' "$LOGBUF" && echo yes || echo no)"

# 5b.4 Anderer Tag ohne Pin -> Warnung, ok.
export CC_V1_REPO_TAG=v1.8.2
export CC_V1_REPO_COMMIT=""
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "anderer Tag ohne Pin -> rc=0" "0" "$rc"
check "anderer Tag Warnung" "yes" "$(grep -q 'Kein Commit-Pin' "$LOGBUF" && echo yes || echo no)"

# 5b.5 Tag auf dem Remote verschieben -> fetch (ohne --force) oder Pin bricht ab.
printf 'moved\n' > "$REMOTE/core_platform/playbook.yml"
git -C "$REMOTE" add -A
git -C "$REMOTE" commit -qm 'move v1.8.1'
git -C "$REMOTE" tag -f v1.8.1
export CC_V1_REPO_TAG=v1.8.1
export CC_V1_REPO_COMMIT="$PIN_SHA"
: > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "verschobener Tag -> Abbruch" "1" "$rc"
check "Abbruch-Meldung fetch/Pin" "yes" "$(grep -q -e 'git fetch --tags fehlgeschlagen' -e 'Commit-Pin verletzt' "$LOGBUF" && echo yes || echo no)"

# ── 6) Statisch: Patch-Funktionen nutzen das gemeinsame Array ────────────────
check "patch_playbook_urls nutzt Array" "yes" "$(grep -q 'CIVITAS_PATCH_TARGETS' "$REPO/modules_V1s/06a_network_certs.sh" && echo yes || echo no)"
check "patch_masterportal_release_name nutzt Array" "yes" "$(grep -q 'CIVITAS_PATCH_TARGETS' "$REPO/modules_V1s/06_civitas.sh" && echo yes || echo no)"

rm -rf "$T"

#!/usr/bin/env bash
# Suite 38: clone_civitas_repo — Release-Pinning auf Tag (fetch --tags + checkout,
# kein pull --ff-only), describe-Ausgabe im Log. Nur git-Stub + Fixture-Klon.

begin_suite "release_pinning"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

cat > "$STUBS/git" <<'GIT'
#!/usr/bin/env bash
if [ -n "${GIT_CALL_LOG:-}" ]; then
  printf 'git %s\n' "$*" >> "$GIT_CALL_LOG"
fi
case "$1" in
  clone)
    last=""
    for a in "$@"; do last="$a"; done
    mkdir -p "$last/.git" "$last/core_platform"
    touch "$last/core_platform/playbook.yml"
    ;;
  -C)
    case "$3" in
      status) : ;;                     # sauber
      fetch) : ;;
      checkout) : ;;
      describe) printf 'v1.8.1\n' ;;
      rev-parse) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
    esac
    ;;
esac
exit 0
GIT
chmod +x "$STUBS/git"

export GIT_CALL_LOG="$T/git.log"

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

export CC_V1_REPO_TAG="v1.8.1"
export CC_V1_REPO_URL="https://gitlab.com/example/civitas-core.git"
export CC_V1_REPO_PATH="$T/repo"
export CC_CLI_PLAYBOOK_DIR="$CC_V1_REPO_PATH/core_platform"
export CIVITAS_CORE_LINK="$T/civitas-core"

# ── Frischer Klon ────────────────────────────────────────────────────────────
: > "$GIT_CALL_LOG"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "frischer Klon rc=0" "0" "$rc"
check "clone mit --branch v1.8.1 --single-branch" "yes" \
  "$(grep -q 'clone --branch v1.8.1 --single-branch' "$GIT_CALL_LOG" && echo yes || echo no)"
check "describe im Log" "yes" "$(grep -q 'CIVITAS/CORE-Stand: v1.8.1' "$LOGBUF" && echo yes || echo no)"

# ── Re-Run (bestehendes Repo) ───────────────────────────────────────────────
rm -rf "$CC_V1_REPO_PATH"
mkdir -p "$CC_V1_REPO_PATH/.git" "$CC_V1_REPO_PATH/core_platform"
touch "$CC_V1_REPO_PATH/core_platform/playbook.yml"
: > "$GIT_CALL_LOG"; : > "$LOGBUF"
( clone_civitas_repo >/dev/null 2>&1 ); rc=$?
check "Re-Run rc=0" "0" "$rc"
check "fetch --tags aufgerufen" "yes" "$(grep -q 'fetch --tags origin' "$GIT_CALL_LOG" && echo yes || echo no)"
check "checkout --force v1.8.1 aufgerufen" "yes" "$(grep -q 'checkout --force v1.8.1' "$GIT_CALL_LOG" && echo yes || echo no)"
check "kein pull --ff-only" "no" "$(grep -q 'pull --ff-only' "$GIT_CALL_LOG" && echo yes || echo no)"

rm -rf "$T"

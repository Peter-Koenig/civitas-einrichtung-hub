#!/usr/bin/env bash
# Suite 32: Portal-Backend-Image-Build (V1s) — Bake vs. docker-build-Fallback.
# Prüft: Bake-Pfad wird gewählt, Fallback bei fehlendem Target, Abbruch bei
# fehlendem Buildx, Plattform-Mapping, gepinnter Fork-Stand wird nicht
# überschrieben, Frühwarnung bei Bake-Context im Fallback. Nur Stubs, kein
# Cluster/Netz.

begin_suite "geoportal_backend_bake"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }
is_installed() { command -v "$1" &>/dev/null; }

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_V1s/06c_image_build.sh"
set +e

STUBS="$T/stubs"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"
export DOCKER_LOG="$T/docker.log"
export GIT_LOG="$T/git.log"
export DPKG_LOG="$T/dpkg.log"
export APT_LOG="$T/apt.log"

# ── Stubs ──────────────────────────────────────────────────────────────────────
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG:?}"
if [ "$1" = "buildx" ] && [ "$2" = "version" ]; then
  if [ "${BUILDX_VERSION_OK:-1}" = "1" ]; then exit 0; else exit 1; fi
fi
exit 0
STUB

cat > "$STUBS/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${GIT_LOG:?}"
case "$*" in
  *"rev-parse"*)       echo "deadbeef" ;;
  *"submodule status"*) echo "0000000000000000000000000000000000000000 portal-backend (heads/main)" ;;
esac
exit 0
STUB

cat > "$STUBS/dpkg" <<'STUB'
#!/usr/bin/env bash
printf 'dpkg %s\n' "$*" >> "${DPKG_LOG:?}"
if [ "$1" = "--print-architecture" ]; then
  echo "${DPKG_ARCH:-amd64}"
fi
exit 0
STUB

cat > "$STUBS/apt-get" <<'STUB'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "${APT_LOG:?}"
case "$*" in
  *"--dry-run docker.io"*) echo "Purg docker.io:amd64" ;;
  *"docker-buildx"*)
    if [ "${APT_BUILDX_FAIL:-0}" = "1" ]; then exit 1; fi
    ;;
esac
exit 0
STUB

chmod +x "$STUBS/docker" "$STUBS/git" "$STUBS/dpkg" "$STUBS/apt-get"

# ── Fixer Fork-Setup ───────────────────────────────────────────────────────────
FORK="$T/fork"
setup_fork() {
  # $1 = "bake" (Target geoportal_backend) | "nobake" (kein Target) | "bakecontext" (nur Target backend)
  rm -rf "$FORK"
  mkdir -p "$FORK/.git" "$FORK/portal-config/default"
  case "$1" in
    bake)
      printf 'target "backend" { context = "portal-backend" }\ntarget "geoportal_backend" { dockerfile = "Dockerfile_geoportal_backend" }\n' > "$FORK/docker-bake.hcl"
      printf 'FROM backend\n' > "$FORK/Dockerfile_geoportal_backend"
      ;;
    nobake)
      printf 'FROM node:20-alpine\n' > "$FORK/Dockerfile_geoportal_backend"
      ;;
    bakecontext)
      printf 'target "backend" { context = "portal-backend" }\n' > "$FORK/docker-bake.hcl"
      printf 'FROM backend\n' > "$FORK/Dockerfile_geoportal_backend"
      ;;
  esac
}

export V1S_FORK_PATH="$FORK"
export V1S_FORK_URL="https://example.invalid/fork.git"
export V1S_FORK_BRANCH="main"
export V1S_INSTANCE_NAME="Standard"
export V1S_IMAGE_TAG="v1s-test"
export V1S_IMAGE_REF="geoportal_backend:v1s-test"
export V1S_DOCKER_INSTALLED_BY_SCRIPT="false"
export V1S_FORK_REF=""

run_build() {
  ( build_geoportal_backend_image >/dev/null 2>&1 )
}

# ── (A) Bake-Pfad wird gewählt ─────────────────────────────────────────────────
setup_fork "bake"
export BUILDX_VERSION_OK=1 DPKG_ARCH=amd64 APT_BUILDX_FAIL=0
: > "$DOCKER_LOG"; : > "$GIT_LOG"; : > "$LOGBUF"
run_build
check "A Bake-Pfad Exit 0"            "0"   "$?"
check "A bake aufgerufen"             "yes" "$(grep -q 'buildx bake geoportal_backend' "$DOCKER_LOG" && echo yes || echo no)"
check "A Plattform linux/amd64"       "yes" "$(grep -q '\*\.platform=linux/amd64' "$DOCKER_LOG" && echo yes || echo no)"
check "A Tag überschrieben"           "yes" "$(grep -q 'geoportal_backend.tags=geoportal_backend:v1s-test' "$DOCKER_LOG" && echo yes || echo no)"
check "A kein docker build"           "no"  "$(grep -q 'docker build ' "$DOCKER_LOG" && echo yes || echo no)"
check "A Image verifiziert (inspect)" "yes" "$(grep -q 'image inspect geoportal_backend:v1s-test' "$DOCKER_LOG" && echo yes || echo no)"

# ── (B) Fallback bei fehlendem Bake-Target ─────────────────────────────────────
setup_fork "nobake"
export BUILDX_VERSION_OK=1 DPKG_ARCH=amd64 APT_BUILDX_FAIL=0
: > "$DOCKER_LOG"; : > "$GIT_LOG"
run_build
check "B Fallback Exit 0"      "0"   "$?"
check "B docker build"         "yes" "$(grep -q 'docker build -f Dockerfile_geoportal_backend' "$DOCKER_LOG" && echo yes || echo no)"
check "B kein bake"            "no"  "$(grep -q 'buildx bake' "$DOCKER_LOG" && echo yes || echo no)"

# ── (C) Abbruch bei fehlendem Buildx (Install schlägt fehl) ───────────────────
setup_fork "bake"
export BUILDX_VERSION_OK=0 DPKG_ARCH=amd64 APT_BUILDX_FAIL=1
: > "$DOCKER_LOG"; : > "$APT_LOG"; : > "$LOGBUF"
run_build
check "C Buildx fehlt -> Exit 1"       "1"   "$?"
check "C docker-buildx installiert"    "yes" "$(grep -q 'docker-buildx' "$APT_LOG" && echo yes || echo no)"
check "C Fehlermeldung"                "yes" "$(grep -q 'docker-buildx-Installation fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

# ── (D) Plattform-Mapping ──────────────────────────────────────────────────────
setup_fork "bake"
export BUILDX_VERSION_OK=1 APT_BUILDX_FAIL=0
export DPKG_ARCH=amd64
: > "$DOCKER_LOG"
run_build
check "D amd64 -> linux/amd64" "yes" "$(grep -q '\*\.platform=linux/amd64' "$DOCKER_LOG" && echo yes || echo no)"

export DPKG_ARCH=arm64
: > "$DOCKER_LOG"
run_build
check "D arm64 -> linux/arm64" "yes" "$(grep -q '\*\.platform=linux/arm64' "$DOCKER_LOG" && echo yes || echo no)"

export DPKG_ARCH=ppc64le
: > "$LOGBUF"
run_build
check "D unbekannte Arch -> Exit 1" "1" "$?"
check "D Arch-Meldung"               "yes" "$(grep -q 'Nicht unterstützte Host-Architektur' "$LOGBUF" && echo yes || echo no)"

# ── (E) Gepinnter Fork-Stand wird nicht überschrieben ─────────────────────────
setup_fork "bake"
export DPKG_ARCH=amd64
export V1S_FORK_REF="c8d6b74"
: > "$GIT_LOG"
run_build
check "E checkout --detach"     "yes" "$(grep -q 'checkout --detach c8d6b74' "$GIT_LOG" && echo yes || echo no)"
check "E kein pull --ff-only"   "no"  "$(grep -q 'pull --ff-only' "$GIT_LOG" && echo yes || echo no)"

# ── (F) Ungepinnt -> pull --ff-only + Warnung ─────────────────────────────────
export V1S_FORK_REF=""
: > "$GIT_LOG"; : > "$LOGBUF"
run_build
check "F pull --ff-only"        "yes" "$(grep -q 'pull --ff-only' "$GIT_LOG" && echo yes || echo no)"
check "F Warnung ungepinnt"     "yes" "$(grep -q 'Fork-Stand nicht gepinnt' "$LOGBUF" && echo yes || echo no)"

# ── (G) Frühwarnung: Bake-Context im Fallback ─────────────────────────────────
setup_fork "bakecontext"
export BUILDX_VERSION_OK=1 APT_BUILDX_FAIL=0 DPKG_ARCH=amd64
: > "$LOGBUF"
run_build
check "G Fallback+Bake-Context -> Exit 1" "1"   "$?"
check "G Frühwarn-Meldung"               "yes" "$(grep -q 'Bake-Context als FROM-Basis' "$LOGBUF" && echo yes || echo no)"

rm -rf "$T"

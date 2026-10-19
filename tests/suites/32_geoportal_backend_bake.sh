#!/usr/bin/env bash
# Suite 32: Portal-Backend-Image-Build (V1s) — Bake vs. docker-build-Fallback.
# Prüft: Bake-Pfad, Fallback, Buildx-Abbruch, Plattform-Mapping, Pin-Pfad
# (frischer Klon + vorhandener Klon, nicht überschrieben), Frühwarnung,
# temporäre Docker-Installation inkl. Deinstallation, Verifikation vor Import.
# Nur Stubs, kein Cluster/Netz.

begin_suite "geoportal_backend_bake"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }
is_installed() {
  if [ "$1" = "docker" ] && [ "${FAKE_NO_DOCKER:-0}" = "1" ]; then
    return 1
  fi
  command -v "$1" &>/dev/null
}

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_V1s/06c_image_build.sh"
set +e

# Echtes Git für Fall M (vor PATH-Ergänzung um das Stub-Verzeichnis sichern).
REAL_PATH="$PATH"

STUBS="$T/stubs"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"
export DOCKER_LOG="$T/docker.log"
export GIT_LOG="$T/git.log"
export DPKG_LOG="$T/dpkg.log"
export APT_LOG="$T/apt.log"
export K3S_LOG="$T/k3s.log"

# ── Stubs ──────────────────────────────────────────────────────────────────────
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_LOG:?}"
if [ "$1" = "buildx" ] && [ "$2" = "version" ]; then
  if [ "${BUILDX_VERSION_OK:-1}" = "1" ]; then exit 0; else exit 1; fi
fi
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  if [ "${DOCKER_INSPECT_FAIL:-0}" = "1" ]; then exit 1; fi
fi
exit 0
STUB

cat > "$STUBS/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${GIT_LOG:?}"
if [ "$1" = "-C" ]; then shift 2; fi
cmd="$1"
case "$cmd" in
  clone)
    dst=""; for a in "$@"; do dst="$a"; done
    mkdir -p "$dst/.git"
    ;;
  fetch)
    if [ "${GIT_FETCH_FAIL:-0}" = "1" ]; then
      case "$*" in
        *" --tags "*) exit 128 ;;   # --tags MIT Refspec (abgekürzter Hash nicht holbar)
      esac
    fi
    ;;
  checkout)
    if [ "${GIT_CHECKOUT_FAIL:-0}" = "1" ]; then
      case "$*" in
        *"--detach"*) exit 1 ;;
      esac
    fi
    ;;
  rev-parse) echo "deadbeef" ;;
  submodule)
    case "$*" in
      *"status"*) echo "0000000000000000000000000000000000000000 portal-backend (heads/main)" ;;
    esac
    ;;
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
  *"--dry-run docker.io"*) echo "Purg docker.io [1.0]" ;;
  *"docker-buildx"*)
    if [ "${APT_BUILDX_FAIL:-0}" = "1" ]; then exit 1; fi
    ;;
esac
exit 0
STUB

cat > "$STUBS/k3s" <<'STUB'
#!/usr/bin/env bash
printf 'k3s %s\n' "$*" >> "${K3S_LOG:?}"
cat >/dev/null
exit 0
STUB

chmod +x "$STUBS/docker" "$STUBS/git" "$STUBS/dpkg" "$STUBS/apt-get" "$STUBS/k3s"

# ── Fixer Fork-Setup ───────────────────────────────────────────────────────────
FORK="$T/fork"
setup_fork() {
  # $1 = "bake" | "nobake" | "bakecontext"; $2 = "fresh" (ohne .git)
  rm -rf "$FORK"
  mkdir -p "$FORK/portal-config/default"
  [ "${2:-}" = "fresh" ] || mkdir -p "$FORK/.git"
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

reset_flags() {
  export BUILDX_VERSION_OK=1
  export APT_BUILDX_FAIL=0
  export DPKG_ARCH=amd64
  export FAKE_NO_DOCKER=0
  export DOCKER_INSPECT_FAIL=0
  export GIT_CHECKOUT_FAIL=0
  export GIT_FETCH_FAIL=0
  export V1S_FORK_REF=""
}

reset_logs() {
  : > "$DOCKER_LOG"; : > "$GIT_LOG"; : > "$DPKG_LOG"; : > "$APT_LOG"; : > "$K3S_LOG"; : > "$LOGBUF"
}

export V1S_FORK_PATH="$FORK"
export V1S_FORK_URL="https://example.invalid/fork.git"
export V1S_FORK_BRANCH="main"
export V1S_INSTANCE_NAME="Standard"
export V1S_IMAGE_TAG="v1s-test"
export V1S_IMAGE_REF="geoportal_backend:v1s-test"
export V1S_DOCKER_INSTALLED_BY_SCRIPT="false"

run_build() {
  ( build_geoportal_backend_image >/dev/null 2>&1 )
}

# ── (A) Bake-Pfad wird gewählt ─────────────────────────────────────────────────
setup_fork "bake"; reset_flags; reset_logs
run_build
check "A Bake-Pfad Exit 0"            "0"   "$?"
check "A bake aufgerufen"             "yes" "$(grep -q 'buildx bake geoportal_backend' "$DOCKER_LOG" && echo yes || echo no)"
check "A Plattform linux/amd64"       "yes" "$(grep -q '\*\.platform=linux/amd64' "$DOCKER_LOG" && echo yes || echo no)"
check "A Tag überschrieben"           "yes" "$(grep -q 'geoportal_backend.tags=geoportal_backend:v1s-test' "$DOCKER_LOG" && echo yes || echo no)"
check "A kein docker build"           "no"  "$(grep -q 'docker build ' "$DOCKER_LOG" && echo yes || echo no)"
check "A Image verifiziert (inspect)" "yes" "$(grep -q 'image inspect geoportal_backend:v1s-test' "$DOCKER_LOG" && echo yes || echo no)"
check "A k3s ctr import (k8s.io)"     "yes" "$(grep -q 'ctr -n k8s.io images import -' "$K3S_LOG" && echo yes || echo no)"

# ── (B) Fallback bei fehlendem Bake-Target ─────────────────────────────────────
setup_fork "nobake"; reset_flags; reset_logs
run_build
check "B Fallback Exit 0"      "0"   "$?"
check "B docker build"         "yes" "$(grep -q 'docker build -f Dockerfile_geoportal_backend' "$DOCKER_LOG" && echo yes || echo no)"
check "B kein bake"            "no"  "$(grep -q 'buildx bake' "$DOCKER_LOG" && echo yes || echo no)"

# ── (C) Abbruch bei fehlendem Buildx (Install schlägt fehl) ───────────────────
setup_fork "bake"; reset_flags; reset_logs
export BUILDX_VERSION_OK=0 APT_BUILDX_FAIL=1
run_build
check "C Buildx fehlt -> Exit 1"       "1"   "$?"
check "C docker-buildx installiert"    "yes" "$(grep -q 'docker-buildx' "$APT_LOG" && echo yes || echo no)"
check "C Fehlermeldung"                "yes" "$(grep -q 'docker-buildx-Installation fehlgeschlagen' "$LOGBUF" && echo yes || echo no)"

# ── (D) Plattform-Mapping ──────────────────────────────────────────────────────
setup_fork "bake"; reset_flags; reset_logs
run_build
check "D amd64 -> linux/amd64" "yes" "$(grep -q '\*\.platform=linux/amd64' "$DOCKER_LOG" && echo yes || echo no)"

reset_logs; export DPKG_ARCH=arm64
run_build
check "D arm64 -> linux/arm64" "yes" "$(grep -q '\*\.platform=linux/arm64' "$DOCKER_LOG" && echo yes || echo no)"

reset_logs; export DPKG_ARCH=ppc64le
run_build
check "D unbekannte Arch -> Exit 1" "1" "$?"
check "D Arch-Meldung"               "yes" "$(grep -q 'Nicht unterstützte Host-Architektur' "$LOGBUF" && echo yes || echo no)"

# ── (E) Gepinnter Fork-Stand (vorhandener Klon) wird nicht überschrieben ──────
# E1: Fetch-Erfolgsfall.
setup_fork "bake"; reset_flags; reset_logs
export V1S_FORK_REF="c8d6b74" GIT_FETCH_FAIL=0
run_build
check "E1 checkout --detach"   "yes" "$(grep -q 'checkout --force --detach c8d6b74' "$GIT_LOG" && echo yes || echo no)"
check "E1 kein pull --ff-only" "no"  "$(grep -q 'pull --ff-only' "$GIT_LOG" && echo yes || echo no)"

# E2: Fetch-Warnpfad (fetch schlägt fehl, checkout läuft trotzdem).
setup_fork "bake"; reset_flags; reset_logs
export V1S_FORK_REF="c8d6b74" GIT_FETCH_FAIL=1
run_build
check "E2 checkout --detach"   "yes" "$(grep -q 'checkout --force --detach c8d6b74' "$GIT_LOG" && echo yes || echo no)"
check "E2 kein pull --ff-only" "no"  "$(grep -q 'pull --ff-only' "$GIT_LOG" && echo yes || echo no)"

# ── (F) Ungepinnt -> pull --ff-only + Warnung ─────────────────────────────────
setup_fork "bake"; reset_flags; reset_logs
run_build
check "F pull --ff-only"        "yes" "$(grep -q 'pull --ff-only' "$GIT_LOG" && echo yes || echo no)"
check "F Warnung ungepinnt"     "yes" "$(grep -q 'Fork-Stand nicht gepinnt' "$LOGBUF" && echo yes || echo no)"

# ── (G) Frühwarnung: Bake-Context im Fallback ─────────────────────────────────
setup_fork "bakecontext"; reset_flags; reset_logs
run_build
check "G Fallback+Bake-Context -> Exit 1" "1"   "$?"
check "G Frühwarn-Meldung"               "yes" "$(grep -q 'Bake-Context als FROM-Basis' "$LOGBUF" && echo yes || echo no)"

# ── (H) Docker nicht vorhanden -> temporär installieren + wieder entfernen ───
setup_fork "bake"; reset_flags; reset_logs
export FAKE_NO_DOCKER=1 BUILDX_VERSION_OK=0
run_build
check "H install docker.io"      "yes" "$(grep -q 'install -y docker.io' "$APT_LOG" && echo yes || echo no)"
check "H install docker-buildx"  "yes" "$(grep -q 'install -y docker-buildx' "$APT_LOG" && echo yes || echo no)"
check "H purge docker.io"        "yes" "$(grep -q 'purge -y docker.io' "$APT_LOG" && echo yes || echo no)"
check "H purge docker-buildx"    "yes" "$(grep -q 'purge -y docker-buildx' "$APT_LOG" && echo yes || echo no)"

# ── (I) Docker vorhanden, Buildx fehlt -> nur Install, kein Purge ─────────────
setup_fork "bake"; reset_flags; reset_logs
export BUILDX_VERSION_OK=0
run_build
check "I install docker-buildx"  "yes" "$(grep -q 'install -y docker-buildx' "$APT_LOG" && echo yes || echo no)"
check "I kein purge docker.io"   "no"  "$(grep -q 'purge -y docker.io' "$APT_LOG" && echo yes || echo no)"
check "I kein purge docker-buildx" "no" "$(grep -q 'purge -y docker-buildx' "$APT_LOG" && echo yes || echo no)"

# ── (J) Verifikation schlägt fehl -> kein Import ──────────────────────────────
setup_fork "bake"; reset_flags; reset_logs
export DOCKER_INSPECT_FAIL=1
run_build
check "J inspect fail -> Exit 1"    "1"   "$?"
check "J Fehlermeldung"             "yes" "$(grep -q 'nach Build nicht vorhanden' "$LOGBUF" && echo yes || echo no)"
check "J kein image save"           "no"  "$(grep -q 'image save' "$DOCKER_LOG" && echo yes || echo no)"
check "J kein k3s ctr"              "no"  "$(grep -q 'ctr' "$K3S_LOG" && echo yes || echo no)"

# ── (K) Frischer Klon mit Pin ─────────────────────────────────────────────────
setup_fork "bake" "fresh"; reset_flags; reset_logs
export V1S_FORK_REF="c8d6b74"
run_build
check "K frischer Klon Exit 0"     "0"   "$?"
check "K fetch ohne Refspec"       "yes" "$(grep -q 'fetch origin --tags$' "$GIT_LOG" && echo yes || echo no)"
check "K checkout --detach"        "yes" "$(grep -q 'checkout --detach c8d6b74' "$GIT_LOG" && echo yes || echo no)"

# ── (L) Frischer Klon, Checkout schlägt fehl -> Abbruch ───────────────────────
setup_fork "bake" "fresh"; reset_flags; reset_logs
export V1S_FORK_REF="c8d6b74" GIT_CHECKOUT_FAIL=1
run_build
check "L checkout fail -> Exit 1"  "1"   "$?"
check "L Fehlermeldung"            "yes" "$(grep -q 'nicht auflösbar' "$LOGBUF" && echo yes || echo no)"

# ── (M) Echtes Git: _v1s_reset_portal_config stellt default/ wieder her ──────
MR="$T/repo-m"
mkdir -p "$MR"
(
  export PATH="$REAL_PATH"
  cd "$MR"
  git init -q -b main 2>/dev/null
  mkdir -p portal-config/default
  echo "x" > portal-config/default/x.txt
  echo "y" > outside.txt
  git add portal-config/default/x.txt outside.txt
  git -c user.name=test -c user.email=test@example.invalid commit -q -m basis
)
# Schritt 2 nachbilden: default -> Standard (getrackt gelöscht, Standard unversioniert).
mv "$MR/portal-config/default" "$MR/portal-config/Standard"
# Unversionierte Datei außerhalb von portal-config/ anlegen.
echo "keep" > "$MR/outside-untracked.txt"

export V1S_FORK_PATH="$MR"
( export PATH="$REAL_PATH"; _v1s_reset_portal_config >/dev/null 2>&1 )
check "M Exit 0"                         "0"   "$?"
check "M default/x.txt wiederhergestellt" "yes" "$([ -f "$MR/portal-config/default/x.txt" ] && echo yes || echo no)"
check "M Standard entfernt"              "no"  "$([ -d "$MR/portal-config/Standard" ] && echo yes || echo no)"
check "M untracked außerhalb bleibt"      "yes" "$([ -f "$MR/outside-untracked.txt" ] && echo yes || echo no)"
check "M getrackte Datei außerhalb bleibt" "yes" "$([ -f "$MR/outside.txt" ] && echo yes || echo no)"

( export PATH="$REAL_PATH"; _v1s_reset_portal_config >/dev/null 2>&1 )
check "M zweiter Aufruf Exit 0"          "0"   "$?"
check "M default/x.txt nach 2. Aufruf"    "yes" "$([ -f "$MR/portal-config/default/x.txt" ] && echo yes || echo no)"

rm -rf "$T"

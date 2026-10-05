#!/usr/bin/env bash
#
# p2d2-Frontend: baut das Runtime-Image für eine Stage auf dem k3s-Node und
# importiert es in k3s (analog GeoServer/MapProxy). Generalisiert aus
# build-de1.sh (Turn 55) — eine Stage als Argument, alle stage-spezifischen
# Buildwerte (PUBLIC_*) kommen aus der .env.p2d2-addon (P2D2_*), nicht mehr
# fest verdrahtet (F5).
#
# Ablauf: git clone (Host) -> docker build (Multi-Stage: npm ci + npm run
#         <build-script> im node:20-Container) -> docker save | k3s ctr import
#
# Aufruf (auf dem k3s-Node, als User mit docker-/k3s-ctr-Zugriff):
#   set -a; source ../.env.p2d2-addon; set +a   # liefert P2D2_GITHUB_TOKEN / P2D2_GITLAB_TOKEN
#   ./build-stage.sh de1                         # main|dev|de1|de2|fv
#
# Determinismus (F4): Der Image-Tag cfg-<12-hex> wird aus den nicht-sensitiven
# Eingaben (Stage, Git-Quelle, Commit, Build-Skript, fünf Buildwerte) berechnet.
# Niemals Tokens/Passwörter in den Hash. Die Berechnung liegt als reine Funktion
# addon_compute_image_tag in modules_addon_V1s/addon_30_frontend.sh.
#
# Tag-Übergabe (F6): Ist FRONTEND_TAG_FILE gesetzt, wird der Tag dorthin
# geschrieben (install_addon_frontend_build setzt die Variable und
# install_addon_frontend liest die Datei). Zusätzlich wird der Tag immer auf
# stdout als __P2D2_IMAGE_TAG__=<tag> ausgegeben.
#
# Idempotenz (F7, Entscheidung): In diesem Turn NICHT umgesetzt. Ein echtes
# "Image existiert -> überspringen" bräuchte die Auflösung des Commit-SHA via
# `git ls-remote` VOR dem Clone; der deterministische Tag hängt aber vom
# aufgelösten Commit ab. Der Tag ist content-adressiert, ein erneuter Lauf
# erzeugt denselben Tag und der Docker-Build nutzt den Layer-Cache. FORCE_REBUILD
# bleibt als Folgearbeit notiert.
#
# Git-Token wird nur für den Host-Clone verwendet (nicht als Build-Arg);
# .git/ wird per .dockerignore aus dem Build-Kontext gehalten.
set -euo pipefail

STAGE="${1:-}"
if [[ -z "${STAGE}" ]]; then
  echo "Fehler: Stage fehlt. Aufruf: $0 {main|dev|de1|de2|fv}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MODULE="${REPO_ROOT}/modules_addon_V1s/addon_30_frontend.sh"

# addon_compute_image_tag (reine Funktion) beziehen, ohne Git/Cluster testbar.
if [[ ! -f "${MODULE}" ]]; then
  echo "Fehler: addon_30_frontend.sh nicht gefunden (${MODULE}) — addon_compute_image_tag fehlt." >&2
  exit 1
fi
# shellcheck disable=SC1090,SC1091
source "${MODULE}"

# require_env <varname> — indirekt lesen; leer/ungesetzt -> Fehler + exit 1.
require_env() {
  local name="$1" val
  val="${!name:-}"
  if [[ -z "${val}" ]]; then
    echo "Fehler: ${name} ist leer — bitte in .env.p2d2-addon setzen (P2D2_*)." >&2
    exit 1
  fi
  printf '%s' "${val}"
}

# ── Stage-spezifische Produktwerte (Git-Quelle/Build-Skript, NICHT Betreiber) ──
# Git-Host, Repo-Pfad und Branch sind Produktwerte (p2d2-Quellrepos), nicht Teil
# des Konfigurationsvertrags. Sie fliessen aber in den deterministischen Tag ein.
case "${STAGE}" in
  main)
    IMAGE="p2d2-frontend-main"
    KEY="MAIN"
    GIT_HOST="gitlab.opencode.de"
    GIT_REPO_PATH="OC000028072444/p2d2.git"
    GIT_BRANCH="main"
    BUILD_SCRIPT="build"
    ;;
  dev)
    IMAGE="p2d2-frontend-dev"
    KEY="DEVELOP"
    GIT_HOST="gitlab.opencode.de"
    GIT_REPO_PATH="OC000028072444/p2d2.git"
    GIT_BRANCH="develop"
    BUILD_SCRIPT="build:develop"
    ;;
  de1)
    IMAGE="p2d2-frontend-de1"
    KEY="DE1"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-de1/main"
    BUILD_SCRIPT="build:de1"
    ;;
  de2)
    IMAGE="p2d2-frontend-de2"
    KEY="DE2"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-de2/main"
    BUILD_SCRIPT="build:de2"
    ;;
  fv)
    IMAGE="p2d2-frontend-fv"
    KEY="FV"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-fv/main"
    BUILD_SCRIPT="build:fv"
    ;;
  *)
    echo "Fehler: unbekannte Stage '${STAGE}' (main|dev|de1|de2|fv)" >&2
    exit 1
    ;;
esac

# ── Buildwerte aus der .env.p2d2-addon (F5, fail-fast ohne Default) ───────────
PUBLIC_SITE_URL="$(require_env "P2D2_${KEY}_PUBLIC_SITE_URL")"
PUBLIC_WFST_WORKSPACE="$(require_env "P2D2_${KEY}_WFST_WORKSPACE")"
PUBLIC_WFST_ENDPOINT="$(require_env "P2D2_BASE_PUBLIC_WFST_ENDPOINT")"
PUBLIC_MAPSERVER_URL="$(require_env "P2D2_BASE_PUBLIC_MAPSERVER_URL")"
DEFAULT_CATEGORY_ICON="$(require_env "P2D2_BASE_DEFAULT_CATEGORY_ICON")"

# ── Skript-Hash (build-stage.sh + Dockerfile + .dockerignore) ──────────────────
SCRIPT_SHA="$(cat "${SCRIPT_DIR}/build-stage.sh" "${SCRIPT_DIR}/Dockerfile" "${SCRIPT_DIR}/.dockerignore" | sha256sum | awk '{print $1}')"

# ── Git-Token je Provider ───────────────────────────────────────────────────
case "${GIT_HOST}" in
  *github*) GIT_TOKEN="${GIT_TOKEN:-${P2D2_GITHUB_TOKEN:-}}" ;;
  *)        GIT_TOKEN="${GIT_TOKEN:-${P2D2_GITLAB_TOKEN:-}}" ;;
esac
if [[ -z "${GIT_TOKEN}" ]]; then
  echo "Fehler: Git-Token nicht gesetzt (${GIT_HOST} erwartet P2D2_GITHUB_TOKEN bzw. P2D2_GITLAB_TOKEN)." >&2
  exit 1
fi

WORKDIR_TMP="$(mktemp -d)"
trap 'rm -rf "$WORKDIR_TMP"' EXIT
APP_DIR="$WORKDIR_TMP/app"

echo ">> Klone ${GIT_HOST}/${GIT_REPO_PATH}@${GIT_BRANCH}"
case "${GIT_HOST}" in
  *github*) AUTH_USER="x-access-token" ;;
  *) AUTH_USER="oauth2" ;;
esac
git clone --depth 1 --branch "${GIT_BRANCH}" \
  "https://${AUTH_USER}:${GIT_TOKEN}@${GIT_HOST}/${GIT_REPO_PATH}" "${APP_DIR}"

cd "${APP_DIR}"

# Aufgelöster Commit des geklonten Standes (Teil des deterministischen Tags).
COMMIT_SHA="$(git rev-parse HEAD)"

# Deterministischer Tag cfg-<12-hex> (F4), nie Secrets im Hash.
TAG="$(addon_compute_image_tag "${STAGE}" "${GIT_HOST}" "${GIT_REPO_PATH}" "${GIT_BRANCH}" \
  "${COMMIT_SHA}" "${SCRIPT_SHA}" "${BUILD_SCRIPT}" \
  "${PUBLIC_SITE_URL}" "${PUBLIC_WFST_ENDPOINT}" "${PUBLIC_WFST_WORKSPACE}" \
  "${PUBLIC_MAPSERVER_URL}" "${DEFAULT_CATEGORY_ICON}")"

# Build-Kontext: Dockerfile + .dockerignore aus dem frontend/-Verzeichnis beziehen.
cp "${SCRIPT_DIR}/Dockerfile" "${APP_DIR}/Dockerfile"
cp "${SCRIPT_DIR}/.dockerignore" "${APP_DIR}/.dockerignore"

echo ">> docker build (npm ci + npm run ${BUILD_SCRIPT} im node:20-Container, Tag ${TAG})"
docker build \
  --build-arg BUILD_SCRIPT="${BUILD_SCRIPT}" \
  --build-arg PUBLIC_SITE_URL="${PUBLIC_SITE_URL}" \
  --build-arg PUBLIC_WFST_ENDPOINT="${PUBLIC_WFST_ENDPOINT}" \
  --build-arg PUBLIC_WFST_WORKSPACE="${PUBLIC_WFST_WORKSPACE}" \
  --build-arg PUBLIC_MAPSERVER_URL="${PUBLIC_MAPSERVER_URL}" \
  --build-arg DEFAULT_CATEGORY_ICON="${DEFAULT_CATEGORY_ICON}" \
  -t "${IMAGE}:${TAG}" "${APP_DIR}"

echo ">> k3s ctr images import"
docker save "${IMAGE}:${TAG}" | k3s ctr -n k8s.io images import -

# Tag-Übergabe (F6): in die Zustandsdatei schreiben, wenn ein Ziel gesetzt ist,
# und immer auf stdout ausgeben.
if [[ -n "${FRONTEND_TAG_FILE:-}" ]]; then
  mkdir -p "$(dirname "${FRONTEND_TAG_FILE}")" 2>/dev/null || true
  printf '%s' "${TAG}" > "${FRONTEND_TAG_FILE}"
fi
echo ">> Fertig: ${IMAGE}:${TAG}"
echo "__P2D2_IMAGE_TAG__=${TAG}"

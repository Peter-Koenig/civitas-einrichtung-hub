#!/usr/bin/env bash
#
# p2d2-Frontend: baut das Runtime-Image für eine Stage auf dem k3s-Node und
# importiert es in k3s (analog GeoServer/MapProxy). Generalisiert aus
# build-de1.sh (Turn 55) — eine Stage als Argument, alle stage-spezifischen
# Werte (Branch, Repo, PUBLIC_*), gemeinsame Basiswerte fest verdrahtet.
#
# Ablauf: git clone (Host) -> docker build (Multi-Stage: npm ci + npm run
#         <build-script> im node:20-Container) -> docker save | k3s ctr import
#
# Aufruf (auf dem k3s-Node, als User mit docker-/k3s-ctr-Zugriff):
#   set -a; source ../.env.p2d2-addon; set +a   # liefert P2D2_GITHUB_TOKEN / P2D2_GITLAB_TOKEN
#   ./build-stage.sh de1                         # main|dev|de1|de2|fv
#
# Git-Token wird nur für den Host-Clone verwendet (nicht als Build-Arg);
# .git/ wird per .dockerignore aus dem Build-Kontext gehalten.
set -euo pipefail

STAGE="${1:-}"
if [[ -z "${STAGE}" ]]; then
  echo "Fehler: Stage fehlt. Aufruf: $0 {main|dev|de1|de2|fv}" >&2
  exit 1
fi

TAG="${TAG:-v1s-2026-09-18}"

# ── Stage-spezifische Werte ─────────────────────────────────────────────────
case "${STAGE}" in
  main)
    IMAGE="p2d2-frontend-main"
    GIT_HOST="gitlab.opencode.de"
    GIT_REPO_PATH="OC000028072444/p2d2.git"
    GIT_BRANCH="main"
    BUILD_SCRIPT="build"
    PUBLIC_SITE_URL="https://www.udp.data-dna.eu"
    PUBLIC_WFST_WORKSPACE="main"
    ;;
  dev)
    IMAGE="p2d2-frontend-dev"
    GIT_HOST="gitlab.opencode.de"
    GIT_REPO_PATH="OC000028072444/p2d2.git"
    GIT_BRANCH="develop"
    BUILD_SCRIPT="build:develop"
    PUBLIC_SITE_URL="https://dev.udp.data-dna.eu"
    PUBLIC_WFST_WORKSPACE="dev"
    ;;
  de1)
    IMAGE="p2d2-frontend-de1"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-de1/main"
    BUILD_SCRIPT="build:de1"
    PUBLIC_SITE_URL="https://f-de1.udp.data-dna.eu"
    PUBLIC_WFST_WORKSPACE="de1"
    ;;
  de2)
    IMAGE="p2d2-frontend-de2"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-de2/main"
    BUILD_SCRIPT="build:de2"
    PUBLIC_SITE_URL="https://f-de2.udp.data-dna.eu"
    PUBLIC_WFST_WORKSPACE="de2"
    ;;
  fv)
    IMAGE="p2d2-frontend-fv"
    GIT_HOST="github.com"
    GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
    GIT_BRANCH="feature/team-fv/main"
    BUILD_SCRIPT="build:fv"
    PUBLIC_SITE_URL="https://f-fv.udp.data-dna.eu"
    PUBLIC_WFST_WORKSPACE="fv"
    ;;
  *)
    echo "Fehler: unbekannte Stage '${STAGE}' (main|dev|de1|de2|fv)" >&2
    exit 1
    ;;
esac

# ── Gemeinsame (nicht stage-spezifische) Werte ──────────────────────────────
PUBLIC_WFST_ENDPOINT="https://geoportal.udp.data-dna.eu/geoserver/ows"
PUBLIC_MAPSERVER_URL="https://geoportal.udp.data-dna.eu/mapserver"
DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"

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

# Build-Kontext: Dockerfile + .dockerignore aus dem frontend/-Verzeichnis beziehen.
cp "$(dirname "$0")/Dockerfile" "${APP_DIR}/Dockerfile"
cp "$(dirname "$0")/.dockerignore" "${APP_DIR}/.dockerignore"

echo ">> docker build (npm ci + npm run ${BUILD_SCRIPT} im node:20-Container)"
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

echo ">> Fertig: ${IMAGE}:${TAG}"

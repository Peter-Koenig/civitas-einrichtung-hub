#!/usr/bin/env bash
#
# p2d2-Frontend: baut das Runtime-Image für Stage "de1" auf dem k3s-Node und
# importiert es in k3s (analog GeoServer/MapProxy).
#
# Ablauf: git clone -> npm ci -> npm run build:de1 (mit PUBLIC_*-Build-Variablen)
#         -> docker build (Dockerfile) -> docker save | k3s ctr images import
#
# Aufruf (auf dem k3s-Node, als User mit docker-/k3s-ctr-Zugriff):
#   set -a; source ../.env.p2d2-addon; set +a   # liefert P2D2_GITHUB_TOKEN
#   ./build-de1.sh
#
# Hinweis: Das Token wird als env übergeben (nicht als Build-Arg), damit es nicht
# im Image-History landet. Für Produktion ggf. BuildKit --secret nutzen.
set -euo pipefail

IMAGE="p2d2-frontend-de1"
TAG="${TAG:-v1s-2026-09-18}"

GIT_HOST="github.com"
GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
GIT_BRANCH="feature/team-de1/main"
BUILD_COMMAND="npm run build:de1"

# GitHub-Token: P2D2_GITHUB_TOKEN (aus .env.p2d2-addon) bevorzugt, sonst GIT_TOKEN.
GIT_TOKEN="${GIT_TOKEN:-${P2D2_GITHUB_TOKEN:-}}"
if [[ -z "${GIT_TOKEN}" ]]; then
  echo "Fehler: P2D2_GITHUB_TOKEN (bzw. GIT_TOKEN) nicht gesetzt." >&2
  exit 1
fi

# Client-seitig eingebackene (public) Build-Variablen für de1.
PUBLIC_SITE_URL="https://f-de1.udp.data-dna.eu"
PUBLIC_WFST_ENDPOINT="https://geoportal.udp.data-dna.eu/geoserver/ows"
PUBLIC_WFST_WORKSPACE="de1"
PUBLIC_MAPSERVER_URL="https://geoportal.udp.data-dna.eu/mapserver"

WORKDIR_TMP="$(mktemp -d)"
trap 'rm -rf "$WORKDIR_TMP"' EXIT
APP_DIR="$WORKDIR_TMP/app"

echo ">> Klone $GIT_HOST/$GIT_REPO_PATH@$GIT_BRANCH"
case "$GIT_HOST" in
  *github*) AUTH_USER="x-access-token" ;;
  *) AUTH_USER="oauth2" ;;
esac
git clone --depth 1 --branch "$GIT_BRANCH" \
  "https://${AUTH_USER}:${GIT_TOKEN}@${GIT_HOST}/${GIT_REPO_PATH}" "$APP_DIR"

cd "$APP_DIR"
echo ">> npm ci"
npm ci

echo ">> npm run build:de1"
export PUBLIC_SITE_URL PUBLIC_WFST_ENDPOINT PUBLIC_WFST_WORKSPACE PUBLIC_MAPSERVER_URL
eval "$BUILD_COMMAND"
test -d dist/server

echo ">> docker build"
cp "$(dirname "$0")/Dockerfile" "$APP_DIR/Dockerfile"
docker build -t "${IMAGE}:${TAG}" "$APP_DIR"

echo ">> k3s ctr images import"
docker save "${IMAGE}:${TAG}" | k3s ctr -n k8s.io images import -

echo ">> Fertig: ${IMAGE}:${TAG}"

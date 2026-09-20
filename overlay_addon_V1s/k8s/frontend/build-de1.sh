#!/usr/bin/env bash
#
# p2d2-Frontend: baut das Runtime-Image für Stage "de1" auf dem k3s-Node und
# importiert es in k3s (analog GeoServer/MapProxy).
#
# Ablauf: git clone (Host) -> docker build (Multi-Stage: npm ci + npm run build:de1
#         im node:20-Container) -> docker save | k3s ctr images import
#
# Der Build läuft IM Container (node:20), NICHT auf dem Host. Der Host braucht nur
# git + docker + k3s ctr — kein Node.js/npm.
#
# Aufruf (auf dem k3s-Node, als User mit docker-/k3s-ctr-Zugriff):
#   set -a; source ../.env.p2d2-addon; set +a   # liefert P2D2_GITHUB_TOKEN
#   ./build-de1.sh
#
# Hinweis: Das Git-Token wird nur für den Host-Clone verwendet (nicht als Build-Arg);
# .git/ wird per .dockerignore aus dem Build-Kontext gehalten.
set -euo pipefail

IMAGE="p2d2-frontend-de1"
TAG="${TAG:-v1s-2026-09-18}"

GIT_HOST="github.com"
GIT_REPO_PATH="Peter-Koenig/p2d2-hub.git"
GIT_BRANCH="feature/team-de1/main"

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
DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"

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

# Build-Kontext: Dockerfile + .dockerignore aus dem frontend/-Verzeichnis beziehen.
cp "$(dirname "$0")/Dockerfile" "$APP_DIR/Dockerfile"
cp "$(dirname "$0")/.dockerignore" "$APP_DIR/.dockerignore"

echo ">> docker build (npm ci + npm run build:de1 im node:20-Container)"
docker build \
  --build-arg PUBLIC_SITE_URL="${PUBLIC_SITE_URL}" \
  --build-arg PUBLIC_WFST_ENDPOINT="${PUBLIC_WFST_ENDPOINT}" \
  --build-arg PUBLIC_WFST_WORKSPACE="${PUBLIC_WFST_WORKSPACE}" \
  --build-arg PUBLIC_MAPSERVER_URL="${PUBLIC_MAPSERVER_URL}" \
  --build-arg DEFAULT_CATEGORY_ICON="${DEFAULT_CATEGORY_ICON}" \
  -t "${IMAGE}:${TAG}" "$APP_DIR"

echo ">> k3s ctr images import"
docker save "${IMAGE}:${TAG}" | k3s ctr -n k8s.io images import -

echo ">> Fertig: ${IMAGE}:${TAG}"

#!/usr/bin/env bash
# Suite 35: addon_10 GeoServer-Mosaic — enabled-Flag, Style, Verifikation.
# Nur Stubs für curl/kubectl; jq/awk/find/base64 real. Kein Cluster/Netz.

begin_suite "addon_geoserver_mosaic"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
export ADDON_SUPPLEMENT_DIR="$REPO/supplement"
export ADDON_GEOTIFF_DIR="$T/geotiffs"

# Fake-GeoTIFF-Ordner mit einer Stadt (koeln).
mkdir -p "$ADDON_GEOTIFF_DIR/koeln"
touch "$ADDON_GEOTIFF_DIR/koeln/granule.tif"

STUBS="$T/stubs"
export STUBS="$STUBS"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

export CURL_LOG="$T/curl.log"
export KUBECTL_LOG="$T/kubectl.log"
export CURL_STORE_ENABLED="${CURL_STORE_ENABLED:-true}"
export CURL_HAS_LAYER="${CURL_HAS_LAYER:-true}"
: > "$CURL_LOG"; : > "$KUBECTL_LOG"

# curl-Stub: protokolliert METHOD|URL (|BODY bei -d), beantwortet Verifikations-GETs.
cat > "$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
args=("$@")
method="GET"; url=""; body=""; out=""; wformat=""; data=0; have_w=0
i=0
while [ "$i" -lt "$#" ]; do
  a="${args[$i]}"
  case "$a" in
    -X) i=$((i+1)); method="${args[$i]}" ;;
    -d) i=$((i+1)); body="${args[$i]}"; data=1 ;;
    -o) i=$((i+1)); out="${args[$i]}" ;;
    -w) i=$((i+1)); wformat="${args[$i]}"; have_w=1 ;;
  esac
  i=$((i+1))
done
url="${args[$#-1]}"

printf '%s|%s' "$method" "$url" >> "$CURL_LOG"
if [ "$data" -eq 1 ]; then printf '|%s' "$body" >> "$CURL_LOG"; fi
printf '\n' >> "$CURL_LOG"

resp="{}"
case "$url" in
  *"coveragestores/friedhofsplaene_koeln_mosaic.json")
    resp="{\"coverageStore\":{\"enabled\":${CURL_STORE_ENABLED:-true}}}" ;;
  *"coverages/friedhoefe_koeln.json")
    resp='{"coverage":{"enabled":true,"nativeBoundingBox":{"minx":354764,"maxx":358892,"miny":5642942,"maxy":5656324}}}' ;;
  *"layers/friedhofsplaene:friedhoefe_koeln.json")
    resp="{\"layer\":{\"enabled\":${CURL_LAYER_ENABLED:-true}}}" ;;
  *"GetCapabilities")
    if [ "${CURL_HAS_LAYER:-true}" = "true" ]; then
      resp='<WMS_Capabilities><Layer><Name>friedhofsplaene:friedhoefe_koeln</Name></Layer></WMS_Capabilities>'
    else
      resp='<WMS_Capabilities/>'
    fi ;;
  *"GetMap")
    resp='PNG-tRNS' ;;
esac

if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then
  printf '%s' "$resp" > "$out"
fi
if [ "$have_w" -eq 1 ]; then
  case "$wformat" in
    *content_type*) printf '200 image/png' ;;
    *) printf '200' ;;
  esac
elif [ -z "$out" ] || [ "$out" == "/dev/null" ]; then
  printf '%s' "$resp"
fi
CURL
chmod +x "$STUBS/curl"

# kubectl-Stub: Secret (base64-Dummies), Pod-Name, exec/cp.
cat > "$STUBS/kubectl" <<'KUB'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$KUBECTL_LOG"
case "$args" in
  *"get secret"*"geoserver-user"*) printf 'YWRtaW4=' ;;
  *"get secret"*"geoserver-password"*) printf 'c2VjcmV0' ;;
  *"get pods"*"-o jsonpath"*) printf 'geoserver-geoserver-0' ;;
  *) exit 0 ;;
esac
KUB
chmod +x "$STUBS/kubectl"

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_10_geoserver.sh"
set +e

# ── Install: enabled-Flag + Style-Schritte ─────────────────────────────────────
: > "$CURL_LOG"; : > "$KUBECTL_LOG"
install_addon_geoserver_mosaic >/dev/null 2>&1
check "Mosaic Install rc=0" "0" "$?"

store_post_body="$(grep -E '^POST\|' "$CURL_LOG" | grep -E '/coveragestores\|' | head -1 | cut -d'|' -f3-)"
check "Store-POST enthält enabled:true" "yes" "$(grep -qF '"enabled":true' <<< "$store_post_body" && echo yes || echo no)"

store_put_body="$(grep -E '^PUT\|' "$CURL_LOG" | grep -E '/coveragestores/friedhofsplaene_koeln_mosaic\|' | head -1 | cut -d'|' -f3-)"
check "Store-PUT (9.5) enthält enabled:true" "yes" "$(grep -qF '"enabled":true' <<< "$store_put_body" && echo yes || echo no)"

check "Style: Ressource POST" "yes" "$(grep -qE '^POST\|.*/styles\|' "$CURL_LOG" && echo yes || echo no)"
check "Style: SLD PUT" "yes" "$(grep -qE '^PUT\|.*/styles/friedhofsplan_transparent' "$CURL_LOG" && echo yes || echo no)"
check "Style: Default-Style am Layer" "yes" "$(grep -qE '^PUT\|.*/layers/friedhofsplaene:friedhoefe_koeln' "$CURL_LOG" && echo yes || echo no)"

# ── Verify: schlägt bei enabled:false fehl ────────────────────────────────────
export CURL_STORE_ENABLED="false"
verify_addon_geoserver_mosaic >/dev/null 2>&1
check "Verify Mosaic: store enabled=false → rc=1" "1" "$?"
unset CURL_STORE_ENABLED

# ── Verify: Layer enabled=false → rc=1 (D.1) ──────────────────────────────────
export CURL_LAYER_ENABLED="false"
verify_addon_geoserver_mosaic >/dev/null 2>&1
check "Verify Mosaic: layer enabled=false → rc=1" "1" "$?"
unset CURL_LAYER_ENABLED

# ── Verify: fehlender Layer in Capabilities → rc=1 ────────────────────────────
export CURL_HAS_LAYER="false"
verify_addon_geoserver_mosaic >/dev/null 2>&1
check "Verify Mosaic: Layer fehlt in Capabilities → rc=1" "1" "$?"
unset CURL_HAS_LAYER

rm -rf "$T"

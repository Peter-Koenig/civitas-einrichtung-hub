#!/usr/bin/env bash
# Suite 34: MapProxy-AddOn — Docker-Lebenszyklus, Image-Build, Pod-Ressourcen,
# Uninstall-Image-Entfernung. Nur Stubs, kein Cluster/Netz/echte Credentials.

begin_suite "mapproxy_addon"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"

# ── Stub-Verzeichnis + Zustandsdateien ────────────────────────────────────────
STUBS="$T/stubs"
export STUBS="$STUBS"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

export APT_INSTALL_LOG="$T/apt-install.log"
export APT_PURGE_LOG="$T/apt-purge.log"
export DOCKER_BUILD_LOG="$T/docker-build.log"
export K3S_IMPORT_LOG="$T/k3s-import.log"
export K3S_RM_LOG="$T/k3s-rm.log"
export K3S_EXPORT_LOG="$T/k3s-export.log"
export K3S_IMAGE_LIST="$T/k3s-images.txt"
export KUBECTL_CALL_LOG="$T/kubectl-call.log"
export KUBECTL_APPLY_STDIN="$T/kubectl-apply-stdin"
export DOCKER_REAL="$STUBS/docker.real"
export CURL_ARGS_LOG="$T/curl-args.log"
export APISIX_BODY_LOG="$T/apisix-body.log"
export APISIX_STATE_DIR="$T/apisix-state"
mkdir -p "$APISIX_STATE_DIR"
: > "$APT_INSTALL_LOG"; : > "$APT_PURGE_LOG"; : > "$DOCKER_BUILD_LOG"; : > "$K3S_IMPORT_LOG"; : > "$K3S_RM_LOG"; : > "$K3S_EXPORT_LOG"; : > "$K3S_IMAGE_LIST"; : > "$KUBECTL_CALL_LOG"; : > "$KUBECTL_APPLY_STDIN"; : > "$CURL_ARGS_LOG"; : > "$APISIX_BODY_LOG"

docker_present() { cp "$DOCKER_REAL" "$STUBS/docker"; chmod +x "$STUBS/docker"; }
# hash -d: verhindert, dass bash nach dem rm einen veralteten Hash-Pfad für
# `command -v docker` zurückliefert (sonst nimmt addon_docker_ensure fälschlich
# "Docker vorhanden" an und setzt ADDON_DOCKER_INSTALLED_BY_SCRIPT nicht).
docker_absent()  { rm -f "$STUBS/docker"; hash -d docker 2>/dev/null || true; }

# docker-Stub (echt, als Vorlage; apt-get install kopiert ihn nach $STUBS/docker).
cat > "$DOCKER_REAL" <<'DOCK'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--version"*) echo "Docker version 26.1.4, build 5650f9b" ;;
  *"info"*) exit 0 ;;
  *"image inspect"*) exit 0 ;;
  *"run"*) if [[ -n "${DOCKER_RUN_FAIL:-}" ]]; then exit 1; fi; exit 0 ;;
  *"load"*) exit 0 ;;
  *"build"*) printf '%s\n' "$args" >> "$DOCKER_BUILD_LOG"; exit 0 ;;
  *"save"*) echo "docker-image-data" ;;
esac
exit 0
DOCK
chmod +x "$DOCKER_REAL"

# apt-get-Stub (zählt install/purge; install simuliert das Erscheinen von docker).
cat > "$STUBS/apt-get" <<'APT'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"install"*"docker.io"*)
    echo "$args" >> "$APT_INSTALL_LOG"
    cp "$DOCKER_REAL" "$STUBS/docker" 2>/dev/null; chmod +x "$STUBS/docker" 2>/dev/null
    exit 0
    ;;
  *"purge"*"--dry-run"*"docker.io"*) echo "Purg docker.io (26.1.4-0ubuntu1) ..." ;;
  *"purge"*"docker.io"*) echo "$args" >> "$APT_PURGE_LOG"; exit 0 ;;
  *"autoremove"*) exit 0 ;;
  *"update"*) exit 0 ;;
esac
exit 0
APT
chmod +x "$STUBS/apt-get"

# k3s-Stub (Image-Liste; import fügt das Image hinzu, rm entfernt es).
cat > "$STUBS/k3s" <<'K3S'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"images ls"*) cat "$K3S_IMAGE_LIST" 2>/dev/null ;;
  *"images import"*)
    echo "$args" >> "$K3S_IMPORT_LOG"
    printf 'docker.io/library/mapproxy:v1s-2026-09-12\n' >> "$K3S_IMAGE_LIST"
    exit 0
    ;;
  *"images export"*) echo "$args" >> "$K3S_EXPORT_LOG"; printf 'docker-image-data' ;;
  *"images rm"*)
    echo "$args" >> "$K3S_RM_LOG"
    : > "$K3S_IMAGE_LIST"
    exit 0
    ;;
esac
exit 0
K3S
chmod +x "$STUBS/k3s"

# kubectl-Stub (alle Aufrufe protokollieren; apply/rollout/exec/delete).
cat > "$STUBS/kubectl" <<'KUB'
#!/usr/bin/env bash
args="$*"
echo "$args" >> "$KUBECTL_CALL_LOG"
case "$args" in
  *"rollout status"*)
    if [[ -n "${KUBECTL_ROLLOUT_FAIL:-}" && -f "$KUBECTL_ROLLOUT_FAIL" ]]; then exit 1; fi
    exit 0
    ;;
  *"create configmap"*"dry-run"*) printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: mapproxy-config\n' ;;
  *"exec"*"sys.argv"*)
    if [[ -n "${KUBECTL_GETMAP_RESULT:-}" ]]; then printf '%s' "$KUBECTL_GETMAP_RESULT"; else printf 'TRNS'; fi
    ;;
  *"exec"*"GetCapabilities"*)
    if [[ -n "${KUBECTL_CAPS_MISSING_LAYER:-}" ]]; then
      printf '<WMS_Capabilities><Layer><Name>p2d2_osm</Name></Layer><Layer><Name>p2d2_cemeteries_overview</Name></Layer></WMS_Capabilities>'
    else
      printf '<WMS_Capabilities><Layer><Name>p2d2_osm</Name></Layer><Layer><Name>p2d2_cemeteries_overview</Name></Layer><Layer><Name>p2d2_cemeteries_details</Name></Layer></WMS_Capabilities>'
    fi
    ;;
  *"get pods"*"{range .items"*) printf 'mapproxy-abc123-xyz Running\n' ;;
  *"get pods"*"-o jsonpath"*) printf 'mapproxy-abc123-xyz' ;;
  *"get pods"*"-o wide"*) printf 'NAME READY STATUS RESTARTS AGE\nmapproxy-abc123-xyz 0/1 CrashLoopBackOff 7 18m\n' ;;
  *"describe pod"*) printf 'Events:\n  Warning  Unhealthy  18m  Readiness probe failed: HTTP probe failed with statuscode: 404\n' ;;
  *"logs"*"deploy/mapproxy"*) printf '[INFO] gunicorn worker booting\n' ;;
  *"apply"*) cat > "${KUBECTL_APPLY_STDIN}" 2>/dev/null; exit 0 ;;
  *"delete"*) exit 0 ;;
esac
exit 0
KUB
chmod +x "$STUBS/kubectl"

# sleep-Stub (Retry-Wartezeit im Test eliminieren).
cat > "$STUBS/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
chmod +x "$STUBS/sleep"

# curl-Stub (APISIX-Admin-API + öffentliche /mapserver-Verifikation).
# Zustand: APISIX_STATE_DIR/upstream-id und route-id; Args/Body werden protokolliert.
cat > "$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
args=("$@")
method="GET"; url=""; out=""; wformat=""; have_w=0; dump_header=0; data_file=""
i=0
while [ "$i" -lt "$#" ]; do
  a="${args[$i]}"
  case "$a" in
    -X) i=$((i+1)); method="${args[$i]}" ;;
    -o) i=$((i+1)); out="${args[$i]}" ;;
    -w) i=$((i+1)); wformat="${args[$i]}"; have_w=1 ;;
    -D) i=$((i+1)); dump_header=1 ;;
    --data-binary) i=$((i+1)); data_file="${args[$i]#@}" ;;
    -K) i=$((i+1)) ;;
  esac
  i=$((i+1))
done
url="${args[$#-1]}"
printf '%s\n' "$*" >> "$CURL_ARGS_LOG"

body=""
code="200"

if [[ "$url" == *"api-admin."*"/apisix/admin/upstreams"* ]]; then
  if [[ "$method" == "GET" ]]; then
    if [[ -f "$APISIX_STATE_DIR/upstream-id" ]]; then
      body='{"list":[{"value":{"id":"123","name":"mapserver-upstream"}}]}'
    else
      body='{"list":[]}'
    fi
  elif [[ "$method" == "POST" ]]; then
    printf '123' > "$APISIX_STATE_DIR/upstream-id"
    code="201"
  elif [[ "$method" == "PUT" ]]; then
    code="200"
  elif [[ "$method" == "DELETE" ]]; then
    rm -f "$APISIX_STATE_DIR/upstream-id"
    code="200"
  fi
elif [[ "$url" == *"api-admin."*"/apisix/admin/routes"* ]]; then
  if [[ "$method" == "GET" ]]; then
    if [[ -f "$APISIX_STATE_DIR/route-id" ]]; then
      body='{"list":[{"value":{"id":"456","name":"mapserver-route"}}]}'
    else
      body='{"list":[]}'
    fi
  elif [[ "$method" == "POST" ]]; then
    printf '456' > "$APISIX_STATE_DIR/route-id"
    code="201"
  elif [[ "$method" == "PUT" ]]; then
    code="200"
  elif [[ "$method" == "DELETE" ]]; then
    rm -f "$APISIX_STATE_DIR/route-id"
    code="200"
  fi
fi

if [[ -n "$data_file" && -f "$data_file" ]]; then
  printf '%s\n' "$(cat "$data_file")" >> "$APISIX_BODY_LOG"
fi

if [[ "$url" == *"/mapserver/"* ]]; then
  if [[ "$url" == *"wmts"* ]]; then
    if [[ "${CURL_WMTS_OK:-1}" == "1" ]]; then
      body='<Capabilities><Contents><Layer><ResourceURL template="https://geoportal.'"$ADDON_DOMAIN"'/mapserver/wmts/1.0.0/x/{TileMatrixSet}/{TileMatrix}/{TileCol}/{TileRow}.png"/></Layer></Contents></Capabilities>'
    else
      code="404"; body=""
    fi
  elif [[ "$dump_header" == "1" ]]; then
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'access-control-allow-origin: *\r\n'
    if [[ "${CURL_CORS_DOUBLE:-0}" == "1" ]]; then
      printf 'access-control-allow-origin: *\r\n'
    fi
    printf '\r\n'
    exit 0
  else
    if [[ "${CURL_WMS_404:-0}" == "1" ]]; then
      code="404"; body=""
    else
      href='xlink:href="https://geoportal.'"$ADDON_DOMAIN"'/mapserver/service?"'
      if [[ "${CURL_WMS_ADDR_OK:-1}" != "1" ]]; then
        href='xlink:href="https://geoportal.'"$ADDON_DOMAIN"'/service?"'
      fi
      body='<WMS_Capabilities><Layer><Name>p2d2_osm</Name></Layer><Layer><Name>p2d2_cemeteries_overview</Name></Layer><Layer><Name>p2d2_cemeteries_details</Name></Layer>'"$href"'</WMS_Capabilities>'
    fi
  fi
fi

if [[ -n "$out" && "$out" != "/dev/null" ]]; then
  printf '%s' "$body" > "$out"
fi
if [[ "$have_w" == "1" ]]; then
  printf '%s' "$code"
elif [[ -z "$out" || "$out" == "/dev/null" ]]; then
  printf '%s' "$body"
fi
CURL
chmod +x "$STUBS/curl"

# ── Module laden ──────────────────────────────────────────────────────────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_20_mapproxy.sh"
set +e

# ── Docker-Lebenszyklus (Anforderung 1) ───────────────────────────────────────
# (a) Docker fehlt -> ensure installiert, release entfernt (je genau einmal).
docker_absent
unset ADDON_DOCKER_INSTALLED_BY_SCRIPT ADDON_DOCKER_HOLD
addon_docker_ensure >/dev/null 2>&1
rc1=$?
addon_docker_ensure >/dev/null 2>&1   # idempotent: kein zweites install
addon_docker_release >/dev/null 2>&1
addon_docker_release >/dev/null 2>&1  # kein zweites purge
check "Docker ensure/release je einmal" "1|1" "$(wc -l < "$APT_INSTALL_LOG" | tr -d ' ')|$(wc -l < "$APT_PURGE_LOG" | tr -d ' ')"
check "Docker ensure rc=0" "0" "$rc1"

# (b) Docker bereits vorhanden -> kein install, kein purge.
docker_present
: > "$APT_INSTALL_LOG"; : > "$APT_PURGE_LOG"
unset ADDON_DOCKER_INSTALLED_BY_SCRIPT ADDON_DOCKER_HOLD
addon_docker_ensure >/dev/null 2>&1
addon_docker_release >/dev/null 2>&1
check "Docker vorhanden: kein install/purge" "0|0" "$(wc -l < "$APT_INSTALL_LOG" | tr -d ' ')|$(wc -l < "$APT_PURGE_LOG" | tr -d ' ')"

# (c) HOLD hält Docker am Leben.
docker_absent
: > "$APT_INSTALL_LOG"; : > "$APT_PURGE_LOG"
unset ADDON_DOCKER_INSTALLED_BY_SCRIPT
# ADDON_DOCKER_HOLD wird von der gesourcten addon_docker_release gelesen
# (shellcheck kann das nicht auflösen) — daher SC2034 hier gezielt deaktivieren.
# shellcheck disable=SC2034
ADDON_DOCKER_HOLD=true
addon_docker_ensure >/dev/null 2>&1
addon_docker_release >/dev/null 2>&1
check "HOLD: kein purge" "0" "$(wc -l < "$APT_PURGE_LOG" | tr -d ' ')"
# shellcheck disable=SC2034
ADDON_DOCKER_HOLD=false
addon_docker_release >/dev/null 2>&1
check "HOLD aufgehoben: purge" "1" "$(wc -l < "$APT_PURGE_LOG" | tr -d ' ')"

# ── MapProxy-Image-Build (Anforderung 2) ──────────────────────────────────────
docker_present
unset ADDON_DOCKER_INSTALLED_BY_SCRIPT ADDON_DOCKER_HOLD

# (a) Image vorhanden -> kein Build/Import.
: > "$DOCKER_BUILD_LOG"; : > "$K3S_IMPORT_LOG"
printf 'docker.io/library/mapproxy:v1s-2026-09-12\n' > "$K3S_IMAGE_LIST"
install_addon_mapproxy_build >/dev/null 2>&1
check "Build: Image vorhanden -> kein Build" "0" "$(wc -l < "$DOCKER_BUILD_LOG" | tr -d ' ')"
check "Build: Image vorhanden -> kein Import" "0" "$(wc -l < "$K3S_IMPORT_LOG" | tr -d ' ')"

# (b) Image fehlt -> Build + Import je einmal.
: > "$DOCKER_BUILD_LOG"; : > "$K3S_IMPORT_LOG"; : > "$K3S_IMAGE_LIST"
install_addon_mapproxy_build >/dev/null 2>&1
check "Build: fehlend -> Build einmal" "1" "$(wc -l < "$DOCKER_BUILD_LOG" | tr -d ' ')"
check "Build: fehlend -> Import einmal" "1" "$(wc -l < "$K3S_IMPORT_LOG" | tr -d ' ')"

# (c) Build schlägt fehl -> return 1, kein Import.
cat > "$STUBS/docker" <<'DOCKFAIL'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"build"*) exit 1 ;;
  *"info"*) exit 0 ;;
  *"--version"*) echo "Docker version 26.1.4" ;;
esac
exit 0
DOCKFAIL
chmod +x "$STUBS/docker"
: > "$DOCKER_BUILD_LOG"; : > "$K3S_IMPORT_LOG"; : > "$K3S_IMAGE_LIST"
install_addon_mapproxy_build >/dev/null 2>&1
check "Build fehlgeschlagen: rc=1" "1" "$?"
check "Build fehlgeschlagen: kein Import" "0" "$(wc -l < "$K3S_IMPORT_LOG" | tr -d ' ')"

# ── MapProxy-Install (Anforderung 3) ──────────────────────────────────────────
: > "$KUBECTL_CALL_LOG"
install_addon_mapproxy >/dev/null 2>&1
check "Install: rc=0" "0" "$?"
check "Install: ConfigMap erzeugt" "yes" "$(grep -q 'create configmap mapproxy-config' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Install: Manifest angewendet" "yes" "$(grep -q 'apply -f -' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Install: checksum/config gerendert (64 hex)" "yes" "$(grep -qE 'checksum/config: [0-9a-f]{64}' "$KUBECTL_APPLY_STDIN" && echo yes || echo no)"

# ── Preflight: ungueltige Config -> return 1, kein schreibender kubectl ───────
cat > "$STUBS/docker" <<'DOCKPRE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--version"*) echo "Docker version 26.1.4" ;;
  *"image inspect"*) exit 0 ;;
  *"run"*) exit 1 ;;
  *"load"*) exit 0 ;;
  *"info"*) exit 0 ;;
esac
exit 0
DOCKPRE
chmod +x "$STUBS/docker"
hash -d docker 2>/dev/null || true
: > "$KUBECTL_CALL_LOG"
install_addon_mapproxy >/dev/null 2>&1
check "Preflight: ungueltige Config rc=1" "1" "$?"
check "Preflight: kein create configmap" "0" "$(grep -c 'create configmap' "$KUBECTL_CALL_LOG" || true)"
check "Preflight: kein apply" "0" "$(grep -c 'apply' "$KUBECTL_CALL_LOG" || true)"

# ── Deployment-Probes (Anforderung: GetCapabilities-Pfad, kein /demo) ─────────
DEPLOY_YAML="$REPO/overlay_addon_V1s/k8s/mapproxy/deployment.yaml"
check "Probe: GetCapabilities-Pfad 2x" "2" "$(grep -oF '/service?SERVICE=WMS&REQUEST=GetCapabilities' "$DEPLOY_YAML" | wc -l | tr -d ' ')"
check "Probe: kein /demo" "0" "$(grep -cF 'path: /demo' "$DEPLOY_YAML" || true)"
check "Probe: checksum/config Platzhalter" "1" "$(grep -cF 'checksum/config: __P2D2_CONFIG_HASH__' "$DEPLOY_YAML")"

# ── MapProxy-Metadaten + User-Agent (Turn 006 B1/B2) ──────────────────────────
MAPROXY_YAML="$REPO/overlay_addon_V1s/k8s/mapproxy/mapproxy.yaml"
check "Meta: online_resource 2x" "2" "$(grep -cF 'online_resource: https://www.data-dna.eu' "$MAPROXY_YAML")"
check "Meta: fees NONE 2x" "2" "$(grep -cF "fees: 'NONE'" "$MAPROXY_YAML")"
check "Meta: kein SomewhereStreet" "0" "$(grep -cF 'SomewhereStreet' "$MAPROXY_YAML" || true)"
check "Meta: keine alte Lizenz" "0" "$(grep -cF 'private and evaluation use only' "$MAPROXY_YAML" || true)"
check "Meta: kein person:/position:" "0" "$(grep -cE '^[[:space:]]*(person|position):' "$MAPROXY_YAML" || true)"
check "OSM: User-Agent identifizierend" "yes" "$(grep -qF 'p2d2-MapProxy/1.0 (https://www.data-dna.eu; info@data-dna.eu)' "$MAPROXY_YAML" && echo yes || echo no)"
check "CORS: access_control_allow_origin leer (APISIX setzt den Header)" "1" "$(grep -cF 'access_control_allow_origin: ""' "$MAPROXY_YAML")"

# ── Statischer Config-Test (keyword_list Objekt-Liste, contact-Schlüssel) ────
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$MAPROXY_YAML" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
kw_ok = all(
    isinstance(cfg["services"][s]["md"].get("keyword_list"), list)
    and all(isinstance(o, dict) and "keywords" in o for o in cfg["services"][s]["md"].get("keyword_list", []))
    for s in ("wms", "wmts")
)
contact = cfg["services"]["wms"]["md"].get("contact", {})
contact_ok = set(contact.keys()) <= {"organization", "email", "city", "country"}
sys.exit(0 if kw_ok and contact_ok else 1)
PY
  check "Statik: keyword_list Objekte + contact-Schlüssel" "0" "$?"
else
  check "Statik: keyword_list 2x" "2" "$(grep -cF 'keyword_list:' "$MAPROXY_YAML")"
  check "Statik: keyword_list Objekt-Liste 2x" "2" "$(grep -cF '        - keywords: [' "$MAPROXY_YAML")"
  check "Statik: keine flache keyword_list" "0" "$(grep -cE 'keyword_list: \[' "$MAPROXY_YAML" || true)"
  check "Statik: contact nur erlaubte Schlüssel" "0" "$(grep -cE '^[[:space:]]+(person|position|address|postcode):' "$MAPROXY_YAML" || true)"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
verify_addon_mapproxy >/dev/null 2>&1
check "Verify: rc=0" "0" "$?"
check "Verify: GetCapabilities ausgeführt" "yes" "$(grep -q 'GetCapabilities' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify: GetMap ausgeführt" "yes" "$(grep -q 'GetMap' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify: GetMap-URL mit STYLES" "yes" "$(grep -qF '&LAYERS=p2d2_cemeteries_details&STYLES=&SRS=' "$KUBECTL_CALL_LOG" && echo yes || echo no)"

# ── Verify-Fehlerpfad: Diagnose + rc=1 ────────────────────────────────────────
: > "$KUBECTL_CALL_LOG"
export KUBECTL_ROLLOUT_FAIL="$T/kubectl-rollout-fail"
: > "$KUBECTL_ROLLOUT_FAIL"
verify_addon_mapproxy >/dev/null 2>&1
check "Verify Fehler: rc=1" "1" "$?"
check "Verify Fehler: get pods Diagnose" "yes" "$(grep -q 'get pods' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify Fehler: describe Diagnose" "yes" "$(grep -q 'describe pod' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify Fehler: logs Diagnose" "yes" "$(grep -q 'logs' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify Fehler: logs --previous" "yes" "$(grep -q -- '--previous' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
rm -f "$KUBECTL_ROLLOUT_FAIL"
unset KUBECTL_ROLLOUT_FAIL

# ── Verify: fehlender Layer in GetCapabilities -> rc=1 ────────────────────────
: > "$KUBECTL_CALL_LOG"
export KUBECTL_CAPS_MISSING_LAYER=1
verify_addon_mapproxy >/dev/null 2>&1
check "Verify: fehlender Layer -> rc=1" "1" "$?"
unset KUBECTL_CAPS_MISSING_LAYER

# ── Verify: GetMap HTTP 500 -> rc=1 + Fehlerursache in der Meldung ──────────
: > "$KUBECTL_CALL_LOG"
export KUBECTL_GETMAP_RESULT="HTTP 500 missing parameters ['styles']"
verify_addon_mapproxy >/dev/null 2>&1
check "Verify: GetMap HTTP 500 -> rc=1" "1" "$?"
check "Verify: GetMap Fehlermeldung enthält HTTP 500" "yes" "$(grep -qF 'HTTP 500' "$LOGBUF" && echo yes || echo no)"
unset KUBECTL_GETMAP_RESULT

# ── Uninstall Image-Entfernung (Anforderung 4) ────────────────────────────────
# (a) Default false -> Image bleibt, kein rm.
printf 'docker.io/library/mapproxy:v1s-2026-09-12\n' > "$K3S_IMAGE_LIST"
: > "$K3S_RM_LOG"
export P2D2_UNINSTALL_REMOVE_IMAGES="false"
uninstall_addon_mapproxy >/dev/null 2>&1
check "Uninstall false: kein rm" "0" "$(wc -l < "$K3S_RM_LOG" | tr -d ' ')"

# (b) true -> rm genau einmal.
: > "$K3S_RM_LOG"
export P2D2_UNINSTALL_REMOVE_IMAGES="true"
uninstall_addon_mapproxy >/dev/null 2>&1
check "Uninstall true: rm einmal" "1" "$(wc -l < "$K3S_RM_LOG" | tr -d ' ')"

# ── Config-Validierung: containerd-Export mit vollqualifiziertem Namen (B.3) ──
: > "$K3S_EXPORT_LOG"
export DOCKER_INSPECT_SEEN="$T/docker-inspect-seen"
rm -f "$DOCKER_INSPECT_SEEN"
cat > "$STUBS/docker" <<'DOCKEXPORT'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--version"*) echo "Docker version 26.1.4" ;;
  *"image inspect"*)
    if [[ ! -f "$DOCKER_INSPECT_SEEN" ]]; then
      touch "$DOCKER_INSPECT_SEEN"
      exit 1
    fi
    exit 0
    ;;
  *"run"*) exit 0 ;;
  *"load"*) exit 0 ;;
  *"info"*) exit 0 ;;
esac
exit 0
DOCKEXPORT
chmod +x "$STUBS/docker"
hash -d docker 2>/dev/null || true
cfg_export="$(mktemp)"; chmod 600 "$cfg_export"
printf 'globals:\n  cache:\n    base_dir: /cache_data\nservices: {}\n' > "$cfg_export"
_mapproxy_validate_config "$cfg_export" "mapproxy:v1s-2026-09-12" >/dev/null 2>&1
check "Validate: Export nutzt vollqualifizierten Namen" "yes" "$(grep -qF 'docker.io/library/mapproxy:v1s-2026-09-12' "$K3S_EXPORT_LOG" && echo yes || echo no)"
rm -f "$cfg_export"
unset DOCKER_INSPECT_SEEN

# ── Config-Validierung: Datei vor docker run für andere lesbar (644) ────────
cat > "$STUBS/docker" <<'DOCKRUN'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"--version"*) echo "Docker version 26.1.4" ;;
  *"image inspect"*) exit 0 ;;
  *"run"*) exit 0 ;;
  *"load"*) exit 0 ;;
  *"info"*) exit 0 ;;
esac
exit 0
DOCKRUN
chmod +x "$STUBS/docker"
hash -d docker 2>/dev/null || true
cfg_mode="$(mktemp)"; chmod 600 "$cfg_mode"
printf 'globals:\n  cache:\n    base_dir: /cache_data\nservices: {}\n' > "$cfg_mode"
_mapproxy_validate_config "$cfg_mode" "mapproxy:v1s-2026-09-12" >/dev/null 2>&1
check "Validate: cfg-Datei vor docker run 644" "644" "$(stat -c '%a' "$cfg_mode")"
rm -f "$cfg_mode"

# ── Routing: Admin-Key fehlt -> return 1 ohne curl ──────────────────────────
unset ADDON_APISIX_CREDENTIALS_FILE
: > "$CURL_ARGS_LOG"
install_addon_mapproxy_routing >/dev/null 2>&1
check "Routing: kein Admin-Key -> rc=1" "1" "$?"
check "Routing: kein Admin-Key -> kein curl" "0" "$(wc -l < "$CURL_ARGS_LOG" | tr -d ' ')"

# ── Routing: erst anlegen (POST), dann idempotent (PUT) ────────────────────
export ADDON_APISIX_CREDENTIALS_FILE="$T/credentials.env"
printf 'APISIX_ADMIN_ROLE_KEY=test-apikey-123\n' > "$ADDON_APISIX_CREDENTIALS_FILE"
rm -f "$APISIX_STATE_DIR/upstream-id" "$APISIX_STATE_DIR/route-id"
: > "$CURL_ARGS_LOG"; : > "$APISIX_BODY_LOG"

install_addon_mapproxy_routing >/dev/null 2>&1
check "Routing: erster Lauf rc=0" "0" "$?"
check "Routing: Upstream POST (erster Lauf)" "yes" "$(grep -qE 'POST.*apisix/admin/upstreams$' "$CURL_ARGS_LOG" && echo yes || echo no)"
check "Routing: Upstream kein PUT (erster Lauf)" "0" "$(grep -cE 'PUT.*apisix/admin/upstreams/' "$CURL_ARGS_LOG" || true)"
check "Routing: Route POST (erster Lauf)" "yes" "$(grep -qE 'POST.*apisix/admin/routes$' "$CURL_ARGS_LOG" && echo yes || echo no)"

route_body="$(grep -E '^\{' "$APISIX_BODY_LOG" | tail -1)"
check "Routing: Route-Body upstream_id=123" "yes" "$(grep -qF '"upstream_id":"123"' <<< "$route_body" && echo yes || echo no)"
check "Routing: Route-Body X-Script-Name" "yes" "$(grep -qF '"X-Script-Name":"/mapserver"' <<< "$route_body" && echo yes || echo no)"
check "Routing: Route-Body X-Forwarded-Proto" "yes" "$(grep -qF '"X-Forwarded-Proto":"https"' <<< "$route_body" && echo yes || echo no)"
check "Routing: Route-Body cors" "yes" "$(grep -qF '"cors":{}' <<< "$route_body" && echo yes || echo no)"

: > "$CURL_ARGS_LOG"
install_addon_mapproxy_routing >/dev/null 2>&1
check "Routing: zweiter Lauf rc=0" "0" "$?"
check "Routing: Upstream PUT (zweiter Lauf)" "yes" "$(grep -qE 'PUT.*apisix/admin/upstreams/123' "$CURL_ARGS_LOG" && echo yes || echo no)"
check "Routing: Route PUT (zweiter Lauf)" "yes" "$(grep -qE 'PUT.*apisix/admin/routes/456' "$CURL_ARGS_LOG" && echo yes || echo no)"
check "Routing: kein zweiter POST" "0" "$(grep -cE 'POST.*apisix/admin/(upstreams|routes)$' "$CURL_ARGS_LOG" || true)"
check "Routing: Key nicht in curl-Args" "0" "$(grep -cF 'test-apikey-123' "$CURL_ARGS_LOG" || true)"
check "Routing: Key nicht im Log" "0" "$(grep -cF 'test-apikey-123' "$LOGBUF" || true)"

# ── Routing-Verify ───────────────────────────────────────────────────────
: > "$CURL_ARGS_LOG"
unset CURL_WMS_404 CURL_WMS_ADDR_OK CURL_WMTS_OK CURL_CORS_DOUBLE
verify_addon_mapproxy_routing >/dev/null 2>&1
check "Routing-Verify: ok rc=0" "0" "$?"

export CURL_WMS_ADDR_OK=0
verify_addon_mapproxy_routing >/dev/null 2>&1
check "Routing-Verify: Adresse ohne /mapserver rc=1" "1" "$?"
unset CURL_WMS_ADDR_OK

export CURL_CORS_DOUBLE=1
verify_addon_mapproxy_routing >/dev/null 2>&1
check "Routing-Verify: doppelter CORS rc=1" "1" "$?"
unset CURL_CORS_DOUBLE

export CURL_WMS_404=1
verify_addon_mapproxy_routing >/dev/null 2>&1
check "Routing-Verify: 404 nach allen Versuchen rc=1" "1" "$?"
unset CURL_WMS_404

rm -rf "$T"

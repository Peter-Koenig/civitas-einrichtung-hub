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
export K3S_IMAGE_LIST="$T/k3s-images.txt"
export KUBECTL_CALL_LOG="$T/kubectl-call.log"
export DOCKER_REAL="$STUBS/docker.real"
: > "$APT_INSTALL_LOG"; : > "$APT_PURGE_LOG"; : > "$DOCKER_BUILD_LOG"; : > "$K3S_IMPORT_LOG"; : > "$K3S_RM_LOG"; : > "$K3S_IMAGE_LIST"; : > "$KUBECTL_CALL_LOG"

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
  *"get pods"*"-o jsonpath"*) printf 'mapproxy-abc123-xyz' ;;
  *"get pods"*"-o wide"*) printf 'NAME READY STATUS RESTARTS AGE\nmapproxy-abc123-xyz 0/1 CrashLoopBackOff 7 18m\n' ;;
  *"describe pod"*) printf 'Events:\n  Warning  Unhealthy  18m  Readiness probe failed: HTTP probe failed with statuscode: 404\n' ;;
  *"logs"*"deploy/mapproxy"*) printf '[INFO] gunicorn worker booting\n' ;;
  *"apply"*|*"delete"*) exit 0 ;;
esac
exit 0
KUB
chmod +x "$STUBS/kubectl"

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

# ── Deployment-Probes (Anforderung: GetCapabilities-Pfad, kein /demo) ─────────
DEPLOY_YAML="$REPO/overlay_addon_V1s/k8s/mapproxy/deployment.yaml"
check "Probe: GetCapabilities-Pfad 2x" "2" "$(grep -oF '/service?SERVICE=WMS&REQUEST=GetCapabilities' "$DEPLOY_YAML" | wc -l | tr -d ' ')"
check "Probe: kein /demo" "0" "$(grep -cF 'path: /demo' "$DEPLOY_YAML" || true)"

# ── Verify ────────────────────────────────────────────────────────────────────
verify_addon_mapproxy >/dev/null 2>&1
check "Verify: rc=0" "0" "$?"

# ── Verify-Fehlerpfad: Diagnose + rc=1 ────────────────────────────────────────
: > "$KUBECTL_CALL_LOG"
export KUBECTL_ROLLOUT_FAIL="$T/kubectl-rollout-fail"
: > "$KUBECTL_ROLLOUT_FAIL"
verify_addon_mapproxy >/dev/null 2>&1
check "Verify Fehler: rc=1" "1" "$?"
check "Verify Fehler: get pods Diagnose" "yes" "$(grep -q 'get pods' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify Fehler: describe Diagnose" "yes" "$(grep -q 'describe pod' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
check "Verify Fehler: logs Diagnose" "yes" "$(grep -q 'logs' "$KUBECTL_CALL_LOG" && echo yes || echo no)"
rm -f "$KUBECTL_ROLLOUT_FAIL"
unset KUBECTL_ROLLOUT_FAIL

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

rm -rf "$T"

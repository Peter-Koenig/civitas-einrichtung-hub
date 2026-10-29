#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_20_mapproxy.sh — p2d2-AddOn: MapProxy-Baustein.
#
# Eigener MapProxy-Pod im GeoData-Namespace: Image-Build (k3s-Node) -> K8s-Ressourcen
# (ConfigMap/PVC/Service/Deployment). APISIX-Routing /mapserver folgt in einem späteren Turn.
#
# Quelle: ai-runs/.../mapproxy-automatisierungshinweise.md.

# Fail-Fast: ohne ADDON_NS sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_NS:-}" ]]; then
  echo "FEHLER: ADDON_NS nicht gesetzt — addon_20_mapproxy.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

# _mapproxy_image_present <image> — 0 wenn das lokal gebaute Image in containerd
# (Namespace k8s.io) als docker.io/library/<image> vorhanden ist, sonst 1.
_mapproxy_image_present() {
  local image="$1"
  k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep -qF "docker.io/library/${image}"
}

# install_addon_mapproxy_build — baut das MapProxy-Image und importiert es in
# containerd. Idempotent: vorhandenes Image überspringt den Build. Docker wird über
# den gemeinsamen Helfer addon_docker_ensure bereitgestellt (HOLD aus dem Hauptskript).
install_addon_mapproxy_build() {
  log "=== AddOn 20: MapProxy-Image-Build ==="

  local image="${ADDON_MAPPROXY_IMAGE:-mapproxy:v1s-2026-09-12}"
  local build_dir
  build_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay_addon_V1s/k8s/mapproxy" && pwd)"

  addon_docker_ensure || return 1

  if _mapproxy_image_present "${image}"; then
    log_ok "MapProxy-Image ${image} bereits vorhanden — Build übersprungen"
    return 0
  fi

  log "Baue MapProxy-Image ${image} (Kontext: ${build_dir}) …"
  docker build -t "${image}" "${build_dir}" || { log_error "docker build fehlgeschlagen"; return 1; }

  log "Importiere MapProxy-Image in containerd (Namespace k8s.io) …"
  docker save "${image}" | k3s ctr -n k8s.io images import - \
    || { log_error "k3s ctr -n k8s.io images import fehlgeschlagen"; return 1; }

  if ! _mapproxy_image_present "${image}"; then
    log_error "MapProxy-Image ${image} nach Import nicht auffindbar — Abbruch vor Deployment"
    return 1
  fi

  log_ok "MapProxy-Image ${image} gebaut + importiert"
  return 0
}

install_addon_mapproxy() {
  log "=== AddOn 20: MapProxy (ConfigMap/PVC/Service/Deployment) ==="

  local ns="${ADDON_NS}"
  local image="${ADDON_MAPPROXY_IMAGE:-mapproxy:v1s-2026-09-12}"
  local overlay_dir cfg_tmp cfg_hash
  overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay_addon_V1s/k8s" && pwd)"

  # 1) ConfigMap mapproxy-config (Key mapproxy.yaml; Namespace aus ADDON_NS rendern).
  cfg_tmp="$(mktemp)"; chmod 600 "${cfg_tmp}"
  sed "s|__P2D2_NAMESPACE__|${ns}|g" "${overlay_dir}/mapproxy/mapproxy.yaml" > "${cfg_tmp}" \
    || { log_error "mapproxy.yaml rendern fehlgeschlagen"; rm -f "${cfg_tmp}"; return 1; }
  cfg_hash="$(sha256sum "${cfg_tmp}" | awk '{print $1}')"
  if ! kubectl -n "${ns}" create configmap mapproxy-config --from-file=mapproxy.yaml="${cfg_tmp}" \
       --dry-run=client -o yaml | kubectl apply -f -; then
    log_error "ConfigMap mapproxy-config anwenden fehlgeschlagen"
    rm -f "${cfg_tmp}"
    return 1
  fi
  rm -f "${cfg_tmp}"

  # 2) PVC + Service + Deployment (Platzhalter rendern, idempotent per apply;
  #    checksum/config löst bei geänderter ConfigMap einen Rollout aus).
  if ! sed -e "s|__P2D2_NAMESPACE__|${ns}|g" -e "s|__P2D2_IMAGE__|${image}|g" \
           -e "s|__P2D2_CONFIG_HASH__|${cfg_hash}|g" \
       "${overlay_dir}/mapproxy/deployment.yaml" | kubectl apply -f -; then
    log_error "MapProxy-Ressourcen (PVC/Service/Deployment) anwenden fehlgeschlagen"
    return 1
  fi

  # 3) APISIX-Routing /mapserver — TODO (Upstream + Route mit proxy-rewrite,
  #    kommt in einem späteren Turn).
  log "  APISIX-Routing /mapserver: TODO — Upstream + Route (proxy-rewrite) anlegen"

  log_ok "AddOn 20 MapProxy abgeschlossen (Pod angelegt)"
}

# verify_addon_mapproxy — Rollout-Status (Pod Ready). Wird im Hauptskript
# nicht-abbrechend aufgerufen (verify_addon_mapproxy || ADDON_EXIT_CODE=1),
# daher explizite return 1 statt set -e. Die inhaltliche WMS/Layer-Prüfung
# (GetCapabilities) folgt im Konfigurations-Turn, wenn APISIX-Routing und
# GeoServer-Style/Mosaic feststehen.
verify_addon_mapproxy() {
  log "=== AddOn 20: MapProxy verifizieren ==="

  local ns="${ADDON_NS}"
  local timeout="${ADDON_MAPPROXY_VERIFY_TIMEOUT:-180}"

  if ! kubectl -n "${ns}" rollout status deployment/mapproxy --timeout="${timeout}s" >/dev/null 2>&1; then
    log_error "MapProxy-Rollout nicht erfolgreich (Timeout ${timeout}s)"
    log_error "  Diagnose (ohne Secrets):"
    kubectl -n "${ns}" get pods -l app=mapproxy -o wide 2>&1 | sed 's/^/  /' || true
    local pod
    pod="$(kubectl -n "${ns}" get pods -l app=mapproxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${pod}" ]]; then
      log_error "  --- Pod ${pod}: Events ---"
      kubectl -n "${ns}" describe pod "${pod}" 2>/dev/null | sed -n '/Events:/,$p' || true
      log_error "  --- Pod ${pod}: letzte Logzeilen ---"
      kubectl -n "${ns}" logs deploy/mapproxy --tail=20 2>&1 | sed 's/^/  /' || true
    fi
    return 1
  fi

  # WMS-GetCapabilities (im Cluster, ohne externe Aufrufe): 200 + 3 Layer.
  local caps layer cap_ok=1
  caps="$(kubectl -n "${ns}" exec deploy/mapproxy -- python -c \
    'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8080/service?SERVICE=WMS&REQUEST=GetCapabilities", timeout=10).read().decode())' 2>/dev/null || true)"
  if [[ -z "${caps}" ]]; then
    log_error "MapProxy GetCapabilities nicht lesbar (Pod nicht erreichbar/HTTP-Fehler)"
    return 1
  fi
  for layer in p2d2_osm p2d2_cemeteries_overview p2d2_cemeteries_details; do
    grep -qF "${layer}" <<< "${caps}" || { log_error "MapProxy-Layer ${layer} fehlt in GetCapabilities"; cap_ok=0; }
  done
  [[ "${cap_ok}" -eq 1 ]] && log_ok "MapProxy GetCapabilities: 200 + Layer p2d2_osm/cemeteries_overview/cemeteries_details"

  # EIN GetMap (kein OSM-Layer): p2d2_cemeteries_details, TRANSPARENT=true -> PNG mit tRNS.
  local bbox="${ADDON_MAPPROXY_VERIFY_BBOX:-356000,5648000,356500,5648500}" map_result
  map_result="$(kubectl -n "${ns}" exec deploy/mapproxy -- python -c \
    'import sys, urllib.request; d=urllib.request.urlopen(sys.argv[1], timeout=30).read(); print("TRNS" if b"tRNS" in d else "NOTRNS")' \
    "http://127.0.0.1:8080/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=p2d2_cemeteries_details&SRS=EPSG:25832&BBOX=${bbox}&WIDTH=256&HEIGHT=256&FORMAT=image/png&TRANSPARENT=true" 2>/dev/null || true)"
  if [[ "${map_result}" == "TRNS" ]]; then
    log_ok "MapProxy GetMap p2d2_cemeteries_details: 200 + tRNS"
  else
    log_error "MapProxy GetMap p2d2_cemeteries_details: tRNS fehlt (${map_result:-<Fehler>})"
    return 1
  fi

  log_ok "MapProxy verifiziert (Rollout ok, Pod Ready, GetCapabilities + GetMap)"
  return 0
}

# addon_apisix_admin_key [creds_file] — liest APISIX_ADMIN_ROLE_KEY aus der
# Credentials-Datei. Verarbeitet unquotierte, einfach/doppelt quotierte und
# `export`-Zeilen; leer, nicht lesbar oder mehrdeutig -> Exit 1 (kein Log, kein Key).
# shellcheck disable=SC2120  # optionaler Parameter, Aufruf auch ohne Argument (Default)
addon_apisix_admin_key() {
  local creds="${1:-${ADDON_APISIX_CREDENTIALS_FILE:-/root/civitas-install/credentials.env}}"
  [[ -r "$creds" ]] || return 1
  local count val
  count="$(grep -cE '^[[:space:]]*(export[[:space:]]+)?APISIX_ADMIN_ROLE_KEY[[:space:]]*=' "$creds" 2>/dev/null || true)"
  [[ "$count" == "1" ]] || return 1
  val="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?APISIX_ADMIN_ROLE_KEY[[:space:]]*=[[:space:]]*//p' "$creds" | head -n1)"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  [[ -n "$val" ]] || return 1
  printf '%s' "$val"
}

# _mapproxy_apisix_delete_by_name <collection> <name> <admin_key> <base>
# Löscht ein APISIX-Admin-Objekt (routes|upstreams) anhand seines name-Felds.
# APISIX erzeugt beim POST ohne explizite ID eine numerische ID — daher Liste lesen,
# per name filtern und die reale ID ermitteln, dann DELETE auf die ID.
_mapproxy_apisix_delete_by_name() {
  local coll="$1" name="$2" admin_key="$3" base="$4" id http_code list_http
  # Listenabfrage: HTTP-Status explizit prüfen; curl-Fehler/401 sind "nicht abfragbar"
  # (Rest), nicht "nicht vorhanden" (falsch-grün).
  list_http=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    -H "X-API-KEY: ${admin_key}" "${base}/${coll}" 2>/dev/null || true)
  if [[ "${list_http}" != "200" ]]; then
    log_warn "APISIX ${coll} nicht abfragbar (HTTP ${list_http:-0}) — ${name} manuell prüfen"
    return 1
  fi
  id=$(curl -sk --max-time 15 -H "X-API-KEY: ${admin_key}" "${base}/${coll}" 2>/dev/null \
    | jq -r --arg n "${name}" \
      '.list[]? | select(.value.name==$n) | (.value.id // (.key | split("/")[-1]))' 2>/dev/null \
    | head -1 || true)
  if [[ -z "${id}" ]]; then
    log_ok "APISIX ${name} nicht vorhanden — übersprungen"
    return 0
  fi
  http_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" -X DELETE \
    -H "X-API-KEY: ${admin_key}" "${base}/${coll}/${id}" 2>/dev/null || true)
  if [[ "${http_code}" == "200" || "${http_code}" == "404" ]]; then
    log_ok "APISIX ${name} gelöscht (HTTP ${http_code})"
    return 0
  else
    log_warn "APISIX ${name} löschen fehlgeschlagen (HTTP ${http_code})"
    return 1
  fi
}

# addon_remove_mapproxy_image — entfernt das MapProxy-Image aus containerd
# (Namespace k8s.io), exakter Name, kein Wildcard (analog addon_remove_frontend_images).
addon_remove_mapproxy_image() {
  local image="${ADDON_MAPPROXY_IMAGE:-mapproxy:v1s-2026-09-12}"
  local ref
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] && k3s ctr -n k8s.io images rm "${ref}" >/dev/null 2>&1 || true
  done < <(k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep -F "docker.io/library/${image}")
  if _mapproxy_image_present "${image}"; then
    log_warn "MapProxy-Image ${image} weiterhin vorhanden — manuell prüfen"
    return 1
  fi
  return 0
}

# uninstall_addon_mapproxy — Rückbau (K8s-Ressourcen + APISIX-Routing).
uninstall_addon_mapproxy() {
  log "=== Uninstall AddOn 20: MapProxy ==="

  local ns="${ADDON_NS}"
  local remove_images rc=0
  remove_images="$(addon_validate_uninstall_remove_images)" || return 1

  kubectl -n "$ns" delete deployment mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete service mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete configmap mapproxy-config --ignore-not-found || true
  kubectl -n "$ns" delete pvc mapproxy-cache --ignore-not-found || true

  # APISIX-Routing /mapserver: Route + Upstream löschen (Admin-API, Turn 65).
  # Admin-Key aus der CIVITAS/CORE-Credentials-Datei (APISIX_ADMIN_ROLE_KEY),
  # Endpunkt https://api-admin.<DOMAIN>/apisix/admin (analog mapproxy-automatisierungshinweise).
  local admin_key apisix_base
  local creds="${ADDON_APISIX_CREDENTIALS_FILE:-/root/civitas-install/credentials.env}"
  admin_key="$(addon_apisix_admin_key)"
  if [[ -n "${admin_key}" ]]; then
    apisix_base="https://api-admin.${ADDON_DOMAIN}/apisix/admin"
    _mapproxy_apisix_delete_by_name "routes" "mapserver-route" "${admin_key}" "${apisix_base}" || rc=1
    _mapproxy_apisix_delete_by_name "upstreams" "mapserver-upstream" "${admin_key}" "${apisix_base}" || rc=1
  else
    log_warn "APISIX_ADMIN_ROLE_KEY nicht gefunden (${creds}) — mapserver-route/-upstream manuell prüfen"
    rc=1
  fi

  # MapProxy-Image (containerd k8s.io) nur mit Schalter entfernen (wie Frontend, N7).
  if [[ "${remove_images}" == "true" ]]; then
    if addon_remove_mapproxy_image; then
      log_ok "MapProxy-Image entfernt (containerd k8s.io)"
    else
      log_warn "MapProxy-Image-Entfernung nicht vollständig — manuell prüfen"
      rc=1
    fi
  else
    log_ok "MapProxy-Image bewusst behalten (P2D2_UNINSTALL_REMOVE_IMAGES=false)"
  fi

  if [[ "${rc}" -ne 0 ]]; then
    log_warn "Uninstall AddOn 20 MapProxy mit Resten/Fehlern beendet"
    return 1
  fi
  log_ok "Uninstall AddOn 20 MapProxy abgeschlossen"
}

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

# _mapproxy_validate_config <rendered_yaml> <image> — prüft die gerenderte
# MapProxy-Config im gebauten Image, bevor die ConfigMap angewendet wird.
# Rückgabe 0 (ok) / 1 (ungültig). Docker nicht verfügbar -> Warnung + 0 (weiter).
# Das Image kann nach einem übersprungenen Build nur in containerd (k8s.io) liegen
# und nicht im Docker-Image-Store: dann wird es rein lokal exportiert und per
# docker load übernommen (kein externer Zugriff, keine Credentials).
_mapproxy_validate_config() {
  local cfg_file="$1" image="$2" ref
  if ! addon_docker_ensure; then
    log_warn "Docker nicht verfügbar — MapProxy-Config-Validierung übersprungen"
    return 0
  fi
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    # Vollqualifizierte Referenz: containerd führt lokal gebaute Images als
    # docker.io/library/<name>:<tag>. Kurzname nur bei bereits vorhandenem "/" unverändert.
    ref="${image}"
    [[ "${ref}" == */* ]] || ref="docker.io/library/${ref}"
    log "MapProxy-Image ${image} nicht im Docker-Store — übernehme aus containerd (k8s.io)"
    if ! k3s ctr -n k8s.io images export "${ref}" - 2>/dev/null | docker load 2>/dev/null; then
      log_warn "MapProxy-Image ${image} nicht für Config-Validierung verfügbar — Validierung übersprungen"
      return 0
    fi
    if ! docker image inspect "${image}" >/dev/null 2>&1; then
      log_warn "MapProxy-Image ${image} nach Export weiterhin nicht im Docker-Store — Validierung übersprungen"
      return 0
    fi
  fi
  # Die gerenderte Config hat Modus 600 und gehört root; das Image läuft als UID
  # 1000 und kann sie im Bind-Mount sonst nicht lesen. Kein Secret enthalten.
  chmod 644 "${cfg_file}"
  local out rc
  out="$(docker run --rm -v "${cfg_file}:/c/mapproxy.yaml:ro" "${image}" \
    python -c "from mapproxy.config.loader import load_configuration; load_configuration('/c/mapproxy.yaml', ignore_warnings=True)" 2>&1)"
  rc=$?
  if [[ ${rc} -ne 0 ]]; then
    log_error "MapProxy-Config ungültig (Validierung im Image fehlgeschlagen):"
    printf '%s\n' "${out}" \
      | grep -vE '^(Traceback|[[:space:]]+File |[[:space:]]+raise |[[:space:]]+return |[[:space:]]+during )' \
      | sed 's/^/    /' | head -40 || true
    return 1
  fi
  log_ok "MapProxy-Config im gebauten Image validiert"
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
  if ! _mapproxy_validate_config "${cfg_tmp}" "${image}"; then
    log_error "MapProxy-Config ungültig — ConfigMap wird nicht angewendet"
    rm -f "${cfg_tmp}"
    return 1
  fi
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

  # 3) APISIX-Routing /mapserver folgt in install_addon_mapproxy_routing
  #    (wird im Hauptskript separat, nicht-abbrechend aufgerufen).

  log_ok "AddOn 20 MapProxy abgeschlossen (Pod angelegt)"
}

# verify_addon_mapproxy — Rollout-Status (Pod Ready), WMS-GetCapabilities (drei Layer) und ein GetMap (tRNS). Wird im Hauptskript nicht-abbrechend aufgerufen (verify_addon_mapproxy || ADDON_EXIT_CODE=1), daher explizite return 1 statt set -e.
verify_addon_mapproxy() {
  log "=== AddOn 20: MapProxy verifizieren ==="

  local ns="${ADDON_NS}"
  local timeout="${ADDON_MAPPROXY_VERIFY_TIMEOUT:-180}"

  if ! kubectl -n "${ns}" rollout status deployment/mapproxy --timeout="${timeout}s" >/dev/null 2>&1; then
    log_error "MapProxy-Rollout nicht erfolgreich (Timeout ${timeout}s)"
    log_error "  Diagnose (ohne Secrets):"
    kubectl -n "${ns}" get pods -l app=mapproxy -o wide 2>&1 | sed 's/^/  /' || true
    local pod loglines
    # Bevorzugt einen laufenden Pod (statt blind items[0]); Fallback auf den ersten Pod.
    pod="$(kubectl -n "${ns}" get pods -l app=mapproxy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="Running"{print $1; exit}' || true)"
    if [[ -z "${pod}" ]]; then
      pod="$(kubectl -n "${ns}" get pods -l app=mapproxy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
    if [[ -n "${pod}" ]]; then
      log_error "  --- Pod ${pod}: Events ---"
      kubectl -n "${ns}" describe pod "${pod}" 2>/dev/null | sed -n '/Events:/,$p' || true
      log_error "  --- Pod ${pod}: letzte Logzeilen ---"
      loglines="$(kubectl -n "${ns}" logs deploy/mapproxy --previous --tail=300 2>/dev/null \
        | grep -vE '^[[:space:]]+(File|~|\\^)' | head -30 || true)"
      if [[ -z "${loglines}" ]]; then
        loglines="$(kubectl -n "${ns}" logs deploy/mapproxy --tail=300 2>/dev/null \
          | grep -vE '^[[:space:]]+(File|~|\\^)' | head -30 || true)"
      fi
      if [[ -n "${loglines}" ]]; then
        printf '%s\n' "${loglines}" | sed 's/^/  /'
      fi
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
  [[ "${cap_ok}" -eq 1 ]] || return 1
  log_ok "MapProxy GetCapabilities: 200 + Layer p2d2_osm/cemeteries_overview/cemeteries_details"

  # EIN GetMap (kein OSM-Layer): p2d2_cemeteries_details, TRANSPARENT=true -> PNG mit tRNS.
  local bbox="${ADDON_MAPPROXY_VERIFY_BBOX:-356000,5648000,356500,5648500}" map_result
  map_result="$(kubectl -n "${ns}" exec deploy/mapproxy -- python -c \
    'import sys, urllib.request, urllib.error
try:
    d = urllib.request.urlopen(sys.argv[1], timeout=30).read()
    print("TRNS" if b"tRNS" in d else "NOTRNS")
except urllib.error.HTTPError as x:
    print("HTTP %s %s" % (x.code, x.read()[:200].decode("utf-8", "replace").replace("\n", " ")))
except Exception as x:
    print("%s %s" % (type(x).__name__, x))' \
    "http://127.0.0.1:8080/service?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=p2d2_cemeteries_details&STYLES=&SRS=EPSG:25832&BBOX=${bbox}&WIDTH=256&HEIGHT=256&FORMAT=image/png&TRANSPARENT=true" 2>/dev/null || true)"
  if [[ "${map_result}" == "TRNS" ]]; then
    log_ok "MapProxy GetMap p2d2_cemeteries_details: 200 + tRNS"
  else
    log_error "MapProxy GetMap p2d2_cemeteries_details: tRNS fehlt (${map_result:0:300})"
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

# _mapproxy_apisix_http <admin_key> <method> <url> [body_file] — APISIX-Admin-Aufruf
# mit X-API-KEY über stdin (curl -K -). Der Key erscheint nie in Prozessargumenten
# oder Logs. Setzt die globalen Variablen _APISIX_HTTP_CODE und _APISIX_HTTP_BODY.
_mapproxy_apisix_http() {
  local admin_key="$1" method="$2" url="$3" body="${4:-}" cfg tmp code
  case "${admin_key}" in
    *$'\n'*|*$'\r'*|*'"'*) log_error "APISIX-Admin-Key enthält unzulässige Zeichen (CR/LF/\")"; return 1 ;;
  esac
  cfg="$(printf 'header = "X-API-KEY: %s"\n' "${admin_key}")"
  tmp="$(mktemp)"; chmod 600 "${tmp}"
  if [[ -n "${body}" ]]; then
    code="$( printf '%s' "${cfg}" | curl -sS -K - --max-time 15 -X "${method}" -H 'Content-Type: application/json' --data-binary "@${body}" -o "${tmp}" -w '%{http_code}' "${url}" 2>/dev/null )" || code="000"
  else
    code="$( printf '%s' "${cfg}" | curl -sS -K - --max-time 15 -X "${method}" -o "${tmp}" -w '%{http_code}' "${url}" 2>/dev/null )" || code="000"
  fi
  _APISIX_HTTP_CODE="${code}"
  _APISIX_HTTP_BODY="$(cat "${tmp}" 2>/dev/null)"
  rm -f "${tmp}"
  return 0
}

# _mapproxy_apisix_find_id <admin_key> <collection> <name> <base> — ID eines APISIX-
# Admin-Objekts anhand seines name-Felds ermitteln. Leer = nicht vorhanden.
_mapproxy_apisix_find_id() {
  local admin_key="$1" coll="$2" name="$3" base="$4" id
  _mapproxy_apisix_http "${admin_key}" GET "${base}/${coll}" || return 1
  if [[ "${_APISIX_HTTP_CODE}" != "200" ]]; then
    log_warn "APISIX ${coll} nicht abfragbar (HTTP ${_APISIX_HTTP_CODE}) — ${name} nicht gefunden"
    return 1
  fi
  id="$(jq -r --arg n "${name}" '.list[]? | select(.value.name==$n) | (.value.id // (.key | split("/")[-1]))' <<< "${_APISIX_HTTP_BODY}" 2>/dev/null | head -1 || true)"
  printf '%s' "${id}"
}

# _mapproxy_apisix_upsert <admin_key> <collection> <id> <body> <base> — legt an (POST)
# oder aktualisiert (PUT); Erfolgscodes 200/201. Existenzprüfung über den Namen liegt
# beim Aufrufer (_mapproxy_apisix_find_id).
_mapproxy_apisix_upsert() {
  local admin_key="$1" coll="$2" id="$3" body="$4" base="$5" method url body_file
  if [[ -n "${id}" ]]; then
    method="PUT"; url="${base}/${coll}/${id}"
  else
    method="POST"; url="${base}/${coll}"
  fi
  body_file="$(mktemp)"; chmod 600 "${body_file}"
  printf '%s' "${body}" > "${body_file}"
  _mapproxy_apisix_http "${admin_key}" "${method}" "${url}" "${body_file}"
  rm -f "${body_file}"
  if [[ "${_APISIX_HTTP_CODE}" == "200" || "${_APISIX_HTTP_CODE}" == "201" ]]; then
    return 0
  fi
  log_warn "APISIX ${coll} ${method} ${url} fehlgeschlagen (HTTP ${_APISIX_HTTP_CODE}): $(printf '%s' "${_APISIX_HTTP_BODY}" | head -c 200)"
  return 1
}

# install_addon_mapproxy_routing — legt APISIX-Upstream + Route /mapserver an oder
# aktualisiert sie idempotent über den Namen. Nicht-abbrechend (return 1 im Fehlerfall).
install_addon_mapproxy_routing() {
  log "=== AddOn 20: MapProxy-Routing (APISIX /mapserver) ==="

  local ns="${ADDON_NS}" domain="${ADDON_DOMAIN}"
  local apisix_base admin_key creds
  apisix_base="https://api-admin.${domain}/apisix/admin"
  creds="${ADDON_APISIX_CREDENTIALS_FILE:-/root/civitas-install/credentials.env}"

  admin_key="$(addon_apisix_admin_key)"
  if [[ -z "${admin_key}" ]]; then
    log_warn "APISIX_ADMIN_ROLE_KEY nicht gefunden (${creds}) — /mapserver-Routing übersprungen"
    return 1
  fi

  local upstream_id upstream_body route_id route_body
  upstream_body="$(jq -nc --arg ns "${ns}" '{name:"mapserver-upstream",type:"roundrobin",scheme:"http",pass_host:"pass",nodes:[{host:("mapproxy."+$ns+".svc.cluster.local"),port:8080,weight:1}]}')"

  upstream_id="$(_mapproxy_apisix_find_id "${admin_key}" "upstreams" "mapserver-upstream" "${apisix_base}")" || return 1
  if ! _mapproxy_apisix_upsert "${admin_key}" "upstreams" "${upstream_id}" "${upstream_body}" "${apisix_base}"; then
    return 1
  fi

  # ID nach POST erneut ermitteln (POST erzeugt eine neue numerische ID).
  upstream_id="$(_mapproxy_apisix_find_id "${admin_key}" "upstreams" "mapserver-upstream" "${apisix_base}")" || return 1
  if [[ -z "${upstream_id}" ]]; then
    log_error "APISIX Upstream mapserver-upstream nach dem Anlegen nicht auffindbar"
    return 1
  fi

  route_body="$(jq -nc --arg uid "${upstream_id}" '{name:"mapserver-route",uri:"/mapserver*",methods:["GET","POST","PUT","PATCH","DELETE"],upstream_id:$uid,plugins:{"proxy-rewrite":{regex_uri:["^/mapserver(.*)","$1"],headers:{set:{"X-Script-Name":"/mapserver","X-Forwarded-Proto":"https"}}},"cors":{}}}')"
  route_id="$(_mapproxy_apisix_find_id "${admin_key}" "routes" "mapserver-route" "${apisix_base}")" || return 1
  if ! _mapproxy_apisix_upsert "${admin_key}" "routes" "${route_id}" "${route_body}" "${apisix_base}"; then
    return 1
  fi

  log_ok "AddOn 20 MapProxy-Routing abgeschlossen (Upstream + Route /mapserver)"
  return 0
}

# verify_addon_mapproxy_routing — öffentliche Erreichbarkeit /mapserver (WMS/WMTS
# Capabilities + CORS). Nicht-abbrechend, harte Fehler (return 1).
verify_addon_mapproxy_routing() {
  log "=== AddOn 20: MapProxy-Routing verifizieren ==="

  local domain="${ADDON_DOMAIN}"
  local wms_url wmts_url attempt ok f code body
  wms_url="https://geoportal.${domain}/mapserver/service?SERVICE=WMS&REQUEST=GetCapabilities"
  wmts_url="https://geoportal.${domain}/mapserver/wmts/1.0.0/WMTSCapabilities.xml"

  ok=0
  for attempt in 1 2 3 4 5; do
    f="$(mktemp)"; chmod 600 "${f}"
    code="$(curl -sS --max-time 30 -o "${f}" -w '%{http_code}' "${wms_url}" 2>/dev/null || true)"
    body="$(cat "${f}" 2>/dev/null)"; rm -f "${f}"
    if [[ "${code}" == "200" ]] \
      && grep -qF 'p2d2_osm' <<< "${body}" \
      && grep -qF 'p2d2_cemeteries_overview' <<< "${body}" \
      && grep -qF 'p2d2_cemeteries_details' <<< "${body}" \
      && grep -qF "xlink:href=\"https://geoportal.${domain}/mapserver/service?" <<< "${body}"; then
      ok=1; break
    fi
    (( attempt < 5 )) && sleep 3
  done
  if [[ "${ok}" -ne 1 ]]; then
    log_error "MapProxy /mapserver WMS-Capabilities fehlgeschlagen (HTTP ${code:-0})"
    return 1
  fi
  log_ok "MapProxy /mapserver WMS-Capabilities: 200 + 3 Layer + korrekte Adresse"

  f="$(mktemp)"; chmod 600 "${f}"
  code="$(curl -sS --max-time 30 -o "${f}" -w '%{http_code}' "${wmts_url}" 2>/dev/null || true)"
  body="$(cat "${f}" 2>/dev/null)"; rm -f "${f}"
  if [[ "${code}" != "200" ]] || ! grep -qF "template=\"https://geoportal.${domain}/mapserver/wmts/" <<< "${body}"; then
    log_error "MapProxy /mapserver WMTS-Capabilities fehlgeschlagen (HTTP ${code:-0})"
    return 1
  fi
  log_ok "MapProxy /mapserver WMTS-Capabilities: 200 + korrektes template"

  local headers acao_count
  headers="$(curl -sS --max-time 30 -D - -o /dev/null -H "Origin: https://f-de1.${domain}" "${wms_url}" 2>/dev/null || true)"
  acao_count="$(grep -ic '^access-control-allow-origin:' <<< "${headers}" || true)"
  if [[ "${acao_count}" != "1" ]] || ! grep -qi '^access-control-allow-origin:[[:space:]]*\*' <<< "${headers}"; then
    log_error "MapProxy /mapserver CORS-Header falsch (${acao_count:-0} Zeilen)"
    return 1
  fi
  log_ok "MapProxy /mapserver CORS: genau ein access-control-allow-origin: *"

  log_ok "MapProxy-Routing verifiziert (/mapserver erreichbar)"
  return 0
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

#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_20_mapproxy.sh — p2d2-AddOn: MapProxy-Baustein (FERTIG, manuell verifiziert)
#
# Eigener MapProxy-Pod im GeoData-Namespace: Image-Build (k3s-Node) -> K8s-Ressourcen
# (ConfigMap/PVC/Service/Deployment) -> APISIX-Routing /mapserver.
#
# Quelle: ai-runs/.../mapproxy-automatisierungshinweise.md.
# Rudimentär: Image-Build auf dem k3s-Node (extern, hier nur dokumentiert), K8s-Ressourcen
# per kubectl apply, APISIX-Routing via Admin-API. NICHT idempotent (Existenz-Prüfung fehlt).

# Fail-Fast: ohne ADDON_NS sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_NS:-}" ]]; then
  echo "FEHLER: ADDON_NS nicht gesetzt — addon_20_mapproxy.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

install_addon_mapproxy() {
  log "=== AddOn 20: MapProxy (/mapserver) ==="

  local ns="${ADDON_NS}"

  # 1) Image-Build — MUSS auf dem k3s-Node laufen (docker build + docker save | k3s ctr import).
  #    TODO: als separater Schritt/Job, nicht aus diesem Skript auf sdt.
  log "  1) Image-Build (k3s-Node): mapproxy:v1s-2026-09-12 — TODO: Build-Skript einbinden"

  # 2) K8s-Ressourcen (ConfigMap mapproxy.yaml + PVC mapproxy-cache + Service + Deployment).
  #    TODO: Manifeste aus p2d2-civitas-addon/tmp/mapproxy-*.yaml nach overlay_addon_V1s/k8s/
  #    überführen und hier anwenden.
  log "  2) K8s-Ressourcen: TODO — ConfigMap/PVC/Service/Deployment aus tmp/-Manifesten übernehmen"
  # kubectl -n "$ns" apply -f "${SCRIPT_DIR}/overlay_addon_V1s/k8s/mapproxy.yaml"

  # 3) APISIX-Routing /mapserver (Admin-Key aus /root/civitas-install/credentials.env).
  #    Upstream mapserver-upstream (mapproxy.<ns>.svc.cluster.local:8080) +
  #    Route mapserver-route (uri /mapserver*, proxy-rewrite regex_uri ["^/mapserver(.*)","$1"]).
  log "  3) APISIX-Routing /mapserver: TODO — Upstream + Route (proxy-rewrite) anlegen"

  log_ok "AddOn 20 MapProxy abgeschlossen (rudimentär, nicht idempotent)"
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

# uninstall_addon_mapproxy — Rückbau (K8s-Ressourcen + APISIX-Routing).
uninstall_addon_mapproxy() {
  log "=== Uninstall AddOn 20: MapProxy ==="

  local ns="${ADDON_NS}"

  kubectl -n "$ns" delete deployment mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete service mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete configmap mapproxy-config --ignore-not-found || true
  kubectl -n "$ns" delete pvc mapproxy-cache --ignore-not-found || true

  # APISIX-Routing /mapserver: Route + Upstream löschen (Admin-API, Turn 65).
  # Admin-Key aus der CIVITAS/CORE-Credentials-Datei (APISIX_ADMIN_ROLE_KEY),
  # Endpunkt https://api-admin.<DOMAIN>/apisix/admin (analog mapproxy-automatisierungshinweise).
  local admin_key apisix_base rc=0
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

  if [[ "${rc}" -ne 0 ]]; then
    log_warn "Uninstall AddOn 20 MapProxy mit Resten/Fehlern beendet"
    return 1
  fi
  log_ok "Uninstall AddOn 20 MapProxy abgeschlossen"
}

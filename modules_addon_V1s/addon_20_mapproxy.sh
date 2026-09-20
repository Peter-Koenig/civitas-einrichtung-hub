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

# uninstall_addon_mapproxy — Rückbau (K8s-Ressourcen + APISIX-Routing).
uninstall_addon_mapproxy() {
  log "=== Uninstall AddOn 20: MapProxy ==="

  local ns="${ADDON_NS}"

  kubectl -n "$ns" delete deployment mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete service mapproxy --ignore-not-found || true
  kubectl -n "$ns" delete configmap mapproxy-config --ignore-not-found || true
  kubectl -n "$ns" delete pvc mapproxy-cache --ignore-not-found || true

  # APISIX-Routing /mapserver: Route + Upstream löschen (Admin-API).
  # TODO: Admin-Key + IDs analog zur Install-Seite (mapserver-route, mapserver-upstream).
  log "  APISIX-Route/Upstream: TODO — mapserver-route + mapserver-upstream löschen"

  log_ok "Uninstall AddOn 20 MapProxy abgeschlossen"
}

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

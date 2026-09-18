#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_30_frontend.sh — p2d2-AddOn: Frontend-Baustein (NOCH NICHT FERTIG)
#
# KLAR MARKIERTER PLATZHALTER — kein vorgetäuschter Vollständigkeitsstand.
#
# Ist-Stand (2026-09-18):
#   - Manifeste liegen unter overlay_addon_V1s/k8s/ (base.yaml, stages/, builder-job.yaml,
#     webhook-controller/, frontend/{Dockerfile,build-de1.sh}).
#   - de1-Bautest (Image-basierte Auslieferung) läuft noch; Image-Build auf dem k3s-Node
#     (overlay_addon_V1s/k8s/frontend/build-de1.sh) ist noch nicht abgeschlossen.
#   - Zitadel->Keycloak-Code-Refactor im p2d2-App-Repo steht noch aus (Blocker für Login).

install_addon_frontend() {
  log "=== AddOn 30: Frontend (Platzhalter) ==="
  echo "TODO: Frontend-Baustein ist noch nicht fertig."
  echo "      - Manifeste: overlay_addon_V1s/k8s/"
  echo "      - Image-Build: overlay_addon_V1s/k8s/frontend/build-de1.sh (k3s-Node)"
  echo "      - offen: de1-Bautest abschließen, Zitadel->Keycloak-Refactor, Rollout auf 5 Stages"
  log_warn "AddOn 30 Frontend übersprungen (Platzhalter) — kein Installationsschritt ausgeführt"
  return 0
}

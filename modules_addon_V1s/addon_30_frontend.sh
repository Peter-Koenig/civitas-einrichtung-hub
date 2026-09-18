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

# uninstall_addon_frontend_DANGER — NICHT in den Standard-Uninstall eingebunden!
# Grund: addon_30_frontend.sh (install) ist nur ein Platzhalter und würde die hier
# gelöschten Ressourcen NICHT wiederherstellen. Nur explizit und einzeln aufrufen:
#   source modules_addon_V1s/addon_30_frontend.sh && uninstall_addon_frontend_DANGER
uninstall_addon_frontend_DANGER() {
  log_error "WARNUNG: Frontend-Uninstall entfernt Ressourcen, die der Install-Platzhalter NICHT wiederherstellt!"
  log_error "  Nur bewusst und einzeln aufrufen — niemals im normalen Uninstall-Durchlauf."
  local ns="${ADDON_NS}"

  # TODO: p2d2-base-config/-secret, 5 Stage-ConfigMaps/Secrets, Webhook-Controller
  #       (Deployment/Service/RBAC), 5 Stage-Deployments/Services/PVCs (bzw. de1-Image-Deployment).
  log "  Frontend-Ressourcen löschen: TODO — bewusst NICHT automatisiert"
  return 0
}

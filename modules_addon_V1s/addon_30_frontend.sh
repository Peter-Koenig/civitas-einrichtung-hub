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

# ── Ingress (idempotent, je Stage) ─────────────────────────────────────────────
# Turn 45: de1-Pod läuft, aber es fehlte ein Ingress. Legt für eine Stage ein
# Ingress nach der funktionierenden idmkeycloak-Vorlage an (Klasse nginx,
# cluster-issuer letsencrypt-prod, TLS-Secret <host>-tls).
ensure_addon_frontend_ingress() {
  local stage="$1"
  [[ -n "${stage}" ]] || { log_error "ensure_addon_frontend_ingress: keine Stage angegeben"; return 1; }

  local svc host secret
  case "${stage}" in
    main) svc="p2d2-main";    host="www.${ADDON_DOMAIN}" ;;
    dev)  svc="p2d2-dev";     host="dev.${ADDON_DOMAIN}" ;;
    de1)  svc="p2d2-f-de1";   host="f-de1.${ADDON_DOMAIN}" ;;
    de2)  svc="p2d2-f-de2";   host="f-de2.${ADDON_DOMAIN}" ;;
    fv)   svc="p2d2-f-fv";    host="f-fv.${ADDON_DOMAIN}" ;;
    *)    log_error "ensure_addon_frontend_ingress: unbekannte Stage '${stage}' (main|dev|de1|de2|fv)"; return 1 ;;
  esac
  secret="${host}-tls"

  if kubectl get ingress "${svc}" -n "${ADDON_NS}" &>/dev/null; then
    log_ok "Ingress ${svc} existiert bereits (idempotent übersprungen)"
    return 0
  fi

  local manifest
  manifest=$(cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${svc}
  namespace: ${ADDON_NS}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: HTTP
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: ${host}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${svc}
            port:
              number: 80
  tls:
  - hosts:
    - ${host}
    secretName: ${secret}
EOF
)

  if ! kubectl auth can-i create ingresses.networking.k8s.io -n "${ADDON_NS}" &>/dev/null; then
    log_error "RBAC: keine create-Berechtigung auf ingresses.networking.k8s.io in ${ADDON_NS} — bitte manuell anwenden:"
    printf '%s\n' "${manifest}"
    return 1
  fi

  printf '%s\n' "${manifest}" | kubectl apply -f - \
    || { log_error "kubectl apply fehlgeschlagen für Ingress ${svc}"; return 1; }
  log_ok "Ingress ${svc} angelegt (${host} -> ${svc}:80; TLS-Secret ${secret} via cert-manager)"
}

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

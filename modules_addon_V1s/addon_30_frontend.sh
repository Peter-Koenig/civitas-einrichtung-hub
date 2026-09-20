#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_30_frontend.sh — p2d2-AddOn: Frontend-Baustein (5 Stages, image-basiert)
#
# Ist-Stand (Turn 55, 2026-09-20): de1 end-to-end verifiziert (HTTP 200, TLS, WFS).
# Generalisiert auf alle 5 Stages (main/dev/de1/de2/fv):
#   - Basis-ConfigMap/-Secret (atomar, alle 5 Basis-Secret-Keys)
#   - 5 Stage-Manifeste (image-basiert, stages/<stage>.yaml)
#   - Ingress je Stage (ensure_addon_frontend_ingress, RBAC-Selbstprüfung)
#   - Image-Build-Hinweis (Node-Schritt: frontend/build-stage.sh <stage>)
#
# Image-Build (k3s-Node, Docker/k3s-ctr):
#   overlay_addon_V1s/k8s/frontend/build-stage.sh <stage>   # main|dev|de1|de2|fv
#   Wrapper: build-{main,dev,de1,de2,fv}.sh

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
  log "=== AddOn 30: Frontend (5 Stages, image-basiert) ==="

  local ns="${ADDON_NS}"
  local overlay_dir
  overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay_addon_V1s/k8s" && pwd)"

  # Basis-ConfigMap + Basis-Secret. WICHTIG: p2d2-base-secret enthält ALLE 5 Keys
  # (ALTCHA_HMAC_KEY, SMTP_PASS, OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET) und
  # wird atomar (nie als Teilmenge) angelegt — Datenverlust vermeiden. Die CHANGEME-
  # Platzhalter werden von Peter NACH der Erst-Anlage mit echten Werten befüllt.
  if kubectl -n "${ns}" get secret p2d2-base-secret &>/dev/null; then
    log_ok "p2d2-base-secret existiert bereits — wird NICHT überschrieben (echte Werte bleiben)"
  else
    kubectl apply -f "${overlay_dir}/base.yaml" \
      || { log_error "kubectl apply base.yaml fehlgeschlagen"; return 1; }
    log_ok "Basis-ConfigMap + Basis-Secret angelegt (p2d2-base-config, p2d2-base-secret, 5 Keys)"
  fi

  # Stage-Manifeste (ConfigMap + Secret + Deployment + Service je Stage, image-basiert).
  local stage
  for stage in main dev de1 de2 fv; do
    local manifest="${overlay_dir}/stages/${stage}.yaml"
    if [[ -f "${manifest}" ]]; then
      kubectl apply -f "${manifest}" \
        || { log_error "kubectl apply ${manifest} fehlgeschlagen"; return 1; }
      log_ok "Stage ${stage}: Manifest angewendet"
    else
      log_warn "Stage-Manifest fehlt: ${manifest} — übersprungen"
    fi
  done

  # Ingress je Stage (RBAC-Selbstprüfung + Peter-Handoff in ensure_addon_frontend_ingress).
  for stage in main dev de1 de2 fv; do
    ensure_addon_frontend_ingress "${stage}" \
      || log_warn "Ingress ${stage} nicht angelegt — bitte manuell (siehe Ausgabe oben)"
  done

  # Image-Build ist ein Node-Schritt (Docker/k3s-ctr existieren nur auf dem k3s-Node,
  # nicht auf sdt) — daher als Hinweis ausgeben statt automatisch ausführen.
  echo ""
  log "  Image-Build pro Stage manuell auf dem k3s-Node ausführen:"
  echo "    set -a; source ../.env.p2d2-addon; set +a"
  echo "    ./overlay_addon_V1s/k8s/frontend/build-stage.sh <stage>   # main|dev|de1|de2|fv"
  echo "    # Wrapper: build-main.sh / build-dev.sh / build-de1.sh / build-de2.sh / build-fv.sh"
  echo "    kubectl -n ${ns} rollout restart deployment/<deployment>"
  echo ""
  log_ok "AddOn 30 Frontend: Manifeste + Ingress angewendet; Image-Build pro Stage manuell (Node)"
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

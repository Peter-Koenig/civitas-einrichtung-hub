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
#
# WICHTIG (Turn 57): Dieses Modul darf NICHT isoliert gesourct werden — ADDON_NS und
# ADDON_DOMAIN müssen vorher vom Hauptskript (p2d2-civitas-addon-v1s.sh, Zeile 39/41)
# exportiert sein. Für manuelle Tests: `export ADDON_NS=... ADDON_DOMAIN=...` vorher setzen.

# Fail-Fast: ohne ADDON_NS/ADDON_DOMAIN sofort abbrechen (verhindert stilles Schreiben
# in die falsche Namespace bzw. Secret-Überschreibung — Incident Turn 57).
if [[ -z "${ADDON_NS:-}" || -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_NS/ADDON_DOMAIN nicht gesetzt — addon_30_frontend.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

# ── Env-Vars-Pipeline (.env.p2d2-addon → Secrets) ─────────────────────────────
# Turn 59: .env.p2d2-addon ist die einzige Quelle der Wahrheit für mandantenabhängige
# Werte (Domains, User-IDs, Secrets). Diese Funktionen lesen die P2D2_*-Variablen
# (vom Hauptskript exportiert) und schreiben die Basis-/Stage-Secrets atomar.

# _addon_get <name> — liest eine Variable indirekt über ihren Namen (leer wenn ungesetzt).
_addon_get() {
  printf '%s' "${!1:-}"
}

# _addon_ensure_secret <namespace> <name> <key=value>...
# Legt das Secret NUR bei Erstanlage an (existiert es, wird es NICHT überschrieben).
# Fail-fast: leere/CHANGEME-Werte brechen ab, bevor irgendein Secret geschrieben wird.
_addon_ensure_secret() {
  local ns="$1" name="$2"; shift 2
  local kv k v args=()
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    if [[ -z "${v}" || "${v}" == "CHANGEME" ]]; then
      log_error "Secret ${name}: Wert für '${k}' fehlt oder ist CHANGEME — bitte in .env.p2d2-addon setzen (P2D2_*)."
      return 1
    fi
    args+=(--from-literal="${k}=${v}")
  done
  if kubectl -n "${ns}" get secret "${name}" &>/dev/null; then
    log_ok "Secret ${name} existiert bereits — wird NICHT überschrieben"
    return 0
  fi
  kubectl -n "${ns}" create secret generic "${name}" "${args[@]}" \
    || { log_error "Secret ${name} konnte nicht angelegt werden"; return 1; }
  log_ok "Secret ${name} angelegt (${#args[@]} Keys, atomar)"
}

# apply_addon_secrets — befüllt Basis- + 5 Stage-Secrets aus .env.p2d2-addon.
apply_addon_secrets() {
  local ns="${ADDON_NS}"
  local iam_creds="${ADDON_IAM_CREDENTIALS_FILE:-/root/civitas-install/p2d2-addon-credentials.env}"

  # OIDC: bevorzugt aus .env.p2d2-addon; Fallback aus dem IAM-credentials-File,
  # das ensure_p2d2_oidc_client() (Turn 40) generiert — vermeidet doppelte Pflege.
  local oidc_issuer oidc_client_id oidc_client_secret
  oidc_issuer="$(_addon_get P2D2_BASE_OIDC_ISSUER)"
  oidc_client_id="$(_addon_get P2D2_BASE_OIDC_CLIENT_ID)"
  oidc_client_secret="$(_addon_get P2D2_BASE_OIDC_CLIENT_SECRET)"
  if [[ -f "${iam_creds}" ]]; then
    [[ -z "${oidc_client_id}" ]]     && oidc_client_id="$(sed -n 's/^P2D2_BASE_OIDC_CLIENT_ID=//p' "${iam_creds}" | head -n1)"
    [[ -z "${oidc_client_secret}" ]] && oidc_client_secret="$(sed -n 's/^P2D2_BASE_OIDC_CLIENT_SECRET=//p' "${iam_creds}" | head -n1)"
    [[ -z "${oidc_issuer}" ]]        && oidc_issuer="$(sed -n 's/^P2D2_BASE_OIDC_ISSUER=//p' "${iam_creds}" | head -n1)"
  fi

  # Basis-Secret (5 Keys).
  _addon_ensure_secret "${ns}" "p2d2-base-secret" \
    "ALTCHA_HMAC_KEY=$(_addon_get P2D2_BASE_ALTCHA_HMAC_KEY)" \
    "SMTP_PASS=$(_addon_get P2D2_BASE_SMTP_PASS)" \
    "OIDC_ISSUER=${oidc_issuer}" \
    "OIDC_CLIENT_ID=${oidc_client_id}" \
    "OIDC_CLIENT_SECRET=${oidc_client_secret}" || return 1

  # Stage-Secrets (4 Keys je Stage).
  local key secret suffix
  for key in MAIN DEVELOP DE1 DE2 FV; do
    case "${key}" in
      MAIN)    secret="p2d2-main-secret";   suffix="MAIN" ;;
      DEVELOP) secret="p2d2-dev-secret";    suffix="DEVELOP" ;;
      DE1)     secret="p2d2-f-de1-secret";  suffix="DE1" ;;
      DE2)     secret="p2d2-f-de2-secret";  suffix="DE2" ;;
      FV)      secret="p2d2-f-fv-secret";   suffix="FV" ;;
    esac
    # WFST_PASSWORD (plain) und WFST_PW_<KEY> (suffigiert) sind derselbe Wert
    # (GeoServer-WFS-T-Passwort) — einmal aus .env lesen, nicht doppelt pflegen.
    local wfst_password
    wfst_password="$(_addon_get "P2D2_${key}_WFST_PASSWORD")"
    _addon_ensure_secret "${ns}" "${secret}" \
      "DB_PASSWORD=$(_addon_get "P2D2_${key}_DB_PASSWORD")" \
      "WFST_PASSWORD=${wfst_password}" \
      "WFST_PW_${suffix}=${wfst_password}" \
      "SESSION_SECRET=$(_addon_get "P2D2_${key}_SESSION_SECRET")" || return 1
  done

  log_ok "Basis- + Stage-Secrets aus .env.p2d2-addon befüllt (nur Erstanlage)"
  return 0
}

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

  # 1) Secrets aus .env.p2d2-addon befüllen (Basis + 5 Stages, atomar, nur Erstanlage).
  apply_addon_secrets || return 1

  # 2) Basis-ConfigMap (nicht-sensibel; Secret wird von apply_addon_secrets verwaltet).
  kubectl apply -f "${overlay_dir}/base.yaml" \
    || { log_error "kubectl apply base.yaml fehlgeschlagen"; return 1; }
  log_ok "Basis-ConfigMap angewendet (p2d2-base-config)"

  # 3) Stage-Manifeste (ConfigMap + Deployment + Service je Stage, image-basiert).
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

  # 4) Ingress je Stage (RBAC-Selbstprüfung + Peter-Handoff in ensure_addon_frontend_ingress).
  for stage in main dev de1 de2 fv; do
    ensure_addon_frontend_ingress "${stage}" \
      || log_warn "Ingress ${stage} nicht angelegt — bitte manuell (siehe Ausgabe oben)"
  done

  # 5) Image-Build ist ein Node-Schritt (Docker/k3s-ctr existieren nur auf dem k3s-Node).
  echo ""
  log "  Image-Build pro Stage manuell auf dem k3s-Node ausführen:"
  echo "    set -a; source ../.env.p2d2-addon; set +a"
  echo "    ./overlay_addon_V1s/k8s/frontend/build-stage.sh <stage>   # main|dev|de1|de2|fv"
  echo "    # Wrapper: build-main.sh / build-dev.sh / build-de1.sh / build-de2.sh / build-fv.sh"
  echo "    kubectl -n ${ns} rollout restart deployment/<deployment>"
  echo ""
  log_ok "AddOn 30 Frontend: Secrets + Manifeste + Ingress angewendet; Image-Build pro Stage manuell (Node)"
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

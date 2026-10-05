#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_30_frontend.sh — p2d2-AddOn: Frontend-Baustein (5 Stages, image-basiert)
#
# Ist-Stand (Turn 55, 2026-09-20): de1 end-to-end verifiziert (HTTP 200, TLS, WFS).
# Generalisiert auf alle 5 Stages (main/dev/de1/de2/fv):
#   - Basis-/Stage-ConfigMaps werden aus .env.p2d2-addon generiert (F2, Allowlist)
#   - Basis-/Stage-Secrets atomar aus .env.p2d2-addon (apply_addon_secrets)
#   - 5 Stage-Manifeste als Templates (image-basiert, stages/<stage>.yaml, F3/F6)
#   - Ingress je Stage (ensure_addon_frontend_ingress, RBAC-Selbstprüfung)
#
# Image-Build (k3s-Node, Docker/k3s-ctr):
#   overlay_addon_V1s/k8s/frontend/build-stage.sh <stage>   # main|dev|de1|de2|fv
#   Wrapper: build-{main,dev,de1,de2,fv}.sh
#   Tag: deterministisch cfg-<12-hex> (F4, addon_compute_image_tag), Übergabe über
#   .frontend-tag-<stage> unter ${VM_REMOTE_INSTALL_DIR} (F6).
#
# WICHTIG (Turn 57): Dieses Modul darf NICHT isoliert gesourct werden — ADDON_NS und
# ADDON_DOMAIN müssen vorher vom Hauptskript (p2d2-civitas-addon-v1s.sh, Zeile 39/41)
# exportiert sein. Für manuelle Tests: `export ADDON_NS=... ADDON_DOMAIN=...` vorher setzen.

# Fail-Fast beim Funktionsaufruf (nicht beim Sourcen): ADDON_NS/ADDON_DOMAIN müssen
# gesetzt sein. ADDON_DOMAIN wird erst im VM-Ablauf aus DOMAIN_NAME abgeleitet (B1),
# daher ist eine Source-Time-Prüfung nicht möglich. Verhindert stilles Schreiben in
# die falsche Namespace bzw. Secret-Überschreibung (Incident Turn 57).
addon_frontend_guard() {
  if [[ -z "${ADDON_NS:-}" || -z "${ADDON_DOMAIN:-}" ]]; then
    log_error "ADDON_NS/ADDON_DOMAIN nicht gesetzt — addon_30_frontend.sh nur über p2d2-civitas-addon-v1s.sh aufrufen"
    return 1
  fi
  return 0
}

# ── Env-Vars-Pipeline (.env.p2d2-addon → Secrets) ─────────────────────────────
# Turn 59: .env.p2d2-addon ist die einzige Quelle der Wahrheit für mandantenabhängige
# Werte (Domains, User-IDs, Secrets). Diese Funktionen lesen die P2D2_*-Variablen
# (vom Hauptskript exportiert) und schreiben die Basis-/Stage-Secrets atomar.

# _addon_get <name> — liest eine Variable indirekt über ihren Namen (leer wenn ungesetzt).
_addon_get() {
  printf '%s' "${!1:-}"
}

# addon_yaml_quote <wert> — gibt den Wert YAML-sicher (doppelt gequotet) aus.
addon_yaml_quote() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '"%s"' "${v}"
}

# addon_configmap_base — YAML der Basis-ConfigMap (stdout). Ausschliesslich
# nicht-sensitive Werte aus der Allowlist (F1), deterministische Key-Reihenfolge.
addon_configmap_base() {
  local ns="${ADDON_NS:-}"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: p2d2-base-config
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: p2d2-addon
data:
  APP_DEBUG: $(addon_yaml_quote "$(_addon_get P2D2_BASE_APP_DEBUG)")
  DEFAULT_CATEGORY_ICON: $(addon_yaml_quote "$(_addon_get P2D2_BASE_DEFAULT_CATEGORY_ICON)")
  DB_HOST: $(addon_yaml_quote "$(_addon_get P2D2_BASE_DB_HOST)")
  DB_PORT: $(addon_yaml_quote "$(_addon_get P2D2_BASE_DB_PORT)")
  DB_NAME: $(addon_yaml_quote "$(_addon_get P2D2_BASE_DB_NAME)")
  WFST_NAMESPACE: $(addon_yaml_quote "$(_addon_get P2D2_BASE_WFST_NAMESPACE)")
  PUBLIC_WFST_ENDPOINT: $(addon_yaml_quote "$(_addon_get P2D2_BASE_PUBLIC_WFST_ENDPOINT)")
  PUBLIC_MAPSERVER_URL: $(addon_yaml_quote "$(_addon_get P2D2_BASE_PUBLIC_MAPSERVER_URL)")
  SMTP_HOST: $(addon_yaml_quote "$(_addon_get P2D2_BASE_SMTP_HOST)")
  SMTP_PORT: $(addon_yaml_quote "$(_addon_get P2D2_BASE_SMTP_PORT)")
  SMTP_SECURE: $(addon_yaml_quote "$(_addon_get P2D2_BASE_SMTP_SECURE)")
  SMTP_USER: $(addon_yaml_quote "$(_addon_get P2D2_BASE_SMTP_USER)")
  CONTACT_EMAIL_TO: $(addon_yaml_quote "$(_addon_get P2D2_BASE_CONTACT_EMAIL_TO)")
  CONTACT_EMAIL_FROM: $(addon_yaml_quote "$(_addon_get P2D2_BASE_CONTACT_EMAIL_FROM)")
EOF
}

# addon_configmap_stage <key> — YAML der Stage-ConfigMap (stdout).
addon_configmap_stage() {
  local key="$1" cm suffix
  case "${key}" in
    MAIN)    cm="p2d2-main-config";  suffix="MAIN" ;;
    DEVELOP) cm="p2d2-dev-config";   suffix="DEVELOP" ;;
    DE1)     cm="p2d2-f-de1-config"; suffix="DE1" ;;
    DE2)     cm="p2d2-f-de2-config"; suffix="DE2" ;;
    FV)      cm="p2d2-f-fv-config";  suffix="FV" ;;
  esac
  local ns="${ADDON_NS:-}"
  local db_user wfst_ws site wfst_ep wfst_user
  db_user="$(_addon_get "P2D2_${key}_DB_USER")"
  wfst_ws="$(_addon_get "P2D2_${key}_WFST_WORKSPACE")"
  site="$(_addon_get "P2D2_${key}_PUBLIC_SITE_URL")"
  wfst_ep="$(_addon_get "P2D2_${key}_WFST_ENDPOINT")"
  wfst_user="$(_addon_get "P2D2_${key}_WFST_USERNAME")"
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${cm}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: p2d2-addon
data:
  DB_USER: $(addon_yaml_quote "${db_user}")
  WFST_WORKSPACE: $(addon_yaml_quote "${wfst_ws}")
  PUBLIC_WFST_WORKSPACE: $(addon_yaml_quote "${wfst_ws}")
  PUBLIC_SITE_URL: $(addon_yaml_quote "${site}")
  WFST_ENDPOINT: $(addon_yaml_quote "${wfst_ep}")
  WFST_ENDPOINT_${suffix}: $(addon_yaml_quote "${wfst_ep}")
  WFST_USERNAME: $(addon_yaml_quote "${wfst_user}")
  WFST_USER_${suffix}: $(addon_yaml_quote "${wfst_user}")
EOF
}

# addon_configmap_hash <key> — Hash der Basis- + Stage-ConfigMap-Daten (Rollout).
addon_configmap_hash() {
  local key="$1"
  local combined
  combined="$(addon_configmap_base; addon_configmap_stage "${key}")"
  printf '%s' "${combined}" | sha256sum | awk '{print $1}'
}

# addon_render_stage_manifest <template> <namespace> <image> <config_hash>
addon_render_stage_manifest() {
  local template="$1" ns="$2" image="$3" hash="$4"
  sed -e "s|__P2D2_NAMESPACE__|${ns}|g" \
      -e "s|__P2D2_IMAGE__|${image}|g" \
      -e "s|__P2D2_CONFIG_HASH__|${hash}|g" \
      "${template}"
}

# addon_stage_key <stage> — bildet den kleinen Stage-Namen auf den Env-Suffix ab.
addon_stage_key() {
  case "$1" in
    main) printf 'MAIN' ;;
    dev)  printf 'DEVELOP' ;;
    de1)  printf 'DE1' ;;
    de2)  printf 'DE2' ;;
    fv)   printf 'FV' ;;
  esac
}

# addon_compute_image_tag <stage> <git_host> <git_repo_path> <git_branch> \
#     <commit_sha> <script_sha> <build_script> <site_url> <wfst_endpoint> \
#     <wfst_workspace> <mapserver_url> <icon>
# Reine Funktion (F4): bildet aus sortierten NAME=WERT-Zeilen den SHA-256 und gibt
# die ersten 12 Hex-Zeichen als cfg-<12-hex> aus. Die Eingaben sind ausschliesslich
# nicht-sensitive Produkt- und Buildwerte — niemals Tokens, Passwörter oder andere
# Secrets in den Hash aufnehmen. Ohne Git-/Cluster-Zugriff testbar.
addon_compute_image_tag() {
  local stage="$1" git_host="$2" git_repo_path="$3" git_branch="$4" \
        commit_sha="$5" script_sha="$6" build_script="$7" site_url="$8" \
        wfst_endpoint="$9" wfst_workspace="${10}" mapserver_url="${11}" icon="${12}"
  local canonical
  canonical="$(printf '%s\n' \
    "BUILD_SCRIPT=${build_script}" \
    "COMMIT_SHA=${commit_sha}" \
    "DEFAULT_CATEGORY_ICON=${icon}" \
    "GIT_BRANCH=${git_branch}" \
    "GIT_HOST=${git_host}" \
    "GIT_REPO_PATH=${git_repo_path}" \
    "PUBLIC_MAPSERVER_URL=${mapserver_url}" \
    "PUBLIC_SITE_URL=${site_url}" \
    "PUBLIC_WFST_ENDPOINT=${wfst_endpoint}" \
    "PUBLIC_WFST_WORKSPACE=${wfst_workspace}" \
    "SCRIPT_SHA=${script_sha}" \
    "STAGE=${stage}")"
  printf 'cfg-%s' "$(printf '%s' "${canonical}" | sha256sum | awk '{print substr($1,1,12)}')"
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

# ── Zertifikats-Issuer (Schritt 2c) ────────────────────────────────────────────
# addon_pick_cert_issuer <explicit> [<issuer>...] — reine Entscheidung (U1, testbar).
# explicit != auto -> unverändert zurück. auto -> alle übergebenen Issuer müssen
# identisch sein; leer oder uneinheitlich ist ein Fehler.
addon_pick_cert_issuer() {
  local explicit="$1"; shift
  if [[ "${explicit}" != "auto" ]]; then
    printf '%s' "${explicit}"
    return 0
  fi
  if [[ "$#" -eq 0 ]]; then
    log_error "addon_pick_cert_issuer: keine Core-Ingresses mit TLS-Block gefunden — P2D2_CERT_ISSUER explizit setzen"
    return 1
  fi
  local first="$1" issuer
  for issuer in "$@"; do
    if [[ -z "${issuer}" ]]; then
      log_error "addon_pick_cert_issuer: ein Core-Ingress trägt keine cert-manager.io/cluster-issuer-Annotation"
      return 1
    fi
    if [[ "${issuer}" != "${first}" ]]; then
      log_error "addon_pick_cert_issuer: uneinheitliche Core-Issuer ('${first}' vs '${issuer}') — P2D2_CERT_ISSUER explizit setzen"
      return 1
    fi
  done
  printf '%s' "${first}"
  return 0
}

# addon_resolve_cert_issuer — löst den Issuer auf (U1). Bei auto werden die
# Core-Ingresses mit TLS-Block in ${ADDON_IAM_NS} gelesen (Default cc-prd-access-stack).
addon_resolve_cert_issuer() {
  local explicit="${P2D2_CERT_ISSUER:-auto}"
  if [[ "${explicit}" != "auto" ]]; then
    addon_pick_cert_issuer "${explicit}"
    return $?
  fi
  local iam_ns="${ADDON_IAM_NS:-cc-prd-access-stack}"
  local -a issuers=()
  local issuer
  while IFS= read -r issuer; do
    issuers+=("${issuer}")
  done < <(kubectl get ingress -n "${iam_ns}" -o json 2>/dev/null \
    | jq -r '.items[]? | select(.spec.tls != null) | (.metadata.annotations["cert-manager.io/cluster-issuer"] // "")' 2>/dev/null)
  if [[ ${#issuers[@]} -eq 0 ]]; then
    addon_pick_cert_issuer "${explicit}"
  else
    addon_pick_cert_issuer "${explicit}" "${issuers[@]}"
  fi
}

# addon_cert_is_acme <issuer> — 0 wenn ACME-Issuer (letsencrypt-*), sonst 1.
addon_cert_is_acme() {
  case "$1" in
    letsencrypt-staging|letsencrypt-prod) return 0 ;;
    *) return 1 ;;
  esac
}

# addon_ensure_cert_issuer_ready <issuer> — prüft nur, legt nichts an (U2).
addon_ensure_cert_issuer_ready() {
  local issuer="$1" ready
  if ! kubectl get clusterissuer "${issuer}" &>/dev/null; then
    log_error "ClusterIssuer ${issuer} nicht vorhanden — P2D2_CERT_ISSUER prüfen"
    return 1
  fi
  ready="$(kubectl get clusterissuer "${issuer}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${ready}" != "True" ]]; then
    log_error "ClusterIssuer ${issuer} ist nicht Ready (Status: ${ready:-unbekannt})"
    return 1
  fi
  log_ok "ClusterIssuer ${issuer} vorhanden und Ready"
  return 0
}

# addon_frontend_host <stage> / addon_frontend_svc <stage> — Stage-Mapping.
addon_frontend_host() {
  case "$1" in
    main) printf 'www.%s'   "${ADDON_DOMAIN}" ;;
    dev)  printf 'dev.%s'   "${ADDON_DOMAIN}" ;;
    de1)  printf 'f-de1.%s' "${ADDON_DOMAIN}" ;;
    de2)  printf 'f-de2.%s' "${ADDON_DOMAIN}" ;;
    fv)   printf 'f-fv.%s'  "${ADDON_DOMAIN}" ;;
  esac
}
addon_frontend_svc() {
  case "$1" in
    main) printf 'p2d2-main' ;;
    dev)  printf 'p2d2-dev' ;;
    de1)  printf 'p2d2-f-de1' ;;
    de2)  printf 'p2d2-f-de2' ;;
    fv)   printf 'p2d2-f-fv' ;;
  esac
}

# addon_render_ingress <stage> <issuer> — reines Ingress-Rendering (U4).
addon_render_ingress() {
  local stage="$1" issuer="$2" svc host secret
  svc="$(addon_frontend_svc "${stage}")"
  host="$(addon_frontend_host "${stage}")"
  [[ -n "${svc}" && -n "${host}" ]] || { log_error "addon_render_ingress: unbekannte Stage '${stage}' (main|dev|de1|de2|fv)"; return 1; }
  secret="${host}-tls"
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${svc}
  namespace: ${ADDON_NS}
  annotations:
    cert-manager.io/cluster-issuer: ${issuer}
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
}

# ── Ingress (idempotent, je Stage) ─────────────────────────────────────────────
ensure_addon_frontend_ingress() {
  local stage="$1" issuer="$2"
  [[ -n "${stage}" && -n "${issuer}" ]] || { log_error "ensure_addon_frontend_ingress: Stage und Issuer erforderlich"; return 1; }

  local svc host secret
  svc="$(addon_frontend_svc "${stage}")"
  host="$(addon_frontend_host "${stage}")"
  [[ -n "${svc}" && -n "${host}" ]] || { log_error "ensure_addon_frontend_ingress: unbekannte Stage '${stage}' (main|dev|de1|de2|fv)"; return 1; }
  secret="${host}-tls"

  if kubectl get ingress "${svc}" -n "${ADDON_NS}" &>/dev/null; then
    # U5: vorhandener Ingress mit abweichendem Issuer -> nur warnen, nie patchen.
    local current_issuer
    current_issuer="$(kubectl get ingress "${svc}" -n "${ADDON_NS}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true)"
    if [[ -n "${current_issuer}" && "${current_issuer}" != "${issuer}" ]]; then
      log_warn "Ingress ${svc} existiert mit Issuer '${current_issuer}' (aufgelöst: '${issuer}') — nicht automatisch gepatcht"
    else
      log_ok "Ingress ${svc} existiert bereits (idempotent übersprungen)"
    fi
    return 0
  fi

  # U3: Sperre bei ACME-Issuer und fehlendem TLS-Secret.
  if [[ "${P2D2_CERT_BLOCK_NEW_REQUESTS:-false}" == "true" ]] && addon_cert_is_acme "${issuer}"; then
    if ! kubectl -n "${ADDON_NS}" get secret "${secret}" &>/dev/null; then
      log_error "P2D2_CERT_BLOCK_NEW_REQUESTS=true und Secret ${secret} fehlt — keine neue Zertifikatsanforderung für ${host}"
      return 1
    fi
  fi

  local manifest
  manifest="$(addon_render_ingress "${stage}" "${issuer}")" || return 1

  if ! kubectl auth can-i create ingresses.networking.k8s.io -n "${ADDON_NS}" &>/dev/null; then
    log_error "RBAC: keine create-Berechtigung auf ingresses.networking.k8s.io in ${ADDON_NS} — bitte manuell anwenden:"
    printf '%s\n' "${manifest}"
    return 1
  fi

  printf '%s\n' "${manifest}" | kubectl apply -f - \
    || { log_error "kubectl apply fehlgeschlagen für Ingress ${svc}"; return 1; }
  log_ok "Ingress ${svc} angelegt (${host} -> ${svc}:80; TLS-Secret ${secret}, Issuer ${issuer})"
}

# install_addon_frontend_build — baut die Runtime-Images aller 5 Stages auf dem
# k3s-Node (Docker + k3s ctr import) über build-stage.sh. Eigener, im VM-Kontext
# automatisch aufgerufener Teilschritt (Turn 63/65) — läuft VOR install_addon_frontend,
# damit die image-basierten Deployments die Images lokal vorfinden (IfNotPresent).
# Token kommen aus der bereits geladenen .env.p2d2-addon (P2D2_GITHUB_TOKEN/P2D2_GITLAB_TOKEN).
install_addon_frontend_build() {
  log "=== AddOn 30: Frontend-Image-Build (5 Stages, k3s-Node) ==="

  local overlay_dir tag_dir
  overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay_addon_V1s/k8s" && pwd)"
  tag_dir="${VM_REMOTE_INSTALL_DIR:-/root/p2d2-addon}"
  # U7a: veraltete Tag-Zustandsdateien löschen, damit install_addon_frontend
  # keinen alten Tag liest, falls ein früherer Build abgebrochen ist.
  local stale
  for stale in "${tag_dir}"/.frontend-tag-*; do
    [[ -e "${stale}" ]] && rm -f "${stale}"
  done
  local build_script="${overlay_dir}/frontend/build-stage.sh"
  if [[ ! -x "${build_script}" ]]; then
    log_error "build-stage.sh nicht gefunden/ausführbar: ${build_script}"
    return 1
  fi

  # ── Build-Engine (Docker) bereitstellen ─────────────────────────────────────
  # Verbindliche Build-Engine der CIVITAS/CORE-V1s-Umgebung ist Docker. Auf der
  # k3s/containerd-VM ist Docker NICHT dauerhaft installiert. Analog zu
  # modules_V1s/06c_image_build.sh wird Docker nur dann temporär installiert,
  # wenn es fehlt, und nach dem Build wieder deinstalliert — kein paralleler
  # Docker-Daemon auf der VM, kein stilles Zurücklassen.
  local docker_installed_by_script="false"
  if command -v docker >/dev/null 2>&1; then
    log_ok "Build-Engine Docker vorhanden: $(command -v docker) ($(docker --version 2>&1))"
  else
    log "Build-Engine Docker nicht vorhanden — installiere temporär (docker.io) …"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || { log_error "apt-get update fehlgeschlagen — Docker-Installation nicht möglich"; return 1; }
    apt-get install -y docker.io || { log_error "docker.io-Installation fehlgeschlagen — Build-Engine fehlt"; return 1; }
    docker_installed_by_script="true"
    log_ok "Docker temporär installiert: $(command -v docker) ($(docker --version 2>&1))"
  fi

  # Fail-Fast: Build-Engine (Binary + Daemon) muss VOR dem Git-Clone nutzbar sein.
  if ! command -v docker >/dev/null 2>&1; then
    log_error "Build-Engine Docker nicht verfügbar (kein docker-Binary im PATH)"
    log_error "  Abbruch vor dem Build. Bitte docker.io installieren oder die Build-Umgebung prüfen."
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log_error "Build-Engine Docker nicht nutzbar (Docker-Daemon nicht erreichbar): $(command -v docker)"
    log_error "  Abbruch vor dem Build. Bitte Daemon starten (systemctl start docker) oder docker.io neu installieren."
    return 1
  fi

  local stage tag_file tag build_failed=0
  for stage in main dev de1 de2 fv; do
    tag_file="${tag_dir}/.frontend-tag-${stage}"
    log "  Image-Build ${stage} (${build_script} ${stage}) …"
    # F6: build-stage.sh schreibt den berechneten Tag (cfg-<12-hex>) in die
    # Zustandsdatei; install_addon_frontend liest ihn und rendert __P2D2_IMAGE__.
    if ! FRONTEND_TAG_FILE="${tag_file}" "${build_script}" "${stage}"; then
      log_error "Image-Build ${stage} fehlgeschlagen — Abbruch"
      build_failed=1
      break
    fi
    tag="$(cat "${tag_file}" 2>/dev/null || true)"
    if [[ -z "${tag}" ]]; then
      log_error "Image-Build ${stage}: kein Tag in ${tag_file} — build-stage.sh prüfen"
      build_failed=1
      break
    fi
    log_ok "Image-Build ${stage}: Tag ${tag} geschrieben"
  done

  # ── Docker ggf. wieder deinstallieren (auch bei Build-Fehler) ──────────────
  if [[ "${docker_installed_by_script}" == "true" ]]; then
    log "Deinstalliere temporär installiertes Docker (Sicherheitscheck) …"
    if apt-get purge --dry-run docker.io | grep -qE "Purg docker\.io(:[a-z0-9]+)?[[:space:]]"; then
      apt-get purge -y docker.io || log_warn "Docker-Deinstallation fehlgeschlagen — bitte manuell prüfen"
      apt-get autoremove -y || true
      log_ok "Docker deinstalliert (war temporär installiert)"
    else
      log_warn "Sicherheitscheck fehlgeschlagen — Docker-Deinstallation übersprungen (bitte manuell prüfen)"
    fi
  fi

  if [[ "${build_failed}" -ne 0 ]]; then
    return 1
  fi

  log_ok "Frontend-Images für alle 5 Stages gebaut + in k3s importiert"
  return 0
}

install_addon_frontend() {
  log "=== AddOn 30: Frontend (5 Stages, image-basiert) ==="
  addon_frontend_guard || return 1

  local ns="${ADDON_NS}"
  local overlay_dir
  overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay_addon_V1s/k8s" && pwd)"
  local tag_dir="${VM_REMOTE_INSTALL_DIR:-/root/p2d2-addon}"

  # 1) Secrets aus .env.p2d2-addon befüllen (Basis + 5 Stages, atomar, nur Erstanlage).
  apply_addon_secrets || return 1

  # 2) Basis-ConfigMap generieren und anwenden (nicht-sensibel, Allowlist F1).
  addon_configmap_base | kubectl apply -f - \
    || { log_error "kubectl apply Basis-ConfigMap fehlgeschlagen"; return 1; }
  log_ok "Basis-ConfigMap angewendet (p2d2-base-config)"

  # 3) Stage-ConfigMaps generieren, Manifeste rendern und anwenden.
  local stage key tag_file tag image hash manifest
  for stage in main dev de1 de2 fv; do
    key="$(addon_stage_key "${stage}")"

    addon_configmap_stage "${key}" | kubectl apply -f - \
      || { log_error "kubectl apply Stage-ConfigMap ${stage} fehlgeschlagen"; return 1; }
    log_ok "Stage ${stage}: ConfigMap angewendet"

    # Image-Tag aus der Zustandsdatei lesen (install_addon_frontend_build schreibt sie).
    tag_file="${tag_dir}/.frontend-tag-${stage}"
    tag=""
    [[ -f "${tag_file}" ]] && tag="$(cat "${tag_file}" 2>/dev/null || true)"
    if [[ -z "${tag}" ]]; then
      log_error "Image-Tag fehlt für Stage ${stage} (${tag_file}) — zuerst install_addon_frontend_build ausführen"
      return 1
    fi
    image="p2d2-frontend-${stage}:${tag}"
    hash="$(addon_configmap_hash "${key}")"

    manifest="${overlay_dir}/stages/${stage}.yaml"
    if [[ -f "${manifest}" ]]; then
      addon_render_stage_manifest "${manifest}" "${ns}" "${image}" "${hash}" | kubectl apply -f - \
        || { log_error "kubectl apply ${manifest} fehlgeschlagen"; return 1; }
      log_ok "Stage ${stage}: Manifest angewendet (${image})"
    else
      log_warn "Stage-Manifest fehlt: ${manifest} — übersprungen"
    fi
  done

  # 4) Zertifikats-Issuer auflösen + ClusterIssuer prüfen (U1/U2), dann Ingress je Stage.
  local cert_issuer
  cert_issuer="$(addon_resolve_cert_issuer)" || return 1
  addon_ensure_cert_issuer_ready "${cert_issuer}" || return 1
  for stage in main dev de1 de2 fv; do
    ensure_addon_frontend_ingress "${stage}" "${cert_issuer}" \
      || log_warn "Ingress ${stage} nicht angelegt — bitte manuell (siehe Ausgabe oben)"
  done

  # 5) Image-Build ist bereits als vorgelagerter Teilschritt gelaufen
  #     (install_addon_frontend_build, vom Hauptskript vor diesem Modul aufgerufen).
  log "  Image-Build: bereits durch install_addon_frontend_build erfolgt (vorgelagerter Schritt)"
  log_ok "AddOn 30 Frontend: Secrets + ConfigMaps + Manifeste + Ingress angewendet"
  return 0
}

# ── Uninstall-TLS-Handhabung (Schritt 2c-3) ─────────────────────────────────────
# addon_tls_provenance <issuer_annotation> <openssl_issuer>
# Klassifiziert die Herkunft eines <host>-tls-Secrets: acme | selfsigned | unknown.
addon_tls_provenance() {
  local annotation="$1" openssl_issuer="$2"
  case "${annotation}" in
    letsencrypt-staging|letsencrypt-prod) printf 'acme'; return 0 ;;
    selfsigned-issuer|civitas-bootstrap-selfsigned) printf 'selfsigned'; return 0 ;;
  esac
  # Keine/mehrdeutige Annotation -> Aussteller des Zertifikats (openssl).
  case "${openssl_issuer}" in
    *"Let's Encrypt"*) printf 'acme'; return 0 ;;
  esac
  printf 'unknown'
  return 0
}

# addon_uninstall_keep_tls <mode> <provenance> — 0 = Secret behalten, 1 = löschen.
addon_uninstall_keep_tls() {
  local mode="$1" provenance="$2"
  case "${mode}" in
    true)  return 0 ;;
    false) return 1 ;;
    auto)  [[ "${provenance}" == "acme" ]] ;;
  esac
}

# addon_cert_names_for_secret <ns> <secret> — Certificate-Namen je spec.secretName.
addon_cert_names_for_secret() {
  local ns="$1" secret="$2"
  kubectl -n "${ns}" get certificate -o json 2>/dev/null \
    | jq -r --arg s "${secret}" '.items[]? | select(.spec.secretName == $s) | .metadata.name' 2>/dev/null
}

# addon_secret_tls_provenance <ns> <secret> — liest die Herkunft eines TLS-Secrets.
# Bevorzugt die cert-manager-Issuer-Annotation, sonst den Aussteller via openssl.
addon_secret_tls_provenance() {
  local ns="$1" secret="$2" annotation openssl_issuer
  annotation="$(kubectl -n "${ns}" get secret "${secret}" \
    -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer-name}' 2>/dev/null || true)"
  [[ -z "${annotation}" ]] && annotation="$(kubectl -n "${ns}" get secret "${secret}" \
    -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer-name}' 2>/dev/null || true)"
  if [[ "${annotation}" != letsencrypt-* && "${annotation}" != selfsigned-issuer && "${annotation}" != civitas-bootstrap-selfsigned ]]; then
    openssl_issuer="$(kubectl -n "${ns}" get secret "${secret}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null || true)"
  fi
  addon_tls_provenance "${annotation}" "${openssl_issuer:-}"
}

# uninstall_addon_frontend — regulärer Uninstall (Turn 65): entfernt alle vom AddOn
# angelegten Frontend-Ressourcen rückstandsfrei, spiegelbildlich zu install_addon_frontend.
# Löst den früheren DANGER-Sonderfall ab (der Install-Platzhalter ist seit Turn 45-62
# produktiv und kann die Ressourcen wiederherstellen).
#
# Gelöscht wird je Stage: Deployment, Service, ConfigMap, Secret, Ingress, Certificate
# (ausdrücklich, V2) sowie Alt-PVCs aus der PVC-basierten Vorversion. Das TLS-Secret
# <host>-tls bleibt bei ACME-Issuern erhalten (E3, V1, P2D2_UNINSTALL_KEEP_TLS).
# Basis: p2d2-base-config + p2d2-base-secret. Webhook-Controller (Deployment/Service/
# SA/Role/RoleBinding) + Builder-Jobs. Shared-Infra-Secrets p2d2-builder-git-auth +
# p2d2-webhook-secrets (Turn 65: NICHT erhalten — ohne AddOn reines Legacy).
uninstall_addon_frontend() {
  log "=== Uninstall AddOn 30: Frontend (5 Stages, Ingress, Shared-Infra) ==="
  addon_frontend_guard || return 1

  local ns="${ADDON_NS}"
  # V6: Enum-Prüfung läuft hier, weil addon_validate_config beim Uninstall nicht läuft.
  local keep_mode
  keep_mode="$(addon_validate_uninstall_keep_tls)" || return 1

  local stage svc host cm secret tls_secret provenance cert_name cert_pem issuer enddate
  for stage in main dev de1 de2 fv; do
    case "${stage}" in
      main) svc="p2d2-main";    cm="p2d2-main-config";    secret="p2d2-main-secret";    host="www.${ADDON_DOMAIN}" ;;
      dev)  svc="p2d2-dev";     cm="p2d2-dev-config";     secret="p2d2-dev-secret";     host="dev.${ADDON_DOMAIN}" ;;
      de1)  svc="p2d2-f-de1";   cm="p2d2-f-de1-config";   secret="p2d2-f-de1-secret";   host="f-de1.${ADDON_DOMAIN}" ;;
      de2)  svc="p2d2-f-de2";   cm="p2d2-f-de2-config";   secret="p2d2-f-de2-secret";   host="f-de2.${ADDON_DOMAIN}" ;;
      fv)   svc="p2d2-f-fv";    cm="p2d2-f-fv-config";    secret="p2d2-f-fv-secret";    host="f-fv.${ADDON_DOMAIN}" ;;
    esac
    tls_secret="${host}-tls"

    log "  Stage ${stage}: Deployment/Service/ConfigMap/Secret/Ingress/Certificate/PVC entfernen"
    kubectl -n "${ns}" delete deployment "${svc}" --ignore-not-found || true
    kubectl -n "${ns}" delete service    "${svc}" --ignore-not-found || true
    kubectl -n "${ns}" delete configmap  "${cm}" --ignore-not-found || true
    kubectl -n "${ns}" delete secret     "${secret}" --ignore-not-found || true
    kubectl -n "${ns}" delete ingress    "${svc}" --ignore-not-found || true
    # V2: Certificate ausdrücklich löschen (nicht auf Garbage Collection verlassen).
    while IFS= read -r cert_name; do
      [[ -n "${cert_name}" ]] && kubectl -n "${ns}" delete certificate "${cert_name}" --ignore-not-found || true
    done < <(addon_cert_names_for_secret "${ns}" "${tls_secret}")
    # Alt-PVC aus der PVC-basierten Vorversion (image-basiert heute ohne PVC).
    kubectl -n "${ns}" delete pvc        "${svc}-code" --ignore-not-found || true

    # V1/E3: <host>-tls nur behalten, wenn der Modus es verlangt.
    provenance="$(addon_secret_tls_provenance "${ns}" "${tls_secret}")"
    if addon_uninstall_keep_tls "${keep_mode}" "${provenance}"; then
      cert_pem="$(kubectl -n "${ns}" get secret "${tls_secret}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null || true)"
      issuer="$(printf '%s' "${cert_pem}" | openssl x509 -noout -issuer 2>/dev/null || true)"
      enddate="$(printf '%s' "${cert_pem}" | openssl x509 -noout -enddate 2>/dev/null || true)"
      log_ok "TLS-Secret ${tls_secret} behalten (Aussteller: ${issuer:-unbekannt}; ${enddate:-unbekannt})"
      log "  Löschen bei Bedarf: P2D2_UNINSTALL_KEEP_TLS=false oder 'kubectl -n ${ns} delete secret ${tls_secret}'"
    else
      kubectl -n "${ns}" delete secret "${tls_secret}" --ignore-not-found || true
    fi
  done

  # Basis-ConfigMap/-Secret
  kubectl -n "${ns}" delete configmap p2d2-base-config --ignore-not-found || true
  kubectl -n "${ns}" delete secret p2d2-base-secret --ignore-not-found || true

  # Webhook-Controller (Deployment/Service/ServiceAccount/Role/RoleBinding)
  kubectl -n "${ns}" delete deployment p2d2-webhook-controller --ignore-not-found || true
  kubectl -n "${ns}" delete service p2d2-webhook-controller --ignore-not-found || true
  kubectl -n "${ns}" delete serviceaccount p2d2-webhook-controller --ignore-not-found || true
  kubectl -n "${ns}" delete role p2d2-webhook-controller-role --ignore-not-found || true
  kubectl -n "${ns}" delete rolebinding p2d2-webhook-controller-binding --ignore-not-found || true

  # Builder-Jobs (Referenz-Job p2d2-builder-* + dynamische p2d2-<stage>-builder-* des
  # Webhook-Controllers). Nur p2d2-Builder-Jobs anfassen, nie fremde Jobs.
  local job
  while read -r job; do
    [[ -n "${job}" ]] && kubectl -n "${ns}" delete job "${job}" --ignore-not-found || true
  done < <(kubectl -n "${ns}" get jobs -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep -E '^p2d2-.*builder' || true)

  # Shared-Infra-Secrets (Turn 65: löschen, nicht erhalten)
  kubectl -n "${ns}" delete secret p2d2-builder-git-auth --ignore-not-found || true
  kubectl -n "${ns}" delete secret p2d2-webhook-secrets --ignore-not-found || true

  log_ok "Uninstall AddOn 30 Frontend abgeschlossen"
}

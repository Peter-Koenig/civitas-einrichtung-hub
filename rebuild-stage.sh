#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# rebuild-stage.sh — baut EINE p2d2-Frontend-Stage bei neuem Branch-Stand neu
# und rollt sie aus (Host → VM, analog p2d2-civitas-addon-v1s.sh).
#
# Aufruf (Host):
#   ./rebuild-stage.sh --stage <main|dev|de1|de2|fv> [--check] [--force] [--keep-docker]
#   (develop ist Alias für dev)
#
# Ohne Option: baut + rollt nur, wenn der Remote-Branch einen neueren Commit hat
# als das laufende Image; sonst "aktuell, nichts zu tun", Exit 0.
# --check:       nur prüfen und berichten (Exit 0 = aktuell, 10 = Rebuild nötig, 1 = Fehler).
# --force:       auch bei gleichem Tag bauen und ausrollen.
# --keep-docker: Docker nach dem Build nicht deinstallieren.
#
# Die VM-seitige .env.p2d2-addon wird NUR gelesen (kein Merge, kein Überschreiben).
set -euo pipefail

# ── Log-Helfer (Minimalkopie, identisch zum Hauptskript) ──────────────────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults (spiegeln das Hauptskript) ───────────────────────────────────────
export ADDON_CONTEXT="${ADDON_CONTEXT:-host}"
export VM_IP_STATIC="${VM_IP_STATIC:-192.168.12.139}"
export VM_ID="${VM_ID:-2010}"
export INSTALL_KEY_DIR="${INSTALL_KEY_DIR:-${HOME}/.local/share/civitas-install/${VM_ID}}"
export ADDON_SSH_KEY_FILE="${ADDON_SSH_KEY_FILE:-}"
export ADDON_SSH_KNOWN_HOSTS="${ADDON_SSH_KNOWN_HOSTS:-${INSTALL_KEY_DIR}/known_hosts}"
export VM_REMOTE_INSTALL_DIR="${VM_REMOTE_INSTALL_DIR:-/root/p2d2-addon}"
export ADDON_ENV_FILE="${ADDON_ENV_FILE:-${SCRIPT_DIR}/../.env.p2d2-addon}"

# ── Argumente ─────────────────────────────────────────────────────────────────
STAGE=""
CHECK=0
FORCE=0
KEEP_DOCKER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        log_error "--stage benötigt einen Wert (main|dev|de1|de2|fv)"
        exit 1
      fi
      STAGE="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    --keep-docker) KEEP_DOCKER=1; shift ;;
    *) log_error "Unbekanntes Argument: $1"; exit 1 ;;
  esac
done
# Alias develop -> dev.
[[ "${STAGE}" == "develop" ]] && STAGE="dev"

# ── Gemeinsame, nicht-fachliche Module laden ──────────────────────────────────
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/modules_addon_V1s/addon_05_ssh.sh"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "${SCRIPT_DIR}/modules_addon_V1s/addon_30_frontend.sh"

# Stage früh validieren (addon_stage_source liefert die Produktwerte und
# meldet unbekannte Stages selbst).
if ! stage_values="$(addon_stage_source "${STAGE}")"; then
  exit 1
fi

# ── Host-Kontext: Selbstkopie + vollautonomer Lauf in der VM ─────────────────
if [[ "${ADDON_CONTEXT}" == "host" ]]; then
  log "=== p2d2 rebuild-stage (Host → VM) — Stage: ${STAGE} ==="

  addon_ssh_select_key

  addon_vm_exec "mkdir -p ${VM_REMOTE_INSTALL_DIR}" \
    || { log_error "VM ${VM_IP_STATIC} nicht per SSH erreichbar"; exit 1; }

  addon_vm_copy "${VM_REMOTE_INSTALL_DIR}/" -r \
    "${SCRIPT_DIR}/rebuild-stage.sh" \
    "${SCRIPT_DIR}/modules_addon_V1s" \
    "${SCRIPT_DIR}/overlay_addon_V1s" \
    || { log_error "scp fehlgeschlagen — VM ${VM_IP_STATIC} nicht erreichbar?"; exit 1; }

  addon_vm_exec "chmod +x ${VM_REMOTE_INSTALL_DIR}/rebuild-stage.sh ${VM_REMOTE_INSTALL_DIR}/overlay_addon_V1s/k8s/frontend/build-stage.sh" \
    || { log_error "chmod +x der Skripte fehlgeschlagen"; exit 1; }

  if ! addon_vm_exec "test -f ${VM_REMOTE_INSTALL_DIR}/../.env.p2d2-addon"; then
    log_error ".env.p2d2-addon fehlt in der VM (${VM_REMOTE_INSTALL_DIR}/../.env.p2d2-addon) — bitte vorher anlegen"
    exit 1
  fi

  remote_cmd="ADDON_CONTEXT=vm ./rebuild-stage.sh --stage ${STAGE}"
  [[ "${CHECK}" -eq 1 ]] && remote_cmd="${remote_cmd} --check"
  [[ "${FORCE}" -eq 1 ]] && remote_cmd="${remote_cmd} --force"
  [[ "${KEEP_DOCKER}" -eq 1 ]] && remote_cmd="${remote_cmd} --keep-docker"

  log "Starte in der VM: cd ${VM_REMOTE_INSTALL_DIR} && ${remote_cmd}"
  addon_vm_exec "cd ${VM_REMOTE_INSTALL_DIR} && ${remote_cmd}"
  exit $?
fi

# ── VM-Kontext: eigentliche Arbeit ────────────────────────────────────────────
ENV_FILE="${VM_REMOTE_INSTALL_DIR}/../.env.p2d2-addon"
[[ -f "${ENV_FILE}" ]] || { log_error ".env.p2d2-addon nicht gefunden: ${ENV_FILE}"; exit 1; }
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

export ADDON_NS="${ADDON_NS:-cc-prd-geodata-stack}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
addon_derive_domain

# Stage-Quelle laden (IMAGE, KEY, GIT_HOST, GIT_REPO_PATH, GIT_BRANCH, BUILD_SCRIPT).
eval "${stage_values}"

# _need <varname> — indirekt lesen; leer/ungesetzt -> Fehler + exit 1 (kein Default).
_need() {
  local name="$1" val
  val="${!name:-}"
  [[ -n "${val}" ]] || { log_error "${name} ist leer — bitte in .env.p2d2-addon setzen"; exit 1; }
  printf '%s' "${val}"
}

# Lock: nur EIN Rebuild pro Stage gleichzeitig. Pfad über REBUILD_LOCK_DIR
# überschreibbar (Tests nutzen ein beschreibbares Verzeichnis).
lock_dir="${REBUILD_LOCK_DIR:-/run/lock}"
lock="${lock_dir}/p2d2-rebuild-${STAGE}.lock"
exec 9>"${lock}"
if ! flock -n 9; then
  log_error "Rebuild für Stage ${STAGE} läuft bereits (Lock ${lock})"
  exit 1
fi

# Git-Token je Provider (nie in der Prozessliste — GIT_ASKPASS).
case "${GIT_HOST}" in
  *github*) GIT_AUTH_USER="x-access-token"; GIT_TOKEN="${P2D2_GITHUB_TOKEN:-}" ;;
  *)        GIT_AUTH_USER="oauth2";          GIT_TOKEN="${P2D2_GITLAB_TOKEN:-}" ;;
esac
[[ -n "${GIT_TOKEN}" ]] || { log_error "Git-Token fehlt (${GIT_HOST} erwartet P2D2_GITHUB_TOKEN bzw. P2D2_GITLAB_TOKEN)"; exit 1; }
export GIT_TOKEN GIT_AUTH_USER

askpass_file="$(mktemp)"; chmod 700 "${askpass_file}"
tag_file=""
# Aufräumen in allen Pfaden (Build-Fehler, Rollout-Fehler, --check, --keep-docker).
cleanup_rebuild() {
  [[ -n "${askpass_file}" ]] && rm -f "${askpass_file}"
  [[ -n "${tag_file}" ]] && rm -f "${tag_file}"
  if [[ "${KEEP_DOCKER}" -ne 1 ]]; then
    addon_docker_release
  fi
}
trap cleanup_rebuild EXIT
cat > "${askpass_file}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' "$GIT_AUTH_USER" ;;
  *) printf '%s\n' "$GIT_TOKEN" ;;
esac
EOF

ls_remote_rc=0
ls_remote_out="$(GIT_ASKPASS="${askpass_file}" GIT_TERMINAL_PROMPT=0 \
  git ls-remote "https://${GIT_HOST}/${GIT_REPO_PATH}" "refs/heads/${GIT_BRANCH}" 2>/dev/null)" || ls_remote_rc=$?
ls_remote_lines=0
if [[ -n "${ls_remote_out}" ]]; then
  ls_remote_lines="$(printf '%s\n' "${ls_remote_out}" | grep -c '^' || true)"
fi
if [[ "${ls_remote_rc}" -ne 0 || "${ls_remote_lines}" != "1" ]]; then
  log_error "git ls-remote lieferte ${ls_remote_lines} Zeile(n) (Exit ${ls_remote_rc}) für ${GIT_BRANCH} (erwartet genau 1)"
  exit 1
fi
remote_sha="${ls_remote_out%%$'\t'*}"

overlay_dir="$(cd "${SCRIPT_DIR}/overlay_addon_V1s/k8s" && pwd)"
script_sha="$(addon_frontend_script_sha "${overlay_dir}/frontend")"

site_url="$(_need "P2D2_${KEY}_PUBLIC_SITE_URL")"
wfst_workspace="$(_need "P2D2_${KEY}_WFST_WORKSPACE")"
wfst_endpoint="$(_need "P2D2_BASE_PUBLIC_WFST_ENDPOINT")"
mapserver_url="$(_need "P2D2_BASE_PUBLIC_MAPSERVER_URL")"
icon="$(_need "P2D2_BASE_DEFAULT_CATEGORY_ICON")"

expected_tag="$(addon_compute_image_tag "${STAGE}" "${GIT_HOST}" "${GIT_REPO_PATH}" "${GIT_BRANCH}" \
  "${remote_sha}" "${script_sha}" "${BUILD_SCRIPT}" \
  "${site_url}" "${wfst_endpoint}" "${wfst_workspace}" "${mapserver_url}" "${icon}")"

svc="$(addon_frontend_svc "${STAGE}")"
kubectl_rc=0
running_image="$(kubectl -n "${ADDON_NS}" get deploy "${svc}" --ignore-not-found \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="astro")].image}')" || kubectl_rc=$?
if [[ "${kubectl_rc}" -ne 0 ]]; then
  log_error "kubectl nicht erreichbar/Fehler (Exit ${kubectl_rc})"
  exit 1
fi
if [[ -z "${running_image}" ]]; then
  log_warn "Deployment ${svc} existiert nicht — der Wrapper legt weder Ingress noch Secrets an (dazu ./p2d2-civitas-addon-v1s.sh verwenden)"
  running_tag=""
else
  running_tag="${running_image##*:}"
fi

log "Stage:      ${STAGE}"
log "Branch:     ${GIT_BRANCH}"
log "remote_sha: ${remote_sha:0:12}"
log "running:    ${running_tag:-<kein Deployment>}"
log "expected:   ${expected_tag}"

if [[ "${running_tag}" == "${expected_tag}" && "${FORCE}" -ne 1 ]]; then
  log_ok "aktuell, nichts zu tun"
  exit 0
fi

if [[ "${CHECK}" -eq 1 ]]; then
  log "Rebuild nötig"
  exit 10
fi

# Build + Rollout.
addon_docker_ensure || { log_error "Docker nicht verfügbar"; exit 1; }

tag_file="$(mktemp)"; chmod 600 "${tag_file}"
FRONTEND_TAG_FILE="${tag_file}" "${overlay_dir}/frontend/build-stage.sh" "${STAGE}" \
  || { log_error "Image-Build ${STAGE} fehlgeschlagen"; exit 1; }
built_tag="$(cat "${tag_file}" 2>/dev/null || true)"
[[ -n "${built_tag}" ]] || { log_error "Image-Build ${STAGE}: kein Tag erzeugt"; exit 1; }

if [[ "${built_tag}" != "${expected_tag}" ]]; then
  log_warn "built_tag ${built_tag} weicht von expected_tag ${expected_tag} ab (Branch hat sich bewegt) — verwende ${built_tag}"
fi

install_addon_frontend_stage "${STAGE}" "${built_tag}" \
  || { log_error "Rollout ${STAGE} fehlgeschlagen"; exit 1; }

if ! kubectl -n "${ADDON_NS}" rollout status "deployment/${svc}" --timeout=180s; then
  log_error "Rollout ${svc} nicht erfolgreich — führe Rollback aus"
  kubectl -n "${ADDON_NS}" rollout undo "deployment/${svc}" || true
  exit 1
fi

# Rauchtest (nur informativ): Status + Host/Pfad der Location, nie Query-Parameter.
host="$(addon_frontend_host "${STAGE}")"
smoke="$(curl --max-time 10 -sS -o /dev/null -D - "https://${host}/api/auth/login" 2>/dev/null || true)"
status="$(printf '%s\n' "${smoke}" | sed -n '1s/^[^ ]* \([0-9][0-9]*\).*/\1/p')"
location="$(printf '%s\n' "${smoke}" | awk -F': ' 'tolower($1)=="location"{sub(/\r$/,""); print $2}' | head -1)"
location_clean="${location%%\?*}"
log "Rauchtest https://${host}/api/auth/login: HTTP ${status:-<Fehler>}, Location ${location_clean:-<keine>}"

log_ok "Stage ${STAGE} neu gebaut + ausgerollt (${built_tag})"

#!/usr/bin/env bash
# Suite 36: rebuild-stage.sh — Argument-Validierung, Tag-Parität,
# aktuell/Rebuild-Entscheidung (--check 0/10), keine Secrets in der Ausgabe.
# Nur Stubs (kubectl, git), kein Cluster/Netz, keine echten Credentials.

begin_suite "rebuild_stage_wrapper"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# ── Stubs ─────────────────────────────────────────────────────────────────────
STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

# kubectl-Stub: liefert das laufende Image für deploy/<svc>.
cat > "$STUBS/kubectl" <<'KUB'
#!/usr/bin/env bash
case "$*" in
  *"get deploy"*"-o jsonpath"*)
    printf '%s' "${KUBECTL_RUNNING_IMAGE:-}" ;;
  *) exit 0 ;;
esac
KUB
chmod +x "$STUBS/kubectl"

# git-Stub: ls-remote -> feste Commit-Zeile (erste Spalte = SHA).
cat > "$STUBS/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
  *"ls-remote"*) printf '%s\trefs/heads/branch\n' "${GIT_LS_REMOTE_SHA:-0000000000000000000000000000000000000000}" ;;
  *) exit 0 ;;
esac
GIT
chmod +x "$STUBS/git"

# ── VM-Verzeichnis + .env.p2d2-addon (Dummy-Werte, keine echten Secrets) ─────
VM_DIR="$T/vm"
mkdir -p "$VM_DIR/p2d2-addon"
cat > "$VM_DIR/.env.p2d2-addon" <<'ENV'
DOMAIN_NAME=example.org
ADDON_NS=cc-prd-geodata-stack
P2D2_DE1_PUBLIC_SITE_URL=https://f-de1.udp.example.org
P2D2_DE1_WFST_WORKSPACE=de1
P2D2_DEVELOP_PUBLIC_SITE_URL=https://dev.udp.example.org
P2D2_DEVELOP_WFST_WORKSPACE=dev
P2D2_BASE_PUBLIC_WFST_ENDPOINT=https://geoportal.udp.example.org/geoserver/ows
P2D2_BASE_PUBLIC_MAPSERVER_URL=https://geoportal.udp.example.org/mapserver
P2D2_BASE_DEFAULT_CATEGORY_ICON=Fahnenmasten.svg
P2D2_GITHUB_TOKEN=test-token-secret
P2D2_GITLAB_TOKEN=test-token-secret
ENV

export VM_REMOTE_INSTALL_DIR="$VM_DIR/p2d2-addon"
export REBUILD_LOCK_DIR="$T/lock"; mkdir -p "$REBUILD_LOCK_DIR"
export ADDON_CONTEXT="vm"
export GIT_LS_REMOTE_SHA="commit-abc"

# ── Argument-Validierung ──────────────────────────────────────────────────────
"$REPO/rebuild-stage.sh" --stage bogus >/dev/null 2>&1
check "unbekannte Stage -> rc=1" "1" "$?"
"$REPO/rebuild-stage.sh" --stage de1 --bogus >/dev/null 2>&1
check "unbekannte Option -> rc=1" "1" "$?"

# ── Paritätstest: expected_tag des Wrappers == addon_compute_image_tag ────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"

eval "$(addon_stage_source de1)"
overlay="$REPO/overlay_addon_V1s/k8s"
script_sha="$(addon_frontend_script_sha "$overlay/frontend")"
expected="$(addon_compute_image_tag de1 "$GIT_HOST" "$GIT_REPO_PATH" "$GIT_BRANCH" \
  "$GIT_LS_REMOTE_SHA" "$script_sha" "$BUILD_SCRIPT" \
  "https://f-de1.udp.example.org" "https://geoportal.udp.example.org/geoserver/ows" \
  "de1" "https://geoportal.udp.example.org/mapserver" "Fahnenmasten.svg")"

out="$("$REPO/rebuild-stage.sh" --stage de1 --check 2>/dev/null)"
check "Parität: expected_tag in Ausgabe" "yes" "$(grep -qF "expected:   ${expected}" <<< "$out" && echo yes || echo no)"

# ── aktuell vs. Rebuild nötig (--check Exitcodes 0/10) ────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "--check aktuell -> rc=0" "0" "$?"

export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:cfg-old"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "--check rebuild nötig -> rc=10" "10" "$?"

# ── develop -> dev Alias ──────────────────────────────────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"
alias_out="$("$REPO/rebuild-stage.sh" --stage develop --check 2>/dev/null)"
check "develop -> dev (Stage: dev)" "yes" "$(grep -qF 'Stage:      dev' <<< "$alias_out" && echo yes || echo no)"

# ── Keine Secrets (Token) in der Ausgabe ──────────────────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:cfg-old"
secret_out="$("$REPO/rebuild-stage.sh" --stage de1 --check 2>&1)"
check "kein Git-Token in Ausgabe" "0" "$(grep -cF 'test-token-secret' <<< "$secret_out" || true)"

rm -rf "$T"

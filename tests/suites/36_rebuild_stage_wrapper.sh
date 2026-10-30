#!/usr/bin/env bash
# Suite 36: rebuild-stage.sh — Argument-Validierung, Tag-Parität gegen die ECHTE
# build-stage.sh, aktuell/Rebuild-Entscheidung (--check 0/10), kubectl-/ls-remote-
# Fehlerfälle, Host-Pfad (ssh-Exit durchreichen) und keine Secrets in der Ausgabe.
# Nur Stubs (git, kubectl, docker, k3s, ssh, scp, ssh-keygen, timeout), kein
# Cluster/Netz, keine echten Credentials.

begin_suite "rebuild_stage_wrapper"

# Gesamte Suite in einer Subshell: exportierte Variablen wirken nicht auf
# spätere Suiten (37+). run.sh sourced die Suite zwar bereits in einer eigenen
# Subshell, hier wird die Hygiene zusätzlich explizit gemacht.
(
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Als Prozess aufgerufen -> ausführbares Bit sicherstellen.
chmod +x "$REPO/rebuild-stage.sh" "$REPO/overlay_addon_V1s/k8s/frontend/build-stage.sh"

# ── Stubs ─────────────────────────────────────────────────────────────────────
STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

# git-Stub: clone legt das Zielverzeichnis an (letztes Argument), rev-parse liefert
# den Commit-SHA, ls-remote liefert 0..N Zeilen (GIT_LS_REMOTE_LINES steuert).
cat > "$STUBS/git" <<'GIT'
#!/usr/bin/env bash
case "$1" in
  clone)
    last=""
    for a in "$@"; do last="$a"; done
    mkdir -p "$last"
    ;;
  rev-parse)
    printf '%s\n' "${GIT_LS_REMOTE_SHA:-0000000000000000000000000000000000000000}"
    ;;
  ls-remote)
    n="${GIT_LS_REMOTE_LINES:-1}"
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '%s\trefs/heads/branch%d\n' "${GIT_LS_REMOTE_SHA:-0000000000000000000000000000000000000000}" "$i"
      i=$((i+1))
    done
    ;;
esac
exit 0
GIT
chmod +x "$STUBS/git"

# docker-Stub: build/save -> Erfolg; save gibt nichts aus (k3s liest leer).
cat > "$STUBS/docker" <<'DOCKER'
#!/usr/bin/env bash
exit 0
DOCKER
chmod +x "$STUBS/docker"

# k3s-Stub: `docker save | k3s ctr images import -` liest stdin, Erfolg.
cat > "$STUBS/k3s" <<'K3S'
#!/usr/bin/env bash
cat >/dev/null
exit 0
K3S
chmod +x "$STUBS/k3s"

# kubectl-Stub: get deploy -o jsonpath liefert KUBECTL_RUNNING_IMAGE; KUBECTL_RC
# != 0 simuliert einen kubectl-Fehler (Exit != 0, Meldung auf stderr).
cat > "$STUBS/kubectl" <<'KUB'
#!/usr/bin/env bash
case "$*" in
  *"get deploy"*"-o jsonpath"*)
    if [ "${KUBECTL_RC:-0}" -ne 0 ]; then
      echo "kubectl: verbindung fehlgeschlagen" >&2
      exit "${KUBECTL_RC}"
    fi
    printf '%s' "${KUBECTL_RUNNING_IMAGE:-}"
    ;;
  *) exit 0 ;;
esac
KUB
chmod +x "$STUBS/kubectl"

# ssh-Stub (nur Host-Pfad-Test): Remote-Aufruf (enthält ADDON_CONTEXT=vm) -> Exit
# 10, sonst Erfolg (Verbindungstest in addon_ssh_select_key läuft damit durch).
cat > "$STUBS/ssh" <<'SSH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *ADDON_CONTEXT=vm*) exit 10 ;;
  esac
done
exit 0
SSH
chmod +x "$STUBS/ssh"

# timeout-Stub (nur Host-Pfad-Test): Reachability-Check (addon_ssh_vm_reachable)
# nicht wirklich ausführen, sondern Erfolg liefern.
cat > "$STUBS/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
exit 0
TIMEOUT
chmod +x "$STUBS/timeout"

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
export KUBECTL_RUNNING_IMAGE=""
export KUBECTL_RC="0"
export GIT_LS_REMOTE_LINES="1"

# ── Argument-Validierung ──────────────────────────────────────────────────────
"$REPO/rebuild-stage.sh" --stage bogus >/dev/null 2>&1
check "unbekannte Stage -> rc=1" "1" "$?"
"$REPO/rebuild-stage.sh" --stage de1 --bogus >/dev/null 2>&1
check "unbekannte Option -> rc=1" "1" "$?"
"$REPO/rebuild-stage.sh" --stage >/dev/null 2>&1
check "--stage ohne Wert -> rc=1" "1" "$?"
"$REPO/rebuild-stage.sh" --stage "" >/dev/null 2>&1
check "--stage leerer Wert -> rc=1" "1" "$?"

# ── Erwartetes Tag (de1) direkt aus der reinen Funktion ───────────────────────
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

# ── Paritätstest gegen die ECHTE build-stage.sh (Auftrag 2) ──────────────────
# build-stage.sh läuft mit denselben Env-Werten (P2D2_*) wie der Wrapper und
# schreibt den von ihr tatsächlich berechneten Tag nach FRONTEND_TAG_FILE.
export P2D2_DE1_PUBLIC_SITE_URL="https://f-de1.udp.example.org"
export P2D2_DE1_WFST_WORKSPACE="de1"
export P2D2_BASE_PUBLIC_WFST_ENDPOINT="https://geoportal.udp.example.org/geoserver/ows"
export P2D2_BASE_PUBLIC_MAPSERVER_URL="https://geoportal.udp.example.org/mapserver"
export P2D2_BASE_DEFAULT_CATEGORY_ICON="Fahnenmasten.svg"
export P2D2_GITHUB_TOKEN="test-token-secret"
export P2D2_GITLAB_TOKEN="test-token-secret"
export FRONTEND_TAG_FILE="$T/tag"

"$REPO/overlay_addon_V1s/k8s/frontend/build-stage.sh" de1 >/dev/null 2>&1
build_rc=$?
built_tag="$(cat "$FRONTEND_TAG_FILE" 2>/dev/null || true)"
check "Paritätstest: build-stage.sh läuft (rc=0)" "0" "$build_rc"
check "Paritätstest: built_tag == reine Funktion" "$expected" "${built_tag:-}"

unset P2D2_DE1_PUBLIC_SITE_URL P2D2_DE1_WFST_WORKSPACE P2D2_BASE_PUBLIC_WFST_ENDPOINT \
  P2D2_BASE_PUBLIC_MAPSERVER_URL P2D2_BASE_DEFAULT_CATEGORY_ICON P2D2_GITHUB_TOKEN P2D2_GITLAB_TOKEN \
  FRONTEND_TAG_FILE

# Wrapper im VM-Kontext: erwartetes Tag in der Ausgabe.
out="$("$REPO/rebuild-stage.sh" --stage de1 --check 2>/dev/null)"
check "Parität: expected_tag in Ausgabe" "yes" "$(grep -qF "expected:   ${expected}" <<< "$out" && echo yes || echo no)"
wrapper_expected="$(printf '%s\n' "$out" | sed -n 's/.*expected:   //p' | head -1)"
check "Paritätstest: built_tag == Wrapper-expected" "${wrapper_expected}" "${built_tag:-}"

# ── aktuell vs. Rebuild nötig (--check Exitcodes 0/10) ────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "--check aktuell -> rc=0" "0" "$?"

export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:cfg-old"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "--check rebuild nötig -> rc=10" "10" "$?"

# --force --check bei gleichem Tag -> Exit 10 (Force ignoriert die Gleichheit).
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"
"$REPO/rebuild-stage.sh" --stage de1 --check --force >/dev/null 2>&1
check "--force --check gleicher Tag -> rc=10" "10" "$?"

# ── kubectl-Fehlerfälle (Auftrag 1) ───────────────────────────────────────────
export KUBECTL_RC="1"; export KUBECTL_RUNNING_IMAGE=""
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "kubectl Exit 1 -> Wrapper Exit 1 (nicht 10)" "1" "$?"

# kubectl Exit 0 + leere Ausgabe -> --check Exit 10 + Warnhinweis (Deployment fehlt).
export KUBECTL_RC="0"; export KUBECTL_RUNNING_IMAGE=""
warn_out="$("$REPO/rebuild-stage.sh" --stage de1 --check 2>&1)"
check "kubectl leer -> --check rc=10" "10" "$?"
check "kubectl leer -> Warnhinweis" "yes" "$(grep -qF 'existiert nicht' <<< "$warn_out" && echo yes || echo no)"
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"

# ── ls-remote mit 0 und 2 Zeilen -> Exit 1 ────────────────────────────────────
export GIT_LS_REMOTE_LINES="0"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "ls-remote 0 Zeilen -> rc=1" "1" "$?"
export GIT_LS_REMOTE_LINES="2"
"$REPO/rebuild-stage.sh" --stage de1 --check >/dev/null 2>&1
check "ls-remote 2 Zeilen -> rc=1" "1" "$?"
export GIT_LS_REMOTE_LINES="1"

# ── develop -> dev Alias ──────────────────────────────────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:${expected}"
alias_out="$("$REPO/rebuild-stage.sh" --stage develop --check 2>/dev/null)"
check "develop -> dev (Stage: dev)" "yes" "$(grep -qF 'Stage:      dev' <<< "$alias_out" && echo yes || echo no)"

# ── Keine Secrets (Token) in der Ausgabe ──────────────────────────────────────
export KUBECTL_RUNNING_IMAGE="p2d2-frontend-de1:cfg-old"
secret_out="$("$REPO/rebuild-stage.sh" --stage de1 --check 2>&1)"
check "kein Git-Token in Ausgabe" "0" "$(grep -cF 'test-token-secret' <<< "$secret_out" || true)"

# ── Host-Pfad: ssh-Stub Exit 10 wird durchgereicht, VM-.env wird nicht kopiert ─
export ADDON_CONTEXT="host"
export VM_IP_STATIC="192.0.2.10"
export INSTALL_KEY_DIR="$T/keys"; mkdir -p "$INSTALL_KEY_DIR"
printf 'PRIVATE KEY\n' > "$INSTALL_KEY_DIR/id_ed25519"; chmod 600 "$INSTALL_KEY_DIR/id_ed25519"
export ADDON_SSH_KNOWN_HOSTS="$T/known_hosts"
export VM_REMOTE_INSTALL_DIR="/root/p2d2-addon"
export ADDON_ENV_FILE="$T/no-such-env"
export SCP_CALL_LOG="$T/scp.log"

"$REPO/rebuild-stage.sh" --stage de1 >/dev/null 2>&1
check "Host-Pfad: ssh Exit 10 durchgereicht" "10" "$?"
check "Host-Pfad: VM-.env wird nicht kopiert" "0" "$(grep -cF '.env' "$SCP_CALL_LOG" 2>/dev/null || true)"

rm -rf "$T"
)

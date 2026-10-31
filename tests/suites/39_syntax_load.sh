#!/usr/bin/env bash
# Suite 39: Syntax- und Ladetest für alle V1s-Installer-Skripte.
# Fängt abgeschnittene/fehlerhafte Moduldateien ab, die source zum Scheitern bringen.

begin_suite "syntax_load"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)

# 1) Syntaxcheck aller Installer-/Modulskripte.
files=( "$REPO"/install_civitas_core_V1s.sh "$REPO"/modules_V1s/*.sh "$REPO"/modules_addon_V1s/*.sh )
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  out="$(bash -n "$f" 2>&1)"; rc=$?
  check "bash -n $(basename "$f")" "0" "$rc"
  if [[ "$rc" -ne 0 ]]; then printf '%s\n' "$out" | head -3; fi
done

# 2) Ladetest: jedes Modul in Subshell mit Minimal-Env sourcebar.
for m in 00_provision_vm 01_config 02_lib 03_preflight 04_k3s 05_addons \
         06a_network_certs 06b_idm_provisioning 06c_image_build 06_civitas \
         07_verify 07_login_summary; do
  (
    set -euo pipefail
    export DOMAIN_NAME=example.org SMTP_HOST=h SMTP_USER=u SMTP_PASS=p \
           ADMIN_PASS='Aa1!aaaaaaaa' WG_ENABLE=false
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/01_config.sh"
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/02_lib.sh"
    # shellcheck disable=SC1090,SC1091
    source "$REPO/modules_V1s/$m.sh"
  ) >/dev/null 2>&1; rc=$?
  check "source $m rc=0" "0" "$rc"
done

# 3) Kernfunktionen definiert (fängt abgeschnittene Dateien ab, die trotzdem laden).
(
  set -euo pipefail
  export DOMAIN_NAME=example.org SMTP_HOST=h SMTP_USER=u SMTP_PASS=p \
         ADMIN_PASS='Aa1!aaaaaaaa' WG_ENABLE=false
  # shellcheck disable=SC1090,SC1091
  source "$REPO/modules_V1s/01_config.sh"
  # shellcheck disable=SC1090,SC1091
  source "$REPO/modules_V1s/02_lib.sh"
  # shellcheck disable=SC1090,SC1091
  source "$REPO/modules_V1s/06a_network_certs.sh"
  # shellcheck disable=SC1090,SC1091
  source "$REPO/modules_V1s/06_civitas.sh"
  declare -F request_fresh_prod_certificates patch_playbook_urls verify_certificates >/dev/null
  declare -F clone_civitas_repo install_civitas check_helm_repo_egress apply_patches >/dev/null
); rc=$?
check "06a/06_civitas definieren Kernfunktionen" "0" "$rc"

# 4) Regression: eine absichtlich abgeschnittene Kopie muss bash -n rot werden lassen.
cp "$REPO/modules_V1s/06_civitas.sh" "$T/truncated.sh"
# Datei kurz vor dem Ende abschneiden (syntaktisch unvollständig).
head -n -5 "$T/truncated.sh" > "$T/t2.sh"
mv "$T/t2.sh" "$T/truncated.sh"
bash -n "$T/truncated.sh" >/dev/null 2>&1; rc=$?
check "abgeschnittene Kopie -> bash -n ungleich 0" "yes" "$([[ "$rc" -ne 0 ]] && echo yes || echo no)"

rm -rf "$T"

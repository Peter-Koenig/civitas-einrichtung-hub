#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 CIVITAS/CORE Contributors
#
# Licensed under the EUPL, Version 1.2 only (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#   https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Licence for the specific language governing permissions and
# limitations under the Licence.
#
# 02_lib.sh — CIVITAS/CORE V2: Hilfsfunktionen
#
# Siehe: skriptarchitektur.md (V2)
# Enthält keine Installationslogik und keine Seiteneffekte beim Laden.
# Wird in den set -euo pipefail-Kontext des Entry-Points hinein gesourct.

# ── Logging ──────────────────────────────────────────────────────────────────
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ── Idempotenz-Prüfungen ────────────────────────────────────────────────────
is_installed()   { command -v "$1" &>/dev/null; }
is_active()      { systemctl is-active --quiet "$1"; }
k8s_ready()      { kubectl get "$1" "$2" -n "${3:-default}" &>/dev/null; }

# ── Netzwerkprüfungen ────────────────────────────────────────────────────────
tcp_reachable()  { timeout 5 bash -c "echo >/dev/tcp/${1}/${2}" &>/dev/null; }
dns_resolves()   { dig +short "$1" | grep -q '.'; }

# ── Warteschleife für Kubernetes-Pods ────────────────────────────────────────
pods_ready() {
  local namespace="$1"
  local timeout="${2:-$TIMEOUT_POD_READY}"
  kubectl wait --for=condition=Ready pods --all \
    -n "$namespace" --timeout="${timeout}s"
}

# ── Fehlercount-Mechanismus für Phase 3 (Verifikation) ──────────────────────
VERIFY_ERRORS=0
verify_check() {
  local description="$1"
  local result="$2"
  if [[ "$result" -eq 0 ]]; then
    log_ok "[VERIFY] ${description} ... OK"
  else
    log_error "[VERIFY] ${description} ... FAILED"
    (( VERIFY_ERRORS++ )) || true
  fi
}

# ── Prüfe Exit-Code mit Abbruch (für harte Preflight-Prüfungen) ──────────────
assert_success() {
  local message="$1"
  local result="$2"
  if [[ "$result" -ne 0 ]]; then
    log_error "${message} — Abbruch"
    exit 1
  fi
}

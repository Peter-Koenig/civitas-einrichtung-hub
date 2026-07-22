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
# Phase 1a: k3s installieren
set -euo pipefail

install_k3s() {
  log "=== Phase 1a: k3s ==="

  if [[ "${K3S_ALREADY_INSTALLED:-false}" == "true" ]] || systemd_active k3s; then
    log_ok "k3s bereits aktiv — überspringe Installation"
    return 0
  fi

  log "Installiere k3s ${K3S_VERSION} ..."
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_EXEC="${K3S_EXEC_ARGS}" \
      sh -

  # Warten bis k3s-API antwortet (kubeconfig-Datei vorhanden)
  wait_k3s_api

  # kubeconfig bereitstellen (erst nach API-Start)
  mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
  install -m 600 /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_PATH}"

  # Warten bis Node im API-Server registriert ist
  wait_k3s_node

  # Warten bis Node Ready
  log "Warte auf Node Ready ..."
  kubectl wait node --all --for=condition=Ready --timeout=120s
  log_ok "k3s installiert und Node Ready"
}

# ── Warten auf k3s-API (kubeconfig-Datei) ────────────────────────────────
wait_k3s_api() {
  local max_wait=60
  local waited=0
  log "Warte auf k3s-API (kubeconfig) ..."
  while [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $max_wait ]]; then
      log_error "k3s-API nicht verfügbar nach ${max_wait}s — /etc/rancher/k3s/k3s.yaml fehlt"
      exit 1
    fi
  done
  log_ok "k3s-API verfügbar nach ${waited}s"
}

# ── Warten auf Node-Registrierung im API-Server ───────────────────────────
wait_k3s_node() {
  local max_wait=60
  local waited=0
  log "Warte auf Node-Registrierung ..."
  while true; do
    local nodes
    nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
    if [[ -n "$nodes" ]]; then
      log_ok "Node registriert nach ${waited}s"
      break
    fi
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge $max_wait ]]; then
      log_error "Kein Node nach ${max_wait}s registriert"
      kubectl get nodes 2>&1 || true
      exit 1
    fi
  done
}

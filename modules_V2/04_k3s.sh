#!/usr/bin/env bash
#
# 04_k3s.sh — Phase 1a: k3s-Cluster installieren
#
# Siehe: skriptarchitektur.md (V2), Phase 1a
# Installiert k3s ≥ 1.32 als Single-Node-Cluster auf der Ziel-VM.
#
# Abhängigkeiten:
#   - 01_config.sh: K3S_VERSION, K3S_EXEC_ARGS, KUBECONFIG_PATH
#   - 02_lib.sh: log_*, is_installed, is_active, pods_ready
#
# Idempotenz: Wenn k3s systemd-Service aktiv und Version korrekt → überspringen.

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
install_k3s() {
  log "=== Phase 1a: k3s-Cluster ==="

  # TODO: Idempotenz-Prüfung: k3s systemd-Service aktiv und Version korrekt?
  #   if is_active k3s && k3s --version | grep -q "${K3S_VERSION}"; then
  #     log_ok "k3s ${K3S_VERSION} bereits installiert – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung: k3s installieren
  #   curl -sfL https://get.k3s.io \
  #     | INSTALL_K3S_VERSION="${K3S_VERSION}" \
  #       INSTALL_K3S_EXEC="${K3S_EXEC_ARGS}" \
  #       sh -
  log "Installiere k3s ${K3S_VERSION} (${K3S_EXEC_ARGS}) …"

  # TODO: Implementierung: kubeconfig bereitstellen
  #   mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
  #   install -m 600 /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_PATH}"
  log "Kopiere kubeconfig nach ${KUBECONFIG_PATH} …"

  # TODO: Implementierung: Auf Node Ready warten
  #   kubectl wait node --all --for=condition=Ready --timeout=120s
  log "Warte auf Node Ready …"

  # TODO: Prüfung: kubectl get nodes – mindestens 1 Node, Status Ready
  #   local node_count node_status
  #   node_count="$(kubectl get nodes -o name | wc -l)"
  #   node_status="$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')"
  #   if [[ "$node_count" -ge 1 ]] && [[ "$node_status" == "True" ]]; then
  #     log_ok "k3s ${K3S_VERSION} installiert und Node Ready"
  #   else
  #     log_error "k3s-Node nicht bereit – Abbruch"
  #     exit 1
  #   fi

  log_ok "Phase 1a abgeschlossen – k3s-Cluster betriebsbereit"
}

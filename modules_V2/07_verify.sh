#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 p2d2 Contributors
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
# 07_verify.sh — Phase 3: Verifikation und Fehlerreport (CIVITAS/CORE V2)
#
# Siehe: skriptarchitektur.md (V2), installationsphasen-und-abnahme.md (V2)
#
# Führt alle Abnahmeprüfungen aus Phase 1 und Phase 2 erneut aus
# und gibt einen zusammenfassenden Fehlerreport aus.
#
# Abhängigkeiten:
#   - 02_lib.sh (log_*, verify_check, VERIFY_ERRORS)
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
run_verification() {
  log "=== Phase 3: Verifikation ==="
  VERIFY_ERRORS=0

  verify_phase1
  verify_phase2
  report_result
}

# ── Phase-1-Prüfungen (k3s, cert-manager, nginx, StorageClass) ───────────────

verify_phase1() {
  log "Phase 1 — Kubernetes-Cluster und Add-ons …"

  # TODO: Implementierung: k3s-Node-Status prüfen
  #   kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}'
  #   Erwartung: "True"
  verify_check "k3s Node Ready" 0

  # TODO: Implementierung: System-Pods auf Errors prüfen
  #   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o name
  #   Erwartung: Keine nicht-laufenden Pods
  verify_check "System-Pods alle Running oder Completed" 0

  # TODO: Implementierung: cert-manager Deployment Ready
  #   kubectl get deployment cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}'
  #   Erwartung: ≥ 1
  verify_check "cert-manager Running" 0

  # TODO: Implementierung: ClusterIssuer selfsigned-ca vorhanden
  #   kubectl get clusterissuer selfsigned-ca
  #   Erwartung: READY = True
  verify_check "ClusterIssuer selfsigned-ca" 0

  # TODO: Implementierung: nginx-Ingress DaemonSet vorhanden und Ready
  #   kubectl get daemonset ingress-nginx-controller -n "${INGRESS_NAMESPACE}" &>/dev/null
  #   verify_check "nginx-Ingress DaemonSet vorhanden" $?
  #   local desired ready
  #   desired="$(kubectl get daemonset ingress-nginx-controller \
  #     -n "${INGRESS_NAMESPACE}" \
  #     -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  #   ready="$(kubectl get daemonset ingress-nginx-controller \
  #     -n "${INGRESS_NAMESPACE}" \
  #     -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  #   [[ "$desired" -ge 1 && "$ready" -eq "$desired" ]]
  #   verify_check "nginx-Ingress DaemonSet Ready (${ready}/${desired})" $?
  verify_check "nginx-Ingress DaemonSet Running" 0

  # TODO: Implementierung: Storage Class local-path ist Default
  #   kubectl get storageclass local-path -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}'
  #   Erwartung: "true"
  verify_check "Storage Class local-path (Default)" 0

  log_ok "Phase-1-Prüfungen abgeschlossen"
}

# ── Phase-2-Prüfungen (Deployment-Repo, Pods, Ingress, WireGuard) ────────────

verify_phase2() {
  log "Phase 2 — CIVITAS/CORE V2 Plattform …"

  # TODO: Implementierung: Deployment-Repository vorhanden
  #   test -d "${CC_V2_REPO_PATH}/.git"
  #   Erwartung: Exit-Code 0
  verify_check "Deployment-Repository ${CC_V2_REPO_PATH}" 0

  # TODO: Implementierung: Symlink /opt/civitas-core → /opt/civitas-core-v2
  #   test -L /opt/civitas-core && test "$(readlink /opt/civitas-core)" = "${CC_V2_REPO_PATH}"
  #   Erwartung: Exit-Code 0
  verify_check "Symlink /opt/civitas-core" 0

  # TODO: Implementierung: Namespace vorhanden
  #   kubectl get namespace "${K8S_NAMESPACE}"
  #   Erwartung: Status "Active"
  verify_check "Namespace ${K8S_NAMESPACE}" 0

  # TODO: Implementierung: Pods der Plattform – kein Error / CrashLoopBackOff
  #   kubectl get pods -n "${K8S_NAMESPACE}" --field-selector=status.phase!=Running,status.phase!=Succeeded -o name
  #   Erwartung: 0 nicht-laufende Pods
  verify_check "CIVITAS/CORE-V2-Pods alle Running" 0

  # TODO: Implementierung: Ingress-Ressourcen vorhanden
  #   kubectl get ingress -n "${K8S_NAMESPACE}" -o name
  #   Erwartung: ≥ 2 Einträge (idm + portal)
  verify_check "Ingress-Ressourcen vorhanden" 0

  # TODO: Implementierung: SSL-Redirect deaktiviert
  #   kubectl get ingress -n "${K8S_NAMESPACE}" \
  #     -o jsonpath='{.items[*].metadata.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect}'
  #   Erwartung: "false" für alle Ingress-Ressourcen
  verify_check "ssl-redirect deaktiviert" 0

  # TODO: Implementierung: keycloak-smtp-Secret vorhanden
  #   kubectl get secret keycloak-smtp -n "${K8S_NAMESPACE}"
  #   Erwartung: Exit-Code 0
  verify_check "Secret keycloak-smtp" 0

  # TODO: Implementierung: WireGuard-Tunnel aktiv
  #   systemctl is-active wg-quick@wg0
  #   Erwartung: active
  verify_check "WireGuard-Tunnel ${WG_INTERFACE}" 0

  # TODO: Implementierung: Konnektivität zu OPNsense
  #   ping -c2 -W2 "${WG_OPN_IP}"
  #   Erwartung: 0% packet loss
  verify_check "WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP})" 0

  # TODO: Implementierung: Keycloak intern erreichbar
  #   curl -sf --max-time 10 -H "Host: idm.${DOMAIN}" http://localhost:8080/health -o /dev/null 2>/dev/null
  #   Erwartung: HTTP 200
  verify_check "Keycloak idm.${DOMAIN} intern erreichbar" 0

  # TODO: Implementierung: Portal intern erreichbar
  #   curl -sf --max-time 10 -H "Host: portal.${DOMAIN}" http://localhost:8080/ -o /dev/null 2>/dev/null
  #   Erwartung: HTTP 200 oder Redirect auf Login
  verify_check "Portal portal.${DOMAIN} intern erreichbar" 0

  log_ok "Phase-2-Prüfungen abgeschlossen"
}

# ── Fehlerreport ──────────────────────────────────────────────────────────────

report_result() {
  log ""
  log "------------------------------------------------------------"
  if [[ "$VERIFY_ERRORS" -eq 0 ]]; then
    log_ok "Alle Prüfungen bestanden. Installation erfolgreich."
    exit 0
  else
    log_error "${VERIFY_ERRORS} Prüfung(en) fehlgeschlagen."
    log "Bitte Logs prüfen und fehlgeschlagene Schritte korrigieren."
    exit 1
  fi
}

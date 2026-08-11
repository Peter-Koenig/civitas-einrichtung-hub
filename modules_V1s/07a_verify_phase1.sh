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
# 07a_verify_phase1.sh — Phase 3: Cluster- und Add-on-Prüfungen
#
# Siehe: skriptarchitektur.md (V1), Modul 07
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 3
#
# Enthält verify_phase1(): prüft k3s-Node, System-Pods, cert-manager,
# ClusterIssuer, CA-Issuer-DN, nginx-Ingress (DaemonSet), StorageClass.
#
# Abhängigkeiten:
#   - 02_lib.sh (log_*, check, VERIFY_ERRORS)
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)

# ── Phase-1-Prüfungen ──────────────────────────────────────────────────────────

verify_phase1() {
  log "Phase 1 — Kubernetes-Cluster und Add-ons ..."

  # Cluster-Status: 1 Node, Ready
  local node_count node_status
  node_count="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get nodes -o jsonpath='{.items[*].metadata.name}' | wc -w)"
  node_status="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')"
  if [[ "$node_count" -ge 1 ]] && [[ "$node_status" == "True" ]]; then
    log_ok "[PHASE 1] k3s Node Ready ... OK"
  else
    log_error "[PHASE 1] k3s Node nicht bereit (Nodes: ${node_count}, Status: ${node_status})"
    (( VERIFY_ERRORS++ )) || true
  fi

  # System-Pods: kein Error / CrashLoopBackOff
  local failed_pods
  failed_pods="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o name 2>/dev/null | wc -l)"
  if [[ "$failed_pods" -eq 0 ]]; then
    log_ok "[PHASE 1] System-Pods alle Running oder Completed ... OK"
  else
    log_error "[PHASE 1] ${failed_pods} Pod(s) nicht in Running/Succeeded"
    (( VERIFY_ERRORS++ )) || true
  fi

  # cert-manager
  if kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get deployment cert-manager -n cert-manager &>/dev/null; then
    local cm_ready
    cm_ready="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
      get deployment cert-manager -n cert-manager \
      -o jsonpath='{.status.readyReplicas}')"
    if [[ "$cm_ready" -ge 1 ]]; then
      log_ok "[PHASE 1] cert-manager Running ... OK"
    else
      log_error "[PHASE 1] cert-manager nicht Ready"
      (( VERIFY_ERRORS++ )) || true
    fi
  else
    log_error "[PHASE 1] cert-manager Deployment nicht gefunden"
    (( VERIFY_ERRORS++ )) || true
  fi

  # ClusterIssuer
  if kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get clusterissuer selfsigned-issuer &>/dev/null; then
    log_ok "[PHASE 1] ClusterIssuer selfsigned-issuer ... OK"
  else
    log_error "[PHASE 1] ClusterIssuer selfsigned-issuer nicht gefunden"
    (( VERIFY_ERRORS++ )) || true
  fi

  # CA-Issuer-DN nicht leer (Java-Kompatibilität)
  local ca_cert="/usr/local/share/ca-certificates/civitas-core-ca.crt"
  if [[ -f "${ca_cert}" ]]; then
    local issuer
    issuer=$(openssl x509 -in "${ca_cert}" -noout -issuer 2>/dev/null || echo "")
    if echo "${issuer}" | grep -q "CN=civitas-core-ca"; then
      log_ok "[PHASE 1] CA-Issuer-DN korrekt: ${issuer} ... OK"
    else
      log_error "[PHASE 1] CA-Issuer-DN leer oder falsch: ${issuer}"
      (( VERIFY_ERRORS++ )) || true
    fi
  else
    log_error "[PHASE 1] CA-Zertifikat nicht gefunden: ${ca_cert}"
    (( VERIFY_ERRORS++ )) || true
  fi

  # nginx-Ingress — DAEMONSET, nicht Deployment
  if kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get daemonset ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    local ingress_ready
    ingress_ready="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
      get daemonset ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.numberReady}')"
    if [[ "$ingress_ready" -ge 1 ]]; then
      log_ok "[PHASE 1] nginx-Ingress (DaemonSet) Running ... OK"
    else
      log_error "[PHASE 1] nginx-Ingress DaemonSet nicht Ready"
      (( VERIFY_ERRORS++ )) || true
    fi
  else
    log_error "[PHASE 1] nginx-Ingress DaemonSet nicht gefunden"
    (( VERIFY_ERRORS++ )) || true
  fi

  # Storage Class
  local sc_default
  sc_default="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get storageclass local-path \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)"
  if [[ "$sc_default" == "true" ]]; then
    log_ok "[PHASE 1] Storage Class local-path (Default) ... OK"
  else
    log_error "[PHASE 1] Storage Class local-path nicht als Default markiert"
    (( VERIFY_ERRORS++ )) || true
  fi
}

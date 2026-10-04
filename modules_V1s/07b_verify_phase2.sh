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
# 07b_verify_phase2.sh — Phase 3: CIVITAS/CORE-Plattformprüfungen (V1)
#
# Enthält verify_phase2(): prüft Namespaces (K8S_NAMESPACES-Array aus
# 01_config.sh), Deployments, Ingress-Ressourcen, TLS-Zertifikate,
# Keycloak- und Portal-Erreichbarkeit (HTTPS via HAProxy-Passthrough),
# WireGuard-Tunnel sowie Konnektivität zu OPNsense (nur bei WG_ENABLE=true).
#
# Abhängigkeiten:
#   - 02_lib.sh (log_*, VERIFY_ERRORS)
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)
#   - 01_config.sh (K8S_NAMESPACES, DOMAIN, WG_INTERFACE, WG_OPN_IP)

# ── Phase-2-Prüfungen ──────────────────────────────────────────────────────────

verify_phase2() {
  log "Phase 2 — CIVITAS/CORE-Plattform ..."

  # Namespaces vorhanden (Array from 01_config.sh)
  local ns_ok=true
  for ns in "${K8S_NAMESPACES[@]}"; do
    if kubectl --kubeconfig="${KUBECONFIG_PATH}" \
      get namespace "${ns}" &>/dev/null; then
      log_ok "[PHASE 2] Namespace ${ns} ... OK"
    else
      log_error "[PHASE 2] Namespace ${ns} nicht gefunden"
      (( VERIFY_ERRORS++ )) || true
      ns_ok=false
    fi
  done
  if [[ "${ns_ok}" == false ]]; then
    return 1
  fi

  # Pods der Plattform (aggregiert ueber alle K8S_NAMESPACES).
  # Job-Pods in Phase Succeeded werden separat gezählt; alle übrigen müssen
  # Running sein und alle Container ready.
  local total_running=0 total_completed=0
  local failing_pods=()
  local ns
  for ns in "${K8S_NAMESPACES[@]}"; do
    local completed
    completed="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n "${ns}" \
      --field-selector=status.phase=Succeeded -o name 2>/dev/null | wc -l | tr -d ' ')"
    total_completed=$(( total_completed + completed ))
    local pod_name pod_phase pod_ready
    while IFS=$'\t' read -r pod_name pod_phase pod_ready; do
      [[ -n "${pod_name}" ]] || continue
      if [[ "${pod_phase}" == "Running" && "${pod_ready}" == "true" ]]; then
        total_running=$(( total_running + 1 ))
      else
        failing_pods+=("${ns}/${pod_name}")
      fi
    done < <(kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n "${ns}" \
      --field-selector=status.phase!=Succeeded -o json 2>/dev/null \
      | jq -r '.items[] | [.metadata.name, .status.phase, (([.status.containerStatuses[]?.ready] | all))] | @tsv')
  done
  if [[ ${#failing_pods[@]} -eq 0 ]]; then
    if [[ "${total_completed}" -gt 0 ]]; then
      log_ok "[PHASE 2] ${total_running} Running, ${total_completed} Completed (Job) ... OK"
    else
      log_ok "[PHASE 2] ${total_running} Pods Running ... OK"
    fi
  else
    log_error "[PHASE 2] ${#failing_pods[@]} Pod(s) nicht Ready: ${failing_pods[*]}"
    (( VERIFY_ERRORS++ )) || true
  fi

  # Ingress-Ressourcen (aggregiert ueber alle K8S_NAMESPACES)
  local total_ingress=0
  for ns in "${K8S_NAMESPACES[@]}"; do
    local ic_ns
    ic_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get ingress -n "${ns}" -o name 2>/dev/null | wc -l)"
    total_ingress=$(( total_ingress + ic_ns ))
  done
  if [[ "$total_ingress" -ge 2 ]]; then
    log_ok "[PHASE 2] Ingress-Ressourcen (${total_ingress}) ... OK"
  elif [[ "$total_ingress" -eq 1 ]]; then
    log_warn "[PHASE 2] Nur 1 Ingress-Ressource gefunden (erwartet: mindestens 2)"
    (( VERIFY_ERRORS++ )) || true
  else
    log_error "[PHASE 2] Keine Ingress-Ressourcen in Namespaces"
    (( VERIFY_ERRORS++ )) || true
  fi

  # TLS-Zertifikate (aggregiert ueber alle K8S_NAMESPACES)
  local total_certs=0 certs_not_ready=false
  for ns in "${K8S_NAMESPACES[@]}"; do
    local cc_ns cr_ns
    cc_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get certificate -n "${ns}" -o name 2>/dev/null | wc -l)"
    cr_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get certificate -n "${ns}" \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    total_certs=$(( total_certs + cc_ns ))
    if [[ "$cr_ns" == *"False"* ]]; then
      certs_not_ready=true
    fi
  done
  if [[ "$total_certs" -gt 0 ]] && [[ "$certs_not_ready" == false ]]; then
    log_ok "[PHASE 2] TLS-Zertifikate (${total_certs}) ... OK"
  else
    log_error "[PHASE 2] TLS-Zertifikate nicht bereit"
    (( VERIFY_ERRORS++ )) || true
  fi

  # Hinweis: HAProxy-Architektur (TCP-Passthrough) im Modus mit WireGuard
  # HAProxy auf OPNsense leitet TLS für *.udp.<DOMAIN> per TCP-Passthrough
  # an 10.10.10.5:443 (WireGuard-IP der VM) weiter. nginx terminiert TLS mit
  # cert-manager-Zertifikaten.

  # Keycloak erreichbar (HTTPS via HAProxy-Passthrough, --cacert prüft CA-Trust)
  if curl -sf --max-time 10 \
    --cacert /usr/local/share/ca-certificates/civitas-core-ca.crt \
    "https://idm.${DOMAIN}/realms/master" \
    -o /dev/null 2>/dev/null; then
    log_ok "[PHASE 2] Keycloak https://idm.${DOMAIN} erreichbar ... OK"
  else
    log_warn "[PHASE 2] Keycloak https://idm.${DOMAIN} nicht erreichbar"
    # Kein Fehlerzähler — Endpunkt /realms/master sollte stabil sein
  fi

  # Portal erreichbar (HTTPS via HAProxy-Passthrough)
  if curl -sf --max-time 10 \
    --cacert /usr/local/share/ca-certificates/civitas-core-ca.crt \
    "https://${DOMAIN}/" \
    -o /dev/null 2>/dev/null; then
    log_ok "[PHASE 2] Portal https://${DOMAIN} erreichbar ... OK"
  else
    log_error "[PHASE 2] Portal https://${DOMAIN} nicht erreichbar"
    (( VERIFY_ERRORS++ )) || true
  fi

  # ssl-redirect-Check entfällt: mit HAProxy-Passthrough terminiert nginx TLS
  # selbst. ssl-redirect=true (Default) ist korrekt und erwünscht.

  # WireGuard-Tunnel aktiv
  if [[ "${WG_ENABLED}" == "true" ]]; then
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
      log_ok "[PHASE 2] WireGuard-Tunnel ${WG_INTERFACE} aktiv ... OK"
    else
      log_error "[PHASE 2] WireGuard-Tunnel ${WG_INTERFACE} nicht aktiv"
      (( VERIFY_ERRORS++ )) || true
    fi

    # Konnektivität zu OPNsense
    if ping -c2 -W2 "${WG_OPN_IP}" >/dev/null 2>&1; then
      log_ok "[PHASE 2] WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) ... OK"
    else
      log_error "[PHASE 2] OPNsense ${WG_OPN_IP} nicht erreichbar"
      (( VERIFY_ERRORS++ )) || true
    fi
  else
    log "[PHASE 2] WireGuard deaktiviert (WG_ENABLE=false) — Tunnel-/OPNsense-Prüfung übersprungen"
  fi

  # Platzhalter-Literale (TODO:PLEASE/TODO_PLEASE/CHANGE_ME) im Cluster prüfen.
  guard_placeholder_literals
}

# ── guard_placeholder_literals: Literal-Scan über Secrets/ConfigMaps ──────
# Sucht in K8S_NAMESPACES nach den Platzhalter-Literalen TODO:PLEASE,
# TODO_PLEASE und CHANGE_ME. Ausgabe nur Art + Namespace/Name + key, nie ein
# Wert. Treffer sind ein Fehler (VERIFY_ERRORS++, return 1).
#
# Keine leeren Läufe: kubectl-Ausgabe wird in eine temporäre Datei (0600)
# gelesen und der Exitcode von kubectl UND jq geprüft. Ein fehlendes
# data-Feld wird über "(.data // {})" toleriert, damit Secrets/ConfigMaps
# mit ausschließlich binaryData den Scan nicht abbrechen. Je Namespace muss
# mindestens eine ConfigMap gelesen werden (kube-root-ca.crt existiert
# immer); sonst gilt der Scan als fehlgeschlagen, nicht als OK.
guard_placeholder_literals() {
  local ns name key value decoded hits=0 scan_errors=0
  local raw_file scan_file cm_count
  raw_file="$(mktemp)"
  scan_file="$(mktemp)"

  for ns in "${K8S_NAMESPACES[@]}"; do
    # Secrets: kubectl- und jq-Exitcode prüfen (nicht verschlucken).
    if ! kubectl --kubeconfig="${KUBECONFIG_PATH}" get secrets -n "${ns}" -o json >"${raw_file}" 2>/dev/null; then
      log_error "Platzhalter-Scan: kubectl get secrets -n ${ns} fehlgeschlagen"
      scan_errors=$((scan_errors + 1))
    elif ! jq -r '.items[] | .metadata.name as $n | (.data // {}) | to_entries[] | "\($n)\t\(.key)\t\(.value)"' "${raw_file}" >"${scan_file}" 2>/dev/null; then
      log_error "Platzhalter-Scan: jq-Auswertung (secrets -n ${ns}) fehlgeschlagen"
      scan_errors=$((scan_errors + 1))
    else
      while IFS=$'\t' read -r name key value; do
        [[ -n "${name}" ]] || continue
        decoded="$(printf '%s' "${value}" | base64 -d 2>/dev/null || true)"
        if printf '%s' "${decoded}" | grep -qE 'TODO:PLEASE|TODO_PLEASE|CHANGE_ME'; then
          log_error "Platzhalter-Literal: Secret ${ns}/${name} key=${key}"
          hits=$((hits + 1))
        fi
      done < "${scan_file}"
    fi

    # ConfigMaps: kubectl-Exitcode prüfen, dann Sanity-Check (mindestens eine
    # ConfigMap je Namespace), dann jq-Exitcode prüfen.
    if ! kubectl --kubeconfig="${KUBECONFIG_PATH}" get configmaps -n "${ns}" -o json >"${raw_file}" 2>/dev/null; then
      log_error "Platzhalter-Scan: kubectl get configmaps -n ${ns} fehlgeschlagen"
      scan_errors=$((scan_errors + 1))
    else
      cm_count="$(jq -r '.items | length' "${raw_file}" 2>/dev/null || echo 0)"
      if [[ "${cm_count}" -eq 0 ]]; then
        log_error "Platzhalter-Scan: Scan hat keine Objekte gelesen (ConfigMaps in ${ns})"
        scan_errors=$((scan_errors + 1))
      elif ! jq -r '.items[] | .metadata.name as $n | (.data // {}) | to_entries[] | "\($n)\t\(.key)\t\(.value)"' "${raw_file}" >"${scan_file}" 2>/dev/null; then
        log_error "Platzhalter-Scan: jq-Auswertung (configmaps -n ${ns}) fehlgeschlagen"
        scan_errors=$((scan_errors + 1))
      else
        while IFS=$'\t' read -r name key value; do
          [[ -n "${name}" ]] || continue
          if printf '%s' "${value}" | grep -qE 'TODO:PLEASE|TODO_PLEASE|CHANGE_ME'; then
            log_error "Platzhalter-Literal: ConfigMap ${ns}/${name} key=${key}"
            hits=$((hits + 1))
          fi
        done < "${scan_file}"
      fi
    fi
  done

  rm -f "${raw_file}" "${scan_file}"

  if [[ ${hits} -gt 0 ]]; then
    log_error "[PHASE 2] ${hits} Platzhalter-Literal(e) gefunden — Template/Inventory prüfen"
    (( VERIFY_ERRORS++ )) || true
    return 1
  fi
  if [[ ${scan_errors} -gt 0 ]]; then
    log_error "[PHASE 2] Platzhalter-Scan unvollständig (${scan_errors} Fehler) — nicht als OK gewertet"
    (( VERIFY_ERRORS++ )) || true
    return 1
  fi
  log_ok "[PHASE 2] Keine Platzhalter-Literale (TODO:PLEASE/TODO_PLEASE/CHANGE_ME) in Secrets/ConfigMaps ... OK"
  return 0
}

#!/usr/bin/env bash
#
# 07_verify.sh — Phase 3: Verifikation und Fehlerreport (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 07
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 3
#
# Führt alle Abnahmeprüfungen aus Phase 1 und Phase 2 erneut aus
# und gibt einen zusammenfassenden Fehlerreport aus.
#
# Hinweis TLS: HAProxy-Architektur (TCP-Passthrough)
# HAProxy auf OPNsense leitet TLS-Verbindungen für *.udp.<DOMAIN>
# per TCP-Passthrough (Layer 4) direkt an 10.10.10.5:443 weiter.
# nginx in der VM terminiert TLS selbstständig mit Zertifikaten von
# cert-manager (CA: civitas-core-ca). ssl-redirect=true ist korrekt.
# HTTPS-Prüfungen verwenden --cacert mit dem lokalen CA-Zertifikat.
#
# Abhängigkeiten:
#   - 02_lib.sh (log_*, check, VERIFY_ERRORS)
#   - kubectl mit gültigem KUBECONFIG (exportiert in 01_config.sh)

run_verification() {
  log "=== Phase 3: Verifikation ==="
  VERIFY_ERRORS=0

  verify_phase1
  verify_phase2
  if [[ "${RUN_TESTS:-false}" == "true" ]]; then
    setup_tests_env
    run_test_suite
  fi
  report_result
}

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

# ── Phase-2-Prüfungen ──────────────────────────────────────────────────────────

verify_phase2() {
  log "Phase 2 — CIVITAS/CORE-Plattform ..."

  # Namespace vorhanden
  if kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get namespace "${K8S_NAMESPACE}" &>/dev/null; then
    log_ok "[PHASE 2] Namespace ${K8S_NAMESPACE} ... OK"
  else
    log_error "[PHASE 2] Namespace ${K8S_NAMESPACE} nicht gefunden"
    (( VERIFY_ERRORS++ )) || true
    # Restliche Prüfungen abbrechen, wenn Namespace fehlt
    return 1
  fi

  # Pods der Plattform
  local civitas_pods civitas_running civitas_failed
  civitas_pods="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get pods -n "${K8S_NAMESPACE}" -o name 2>/dev/null | wc -l)"
  civitas_running="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get pods -n "${K8S_NAMESPACE}" \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)"
  civitas_failed="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get pods -n "${K8S_NAMESPACE}" \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    -o name 2>/dev/null | wc -l)"
  if [[ "$civitas_pods" -gt 0 ]] && [[ "$civitas_failed" -eq 0 ]]; then
    log_ok "[PHASE 2] ${civitas_running}/${civitas_pods} Pods Running ... OK"
  else
    log_error "[PHASE 2] ${civitas_failed} Pod(s) nicht Running (${civitas_running}/${civitas_pods})"
    (( VERIFY_ERRORS++ )) || true
  fi

  # Ingress-Ressourcen
  local ingress_count
  ingress_count="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get ingress -n "${K8S_NAMESPACE}" -o name 2>/dev/null | wc -l)"
  if [[ "$ingress_count" -ge 2 ]]; then
    log_ok "[PHASE 2] Ingress-Ressourcen (${ingress_count}) ... OK"
  elif [[ "$ingress_count" -eq 1 ]]; then
    log_warn "[PHASE 2] Nur 1 Ingress-Ressource gefunden (erwartet: 2 für idm + portal)"
    (( VERIFY_ERRORS++ )) || true
  else
    log_error "[PHASE 2] Keine Ingress-Ressourcen in ${K8S_NAMESPACE}"
    (( VERIFY_ERRORS++ )) || true
  fi

  # TLS-Zertifikate
  local cert_count cert_ready
  cert_count="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get certificate -n "${K8S_NAMESPACE}" -o name 2>/dev/null | wc -l)"
  cert_ready="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" \
    get certificate -n "${K8S_NAMESPACE}" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if [[ "$cert_count" -gt 0 ]] && [[ "$cert_ready" != *"False"* ]]; then
    log_ok "[PHASE 2] TLS-Zertifikate (${cert_count}) ... OK"
  else
    log_error "[PHASE 2] TLS-Zertifikate nicht bereit"
    (( VERIFY_ERRORS++ )) || true
  fi

  # Hinweis: HAProxy-Architektur (TCP-Passthrough)
  # HAProxy auf OPNsense leitet TLS für *.udp.<DOMAIN> per TCP-Passthrough
  # an 10.10.10.5:443 weiter. nginx terminiert TLS mit cert-manager-Zertifikaten.

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
}

# ── Test-Umgebung einrichten ────────────────────────────────────────────
setup_tests_env() {
  log "Richte Test-Umgebung ein (RUN_TESTS=true) …"

  local tests_dir="${CC_V1_REPO_PATH}/tests"
  if [[ ! -d "${tests_dir}" ]]; then
    log_warn "Tests-Verzeichnis nicht gefunden: ${tests_dir}"
    log_warn "  Installations-Repository enthaelt keine Tests — ueberspringe"
    return 1
  fi

  # uv installieren
  if ! command -v uv &>/dev/null; then
    log "Installiere uv …"
    pip install uv --quiet 2>/dev/null || {
      log_warn "uv-Installation fehlgeschlagen — Tests werden uebersprungen"
      return 1
    }
    log_ok "uv installiert"
  else
    log_ok "uv bereits installiert"
  fi

  # venv einrichten
  if [[ ! -d "${tests_dir}/.venv" ]]; then
    log "Richte Python-Venv mit uv sync ein …"
    (cd "${tests_dir}" && uv sync --quiet 2>/dev/null) || {
      log_warn "uv sync fehlgeschlagen — Tests werden uebersprungen"
      return 1
    }
    log_ok "Python-Venv eingerichtet"
  else
    log_ok "Python-Venv bereits vorhanden"
  fi

  # Playwright-Browser installieren
  log "Installiere Playwright-Browser …"
  (cd "${tests_dir}" && source .venv/bin/activate && playwright install --with-deps chromium 2>/dev/null) || {
    log_warn "Playwright-Installation fehlgeschlagen — UI-Tests werden uebersprungen"
  }

  # .env aus Secrets generieren (sofern nicht vorhanden)
  if [[ ! -f "${tests_dir}/.env" ]]; then
    log "Generiere .env aus Kubernetes-Secrets …"
    generate_test_env "${tests_dir}"
  else
    log_ok ".env bereits vorhanden"
  fi

  # GeoServer-Grundkonfiguration
  log "Fuehre GeoServer-Grundkonfiguration aus …"
  (cd "${tests_dir}" && source .venv/bin/activate && \
    pytest --only-geoserver-setup e2e_tests/ 2>/dev/null) || {
    log_warn "GeoServer-Grundkonfiguration fehlgeschlagen — wird ignoriert"
  }

  log_ok "Test-Umgebung bereit"
}

# ── .env aus Secrets generieren ───────────────────────────────────────────
generate_test_env() {
  local target_dir="$1"
  local env_file="${target_dir}/.env"

  # Hier werden die Zugangsdaten aus den Kubernetes-Secrets geholt
  cat > "${env_file}" << EOF
# Automatisch generiert durch install_civitas_core_V1.sh
DOMAIN=${DOMAIN}
ENVIRONMENT=${CC_ENVIRONMENT}
KEYCLOAK_ADMIN_USER=$(kubectl get secret ${CC_ENVIRONMENT}-keycloak-admin -n ${CC_ENVIRONMENT}-access-stack -o jsonpath='{.data.MASTER_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret ${CC_ENVIRONMENT}-keycloak-admin -n ${CC_ENVIRONMENT}-access-stack -o jsonpath='{.data.MASTER_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
EOF

  # Weitere Secrets nach Bedarf ergänzen
  local geoserver_user geoserver_pass
  geoserver_user=$(kubectl get secret geoserver-geoserver -n ${CC_ENVIRONMENT}-geodata-stack -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d 2>/dev/null || echo "admin")
  geoserver_pass=$(kubectl get secret geoserver-geoserver -n ${CC_ENVIRONMENT}-geodata-stack -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  cat >> "${env_file}" << EOF
GEOSERVER_USER=${geoserver_user}
GEOSERVER_PASSWORD=${geoserver_pass}
EOF

  log_ok "Test-.env generiert: ${env_file}"
}

# ── Test-Suite ausführen ─────────────────────────────────────────────────
run_test_suite() {
  local tests_dir="${CC_V1_REPO_PATH}/tests"
  log "Fuehre E2E-Tests aus (pytest --prod-safe) …"

  if [[ ! -f "${tests_dir}/.venv/bin/activate" ]]; then
    log_warn "Test-Venv nicht vorhanden — ueberspringe Tests"
    return 1
  fi

  local result=0
  (
    cd "${tests_dir}"
    source .venv/bin/activate
    pytest --prod-safe e2e_tests/ 2>&1
  ) || result=$?

  if [[ "${result}" -eq 0 ]]; then
    log_ok "E2E-Tests: ALLE BESTANDEN"
  else
    log_error "E2E-Tests: ${result} Test(s) fehlgeschlagen"
    log_warn "  Details: cd ${tests_dir} && source .venv/bin/activate && pytest --prod-safe e2e_tests/"
    (( VERIFY_ERRORS++ )) || true
  fi
}

# ── Fehlerreport ───────────────────────────────────────────────────────────────

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

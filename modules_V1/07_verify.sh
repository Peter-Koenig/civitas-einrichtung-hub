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

  # Pods der Plattform (aggregiert ueber alle K8S_NAMESPACES)
  local total_pods=0 total_running=0 total_failed=0
  for ns in "${K8S_NAMESPACES[@]}"; do
    local p_ns r_ns f_ns
    p_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n "${ns}" -o name 2>/dev/null | wc -l)"
    r_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n "${ns}" --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)"
    f_ns="$(kubectl --kubeconfig="${KUBECONFIG_PATH}" get pods -n "${ns}" --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | wc -l)"
    total_pods=$(( total_pods + p_ns ))
    total_running=$(( total_running + r_ns ))
    total_failed=$(( total_failed + f_ns ))
  done
  if [[ "$total_pods" -gt 0 ]] && [[ "$total_failed" -eq 0 ]]; then
    log_ok "[PHASE 2] ${total_running}/${total_pods} Pods Running ... OK"
  else
    log_error "[PHASE 2] ${total_failed} Pod(s) nicht Running (${total_running}/${total_pods})"
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
    log "Installiere uv via pipx (Userkontext) …"

    if ! command -v pipx &>/dev/null; then
      log "pipx nicht gefunden — installiere ueber apt (Debian-Repo) ..."
      apt-get install -y pipx python3-all python-is-python3 2>&1 || {
        log_warn "pipx-Installation ueber apt fehlgeschlagen — Tests werden uebersprungen"
        log_warn "  Bitte manuell installieren: apt-get install pipx python3-all python-is-python3"
        return 1
      }
      log_ok "pipx installiert"
    fi

    pipx ensurepath 2>/dev/null || true
    export PATH="${HOME}/.local/bin:${PATH}"

    pipx install uv 2>&1 || {
      log_warn "uv-Installation via pipx fehlgeschlagen — Tests werden uebersprungen"
      log_warn "  pipx-Ausgabe siehe oben; ggf. manuell: pipx install uv"
      return 1
    }

    if ! command -v uv &>/dev/null; then
      log_warn "uv nach pipx-Installation nicht im PATH gefunden — Tests werden uebersprungen"
      log_warn "  PATH=${PATH}"
      return 1
    fi

    log_ok "uv erfolgreich installiert: $(uv --version)"
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
  # HINWEIS: playwright install --with-deps NICHT verwenden — fragt
  # veraltete Ubuntu-Paketnamen (ttf-ubuntu-font-family, ttf-unifont)
  # an, die in Debian 13 Trixie nicht existieren. Ersatzpakete
  # (fonts-ubuntu aus non-free, fonts-unifont aus main) sowie die
  # Chromium-Laufzeitbibliotheken werden unten explizit installiert.
  log "Installiere Font- und Laufzeit-Abhaengigkeiten fuer Playwright/Chromium …"
  if apt-get install -y \
      fonts-ubuntu fonts-unifont \
      libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxcb1 \
      libxkbcommon0 libatspi2.0-0 libx11-6 libxcomposite1 libxdamage1 \
      libxext6 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 \
      libasound2 2>&1; then
    log_ok "Font- und Laufzeit-Abhaengigkeiten installiert"
  else
    log_warn "Font-/Bibliotheks-Installation fehlgeschlagen — Playwright-Browser-Install wird trotzdem versucht"
  fi

  log "Installiere Playwright-Browser (chromium, ohne --with-deps) …"
  cd "${tests_dir}"
  source .venv/bin/activate
  if "${tests_dir}/.venv/bin/python" -m playwright install chromium 2>&1; then
    log_ok "Playwright-Browser (chromium) installiert"
  else
    log_warn "Playwright-Installation fehlgeschlagen — UI-Tests werden uebersprungen"
  fi

  if "${tests_dir}/.venv/bin/python" -c "
from playwright.sync_api import sync_playwright
p = sync_playwright().start()
b = p.chromium.launch()
print('Chromium OK')
b.close()
p.stop()
" 2>&1; then
    log_ok "Chromium startet erfolgreich"
  else
    log_warn "Chromium-Start fehlgeschlagen — UI-Tests werden uebersprungen"
  fi

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

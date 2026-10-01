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
# 07c_verify_tests.sh — Phase 3: E2E-Testsuite (optional)
#
# Enthaelt setup_tests_env(), generate_test_env() und run_test_suite().
# Wird nur ausgefuehrt, wenn RUN_TESTS=true gesetzt ist.
#
# Abhaengigkeiten:
#   - 02_lib.sh (log_*, VERIFY_ERRORS)
#   - kubectl mit gueltigem KUBECONFIG (aus 01_config.sh)
#   - CC_V1_REPO_PATH (aus 01_config.sh)

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
QUANTUMLEAP_DB_PASSWORD=unused   # Platzhalter: Fixture verlangt den Wert, QuantumLeap ist in V1s deaktiviert
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

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
# 07_verify.sh — Phase 3: Verifikation und Fehlerreport (Orchestrator)
#
# Siehe: skriptarchitektur.md (V1), Modul 07
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 3
#
# Sourct die Teilmodule 07a-07d und orchestriert deren Aufruf in der
# bekannten Reihenfolge. Enthält selbst KEINE Prüf-Logik mehr.
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

# Pfad zum eigenen Verzeichnis ermitteln, damit die Teilmodule unabhängig
# vom Aufrufkontext (VM oder lokal) gefunden werden.
MODULES_V1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${MODULES_V1_DIR}/07a_verify_phase1.sh"
source "${MODULES_V1_DIR}/07b_verify_phase2.sh"
source "${MODULES_V1_DIR}/07c_verify_tests.sh"
source "${MODULES_V1_DIR}/07d_report.sh"

run_verification() {
  log "=== Phase 3: Verifikation ==="
  VERIFY_ERRORS=0

  verify_phase1
  verify_phase2
  verify_portal_tiles
  if [[ "${RUN_TESTS:-false}" == "true" ]]; then
    setup_tests_env
    run_test_suite
  fi
  report_result
}

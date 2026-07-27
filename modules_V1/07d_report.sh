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
# 07d_report.sh — Phase 3: Fehlerreport
#
# Enthält report_result(): gibt die Anzahl der Fehler (VERIFY_ERRORS) aus
# und beendet das Skript mit exit 0 (alle bestanden) oder exit 1 (Fehler).
# Abhängigkeiten:
#   - 02_lib.sh (log, log_ok, log_error, VERIFY_ERRORS)
#   - VERIFY_ERRORS aus 07_verify.sh (globaler Zähler)

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

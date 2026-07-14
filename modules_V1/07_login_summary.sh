#!/usr/bin/env bash
#
# 07_login_summary.sh — Login-Zusammenfassung (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 07
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 3
# Siehe: idm-provisionierung-und-login.md (V1)
#
# Enthält die Funktion login_summary(), die nach der Installation eine
# Übersicht aller Zugangsdaten und URLs für die CIVITAS/CORE-Plattform
# ausgibt.
#
# Abhängigkeiten:
#   - 01_config.sh: DOMAIN, ADMIN_EMAIL, CREDENTIALS_OUTPUT_PATH
#   - 02_lib.sh: log_*, VERIFY_ERRORS

set -euo pipefail


# ── Login-Zusammenfassung ausgeben ────────────────────────────────────────
# Gibt eine formatierte Tabelle mit URLs, Accounts und Passwortquellen für
# alle CIVITAS/CORE-Komponenten aus. Wird am Ende der Installation
# (nach Phase 3) aufgerufen.
login_summary() {
  log ""
  log "================================================================"
  log "  LOGIN SUMMARY — CIVITAS/CORE V1"
  log "================================================================"
  log ""
  log "  Keycloak Admin (idm)"
  log "    URL:      https://idm.${DOMAIN}"
  log "    Account:  ${ADMIN_EMAIL}"
  log "    Passwort: \${ADMIN_PASS} (Umgebungsvariable)"
  log ""
  log "  pgAdmin"
  log "    URL:      https://pgadmin.${DOMAIN}"
  log "    Account:  ${ADMIN_EMAIL}"
  log "    Passwort: ${CREDENTIALS_OUTPUT_PATH} → PGADMIN_PASSWORD"
  log ""
  log "  GeoServer"
  log "    URL:      https://geoportal.${DOMAIN}/geoserver/web/"
  log "    Account:  admin"
  log "    Passwort: ${CREDENTIALS_OUTPUT_PATH} → GEOSERVER_PASSWORD"
  log ""
  log "  Superset"
  log "    URL:      https://superset.${DOMAIN}"
  log "    Account:  admin"
  log "    Passwort: ${CREDENTIALS_OUTPUT_PATH} → SUPERSET_PASSWORD"
  log ""
  log "  Grafana (Operation Stack)"
  log "    URL:      https://monitoring.${DOMAIN}"
  log "    Account:  admin"
  log "    Passwort: ${CREDENTIALS_OUTPUT_PATH} → GRAFANA_PASSWORD"
  log ""
  log "  APISIX Dashboard"
  log "    URL:      https://api-admin.${DOMAIN}"
  log "    Account:  admin@${DOMAIN}"
  log "    Passwort: ${CREDENTIALS_OUTPUT_PATH} → APISIX_DASHBOARD_PASSWORD"
  log "    Hinweis:  Nur aktiv wenn APISIX_DASHBOARD=true"
  log ""
  log "  Portal (Service Portal)"
  log "    URL:      https://${DOMAIN}"
  log "    Login:    Keycloak-SSO (Account oben)"
  log ""
  log "  Credentials-Datei (chmod 600, root-only):"
  log "    ${CREDENTIALS_OUTPUT_PATH}"
  log ""
  log "  Nächste Schritte:"
  log "    1. Bei Keycloak anmelden → Realm ${CC_ENVIRONMENT} wechseln"
  log "    2. Weitere Benutzer anlegen und Rollen zuweisen"
  log "    3. GeoServer-JWT-Filter konfigurieren (falls benötigt)"
  log "================================================================"
  log ""
}

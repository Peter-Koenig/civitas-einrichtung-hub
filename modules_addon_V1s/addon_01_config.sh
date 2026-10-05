#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_01_config.sh — p2d2-AddOn: versionierter Konfigurationsvertrag (V1s)
#
# Seiteneffektfreies Modul. Es definiert ausschliesslich die zentrale
# Validierung der .env.p2d2-addon und wird im Hauptskript nach addon_05_ssh.sh,
# vor allen AddOn-Modulen gesourct, die die Konfiguration lesen.
#
# addon_validate_config wird nur im VM-Kontext nach dem Laden der
# .env.p2d2-addon aufgerufen. Sie schreibt keine Datei und führt keine
# Kubernetes- oder Netzwerkaktion aus.

# addon_normalize_bool <variablenname>
# Normalisiert true|false (Gross-/Kleinschreibung egal) auf Kleinschreibung.
# Leerer oder anderer Wert ist ein Fehler.
addon_normalize_bool() {
  local name="$1" val
  val="${!name:-}"
  case "${val,,}" in
    true)  printf -v "${name}" '%s' 'true'  ;;
    false) printf -v "${name}" '%s' 'false' ;;
    '')
      log_error "addon_normalize_bool: ${name} ist leer (erwartet true|false)"
      return 1
      ;;
    *)
      log_error "addon_normalize_bool: ${name}='${val}' ist ungültig (erwartet true|false)"
      return 1
      ;;
  esac
  return 0
}

# addon_validate_nonempty <name> [allow_empty]
# Leere Werte und Werte mit CHANGEME sind Fehler, ausser allow_empty ist gesetzt.
addon_validate_nonempty() {
  local name="$1" allow_empty="${2:-0}" val
  val="${!name:-}"
  if [[ -z "${val}" ]]; then
    if [[ "${allow_empty}" == "1" ]]; then
      return 0
    fi
    log_error "addon_validate_nonempty: ${name} ist leer"
    return 1
  fi
  if [[ "${val}" == *"CHANGEME"* ]]; then
    log_error "addon_validate_nonempty: ${name} enthält CHANGEME"
    return 1
  fi
  return 0
}

# addon_validate_config
# Zentrale Validierung der .env.p2d2-addon (Konfigurationsvertrag).
addon_validate_config() {
  local key v

  # 1) DOMAIN_NAME: Pflicht, kein CHANGEME, keine Leerzeichen an den Rändern,
  #    nur [A-Za-z0-9.-], nicht mit "udp." beginnend.
  addon_validate_nonempty DOMAIN_NAME || return 1
  if [[ "${DOMAIN_NAME}" =~ ^[[:space:]] || "${DOMAIN_NAME}" =~ [[:space:]]$ ]]; then
    log_error "DOMAIN_NAME darf keine führenden oder folgenden Leerzeichen haben"
    return 1
  fi
  if [[ ! "${DOMAIN_NAME}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    log_error "DOMAIN_NAME enthält unzulässige Zeichen (erlaubt: A-Za-z0-9.-)"
    return 1
  fi
  if [[ "${DOMAIN_NAME}" == udp.* ]]; then
    log_error "DOMAIN_NAME darf nicht mit 'udp.' beginnen"
    return 1
  fi

  # 2) ADDON_DOMAIN: optional. Ist es gesetzt, muss es exakt udp.${DOMAIN_NAME} sein.
  if [[ -n "${ADDON_DOMAIN:-}" && "${ADDON_DOMAIN}" != "udp.${DOMAIN_NAME}" ]]; then
    log_error "ADDON_DOMAIN muss exakt 'udp.${DOMAIN_NAME}' entsprechen (ist: '${ADDON_DOMAIN}'). Leer lassen oder auf den abgeleiteten Wert setzen."
    return 1
  fi

  # 2b) F8: PUBLIC_SITE_URL je Stage muss exakt https://<Präfix>.${ADDON_DOMAIN} sein.
  # Der Host von PUBLIC_WFST_ENDPOINT / PUBLIC_MAPSERVER_URL wird nur als Warnung
  # geprüft (nicht belegt, dass alle Umgebungen geoportal.${ADDON_DOMAIN} nutzen).
  if [[ -n "${ADDON_DOMAIN:-}" ]]; then
    local stage_key site_prefix site_var site_val expected host_var host_val
    for stage_key in MAIN DEVELOP DE1 DE2 FV; do
      case "${stage_key}" in
        MAIN)    site_prefix="www"   ;;
        DEVELOP) site_prefix="dev"   ;;
        DE1)     site_prefix="f-de1" ;;
        DE2)     site_prefix="f-de2" ;;
        FV)      site_prefix="f-fv"  ;;
      esac
      site_var="P2D2_${stage_key}_PUBLIC_SITE_URL"
      site_val="${!site_var:-}"
      expected="https://${site_prefix}.${ADDON_DOMAIN}"
      if [[ -n "${site_val}" && "${site_val}" != "${expected}" ]]; then
        log_error "${site_var} muss exakt '${expected}' entsprechen (ist: '${site_val}')."
        return 1
      fi
    done
    for host_var in P2D2_BASE_PUBLIC_WFST_ENDPOINT P2D2_BASE_PUBLIC_MAPSERVER_URL; do
      host_val="${!host_var:-}"
      if [[ -n "${host_val}" && "${host_val}" != *"geoportal.${ADDON_DOMAIN}"* ]]; then
        log_warn "${host_var} nutzt nicht den Host 'geoportal.${ADDON_DOMAIN}' (Warnung, nicht belegt, dass alle Umgebungen diesen Host nutzen)."
      fi
    done
  fi

  # 3) Schalter (bool): Default false, wenn ungesetzt.
  if [[ ! -v P2D2_DEMO_ACCOUNTS ]]; then P2D2_DEMO_ACCOUNTS="false"; fi
  if [[ ! -v P2D2_OSM_IDP_ENABLE ]]; then P2D2_OSM_IDP_ENABLE="false"; fi
  addon_normalize_bool P2D2_DEMO_ACCOUNTS || return 1
  addon_normalize_bool P2D2_OSM_IDP_ENABLE || return 1

  # 4) Nicht-sensitive Basiswerte (Vorlage, Abschnitt 3).
  for v in \
    P2D2_BASE_APP_DEBUG \
    P2D2_BASE_DEFAULT_CATEGORY_ICON \
    P2D2_BASE_DB_HOST \
    P2D2_BASE_DB_PORT \
    P2D2_BASE_DB_NAME \
    P2D2_BASE_WFST_NAMESPACE \
    P2D2_BASE_PUBLIC_WFST_ENDPOINT \
    P2D2_BASE_PUBLIC_MAPSERVER_URL \
    P2D2_BASE_SMTP_HOST \
    P2D2_BASE_SMTP_PORT \
    P2D2_BASE_SMTP_SECURE \
    P2D2_BASE_SMTP_USER \
    P2D2_BASE_CONTACT_EMAIL_TO \
    P2D2_BASE_CONTACT_EMAIL_FROM; do
    addon_validate_nonempty "${v}" || return 1
  done

  # 5) Nicht-sensitive Stage-Werte (Vorlage, Abschnitt 5).
  for key in MAIN DEVELOP DE1 DE2 FV; do
    for v in \
      "P2D2_${key}_DB_USER" \
      "P2D2_${key}_WFST_WORKSPACE" \
      "P2D2_${key}_PUBLIC_SITE_URL" \
      "P2D2_${key}_WFST_ENDPOINT" \
      "P2D2_${key}_WFST_USERNAME"; do
      addon_validate_nonempty "${v}" || return 1
    done
  done

  # 6) Pflichtsecrets (heutige _preflight_env-Menge) und Stage-Secrets.
  for v in \
    P2D2_BASE_ALTCHA_HMAC_KEY \
    P2D2_BASE_SMTP_PASS \
    P2D2_BASE_OIDC_ISSUER \
    P2D2_DEMO_PASSWORD \
    P2D2_OSM_IDP_CLIENT_ID \
    P2D2_OSM_IDP_CLIENT_SECRET \
    P2D2_GITHUB_TOKEN \
    P2D2_GITLAB_TOKEN; do
    addon_validate_nonempty "${v}" || return 1
  done
  for key in MAIN DEVELOP DE1 DE2 FV; do
    for v in "P2D2_${key}_DB_PASSWORD" "P2D2_${key}_WFST_PASSWORD" "P2D2_${key}_SESSION_SECRET"; do
      addon_validate_nonempty "${v}" || return 1
    done
  done

  log_ok ".env.p2d2-addon validiert (Konfigurationsvertrag)"
  return 0
}

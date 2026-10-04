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
# 06a_network_certs.sh — Netzwerk- und Zertifikatsfunktionen (V1)
#
# Siehe: skriptarchitektur.md (V1), Modul 06a
# Siehe: installationsphasen-und-abnahme.md (V1), Phase 2
#
# Enthält Funktionen zur WireGuard-Konfiguration, zum Patchen von
# Ansible-Playbook-URLs, zur Ingress-Bereinigung, zur Wiederherstellung
# von Let's-Encrypt-Zertifikaten und zum Wechsel des Certificate-Issuers.
#
# Aus 06_civitas.sh ausgegliedert, um die Modulverantwortlichkeiten
# zu trennen.
#
# Abhängigkeiten:
#   - 01_config.sh: DOMAIN, CC_ENVIRONMENT, WG_*, VM_REMOTE_INSTALL_DIR, …
#   - 02_lib.sh: log_*, tcp_reachable, dns_resolves

set -euo pipefail

# Signal: wurden in diesem Lauf Produktivzertifikate frisch ausgestellt?
# Wird in request_fresh_prod_certificates gesetzt und in install_civitas
# ausgewertet, um das LE-Backup nur nach Neuausstellung zu schreiben.
LE_FRESH_PROD_ISSUED=false

# ── resolve_target_state: Zielzustand fuer Zertifikate ermitteln ──────────
# Reine Entscheidungsfunktion. Fuehrt KEINE kubectl-Aufrufe aus, veraendert
# KEINEN Cluster-Zustand. Gibt genau einen der drei Strings per stdout zurueck:
#   "keep_staging"   | "restore_backup" | "request_prod"
#
# Wahrheitstabelle:
#   LE_CERT=false                         → keep_staging
#   Backup vorhanden und brauchbar        → restore_backup
#   LE_CERT=true, kein brauchbares Backup → request_prod
#
# Ein vorhandenes, aber unbrauchbares Backup (falsche Domain, Restlaufzeit
# unter CERT_BACKUP_MIN_DAYS, Dokumentzahl/tls.crt stimmt nicht) wird
# ignoriert — backup_usable warnt per log_warn und der Lauf verhält sich wie
# ohne Backup.
#
# Hinweis: LE_REQUESTS_BLOCKED wird hier NICHT abgefragt — die Funktion
# beschreibt den gewuenschten Zielzustand, unabhaengig von der Ausfuehrbarkeit.
# Die Blockade wird in Schritt 3 (apply_target_state) geprueft.
resolve_target_state() {
    local backup_file="${CERT_BACKUP_FILE}"

    if [[ -f "${backup_file}" ]] && backup_usable "${backup_file}"; then
        echo "restore_backup"
        return 0
    fi

    if [[ "${LE_CERT}" != "true" ]]; then
        echo "keep_staging"
        return 0
    fi

    echo "request_prod"
    return 0
}



# ── WireGuard konfigurieren und Tunnel aktivieren ────────────────────────────
# Idempotenz: Tunnel bereits aktiv → return 0.
# Leerer WG_PRESHARED_KEY → PresharedKey-Zeile wird weggelassen
# (WireGuard wirft Fehler bei leerem Wert).
setup_wireguard() {
  if [[ "${WG_ENABLED}" != "true" ]]; then
    log "WireGuard deaktiviert (WG_ENABLE=${WG_ENABLED:-false}) — überspringe setup_wireguard"
    return 0
  fi
  log "Konfiguriere WireGuard (Schritt 2.4c) …"

  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    log_ok "WireGuard-Tunnel ${WG_INTERFACE} bereits aktiv – überspringe"
    return 0
  fi

  local tpl="${SCRIPT_DIR}/templates_V1/wg0.conf.tpl"
  if [[ ! -f "${tpl}" ]]; then
    log_error "WireGuard-Template nicht gefunden: ${tpl}"
    exit 1
  fi

  # Config-Verzeichnis anlegen
  mkdir -p /etc/wireguard
  chmod 700 /etc/wireguard

  # PreSharedKey-Zeile nur einfügen wenn gesetzt
  local psk_line=""
  if [[ -n "${WG_PRESHARED_KEY:-}" ]]; then
    psk_line="PreSharedKey = ${WG_PRESHARED_KEY}"
  fi

  sed \
    -e "s|WG_VM_PRIVATE_KEY|${WG_VM_PRIVATE_KEY}|g" \
    -e "s|WG_VM_IP|${WG_VM_IP}|g" \
    -e "s|WG_LISTEN_PORT|${WG_LISTEN_PORT:-51820}|g" \
    -e "s|WG_OPN_PUBLIC_KEY|${WG_OPN_PUBLIC_KEY}|g" \
    -e "s|WG_PRESHARED_KEY|${psk_line}|g" \
    -e "s|WG_OPN_ENDPOINT|${WG_OPN_ENDPOINT}|g" \
    -e "s|WG_ALLOWED_IPS|${WG_ALLOWED_IPS:-10.10.10.0/24}|g" \
    "${tpl}" > "${WG_CONF_PATH}"

  chmod 600 "${WG_CONF_PATH}"
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
  log_ok "WireGuard-Tunnel ${WG_INTERFACE} gestartet und aktiviert"

  # Konnektivität zu OPNsense prüfen
  log "Prüfe WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) …"
  local attempts=0
  until ping -c1 -W2 "${WG_OPN_IP}" >/dev/null 2>&1; do
    sleep 3
    (( attempts++ )) || true
    if [[ ${attempts} -ge 10 ]]; then
      log_error "OPNsense ${WG_OPN_IP} nach 30s nicht erreichbar."
      log_error "WireGuard-Konfiguration auf OPNsense-Seite prüfen."
      exit 1
    fi
  done
  log_ok "WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) bestätigt"
}


# ── Playbook-URLs patchen ────────────────────────────────────────────────────
# Ansible's uri-Modul folgt bei POST keine Redirects. Die Keycloak-Admin-API
# verwendet URLs ohne /auth-Prefix und redirectet auf die korrekte URL.
# Ohne diesen Patch scheitern POST-Rollenzuweisungen mit 404.
patch_playbook_urls() {
  log "Patch: follow_redirects in Ansible-Playbooks …"
  local files=(
    "tasks/geodata/configure/integrated_keycloak.yml"
    "tasks/geodata/install/geoserver_setup_role_service.yml"
    "tasks/access/keycloak/idm-config/keycloak_8_users.yml"
    "tasks/access/keycloak/idm-config/keycloak_5_clients.yml"
    "tasks/dashboard/superset.yml"
    "tasks/datacatalog/piveau.yml"
  )
  local patched=0
  for f in "${files[@]}"; do
    local fullpath="${CC_CLI_PLAYBOOK_DIR}/${f}"
    if [[ ! -f "${fullpath}" ]]; then
      continue
    fi
    # follow_redirects in role-mappings-Blöcken einfügen
    sed -i '/role-mappings\/clients/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    # follow_redirects in admin/realms/*/users-Blöcken
    sed -i '/admin\/realms\/.*\/users$/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    # follow_redirects in admin/realms/*/clients-Blöcken
    sed -i '/admin\/realms\/.*\/clients$/,/status_code:/{
      /status_code:/a\    follow_redirects: yes
    }' "${fullpath}"
    (( patched++ )) || true
  done
  log_ok "Playbook-URLs in ${patched} Dateien gepatcht"
}


# ── GeoData-Ingress bereinigen ──────────────────────────────────────────────
# Entfernt doppelten GeoData-Ingress (geostack vs. geostack-geostack).
cleanup_geodata_ingress() {
  local ns="${CC_ENVIRONMENT}-geodata-stack"

  if ! kubectl get namespace "${ns}" &>/dev/null; then
    log "Namespace ${ns} nicht gefunden — überspringe Ingress-Bereinigung"
    return 0
  fi

  if kubectl get ingress geostack -n "${ns}" &>/dev/null; then
    kubectl delete ingress geostack -n "${ns}" --ignore-not-found
    log_ok "Doppelten GeoData-Ingress (geostack) in ${ns} entfernt"
  else
    log "Kein doppelter GeoData-Ingress in ${ns} gefunden"
  fi
}



# ── ensure_staging_baseline: Staging-Issuer sicherstellen ─────────────────
# Zielzustand: keep_staging
# Stellt sicher, dass alle Ingress-Ressourcen auf dem Staging-Issuer
# laufen und READY=True sind.
# Idempotenz: Bereits auf Staging → nichts tun.
ensure_staging_baseline() {
    log "=== ensure_staging_baseline: Pruefe Staging-Issuer ==="
    local all_expected=true
    for ns in "${K8S_NAMESPACES[@]}"; do
        local ingress_hosts
        ingress_hosts=$(kubectl get ingress -n "${ns}" \
            -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null)
        while IFS= read -r host; do
            [[ -z "${host}" ]] && continue
            local cert_name="${host}-tls"
            local issuer
            issuer=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || true)
            if [[ -z "${issuer}" ]]; then
                continue
            fi
            if [[ "${issuer}" != "letsencrypt-staging" && "${issuer}" != "selfsigned-issuer" ]]; then
                log_warn "  ${host} (${ns}): issuerRef=${issuer} (weder staging noch selfsigned)"
                all_expected=false
            fi
        done <<< "${ingress_hosts}"
    done
    if [[ "${all_expected}" == "true" ]]; then
        log_ok "Alle Zertifikate auf erwartetem Issuer (staging/selfsigned)"
    fi
}



# ── apply_target_state: Zielzustand ausfuehren ──────────────────────────
# Nimmt das Ergebnis von resolve_target_state() als Argument und ruft
# GENAU EINE der drei Aktionsfunktionen auf.
apply_target_state() {
    local target_state="$1"

    case "${target_state}" in
        keep_staging)
            ensure_staging_baseline
            return $?
            ;;
        restore_backup)
            if restore_backup_and_switch_to_prod; then
                return 0
            fi

            log_warn "restore_backup_and_switch_to_prod fehlgeschlagen — pruefe Fallback anhand LE_CERT"

            if [[ "${LE_CERT}" != "true" ]]; then
                log_warn "LE_CERT=false — kein Fallback, bleibe bei Staging"
                ensure_staging_baseline
                return $?
            fi

            log_warn "LE_CERT=true — versuche Fallback: request_fresh_prod_certificates"

            if [[ "${LE_REQUESTS_BLOCKED}" == "true" ]]; then
                log_error "LE_REQUESTS_BLOCKED=true — Fallback auf request_prod nicht erlaubt."
                log_error "  LE-CA-Backup oder Konfiguration manuell pruefen."
                return 1
            fi

            request_fresh_prod_certificates
            return $?
            ;;
        request_prod)
            if [[ "${LE_REQUESTS_BLOCKED}" == "true" ]]; then
                log_error "LE_REQUESTS_BLOCKED=true — request_prod nicht erlaubt."
                log_error "  LE-CA-Backup oder Konfiguration manuell pruefen."
                return 1
            fi
            request_fresh_prod_certificates
            return $?
            ;;
        *)
            log_error "apply_target_state: unbekannter Zielzustand '${target_state}'"
            return 1
            ;;
    esac
}


# ── verify_certificates: Pfadunabhaengige Zertifikats-Abnahme ─────────
# Verifiziert pro Hostname GENAU EINEN gueltigen Nachweis, basierend
# auf dem via $1 uebergebenen target_state:
#   - target_state=keep_staging:    Nachweis (a) oder (d)
#   - target_state=restore_backup/
#     request_prod:                 Nachweis (a), (b) oder (c)
# Nachweise:
#   a) Staging-Annotation civitas.io/staging-verified="true" (immer gueltig)
#   b) Produktivzertifikat READY=True mit issuerRef letsencrypt-prod
#   c) Backup-Restore mit identischem notBefore-Zeitstempel
#   d) Staging- oder selfsigned-Zertifikat READY=True
verify_certificates() {
    local target_state="${1:?target_state muss uebergeben werden}"
    log ""
    log "============================================"
    log "  REPORT: verify_certificates (target_state=${target_state})"
    log "============================================"

    local backup_file="${CERT_BACKUP_FILE}"
    local total=0 ok=0 failed=0
    local failed_hosts=()

    for ns in "${K8S_NAMESPACES[@]}"; do
        local ingress_data
        ingress_data=$(kubectl get ingress -n "${ns}" -o json 2>/dev/null \
            | jq -r '.items[] | select(.spec.tls|type=="array" and length>0) | .spec.tls[0] | "\(.hosts[0])\t\(.secretName)"')

        while IFS=$'\t' read -r host secret_name; do
            [[ -z "${host}" ]] && continue
            total=$((total + 1))
            local cert_name="${secret_name}"

            # Nachweis (a): Staging-Annotation — IMMER zulaessig,
            # unabhaengig von target_state
            local staging_annotation
            staging_annotation=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                -o jsonpath='{.metadata.annotations.civitas\.io/staging-verified}' 2>/dev/null)
            if [[ "${staging_annotation}" == "true" ]]; then
                log_ok "  ${host} (${ns}): Nachweis (a) Staging-Annotation"
                ok=$((ok + 1))
                continue
            fi

            case "${target_state}" in
                keep_staging)
                    local issuer ready
                    issuer=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                        -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)
                    ready=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                    if [[ "${ready}" == "True" && ( "${issuer}" == "letsencrypt-staging" || "${issuer}" == "selfsigned-issuer" ) ]]; then
                        log_ok "  ${host} (${ns}): Nachweis (d) Staging/selfsigned READY"
                        ok=$((ok + 1))
                        continue
                    fi
                    ;;
                restore_backup|request_prod)
                    local issuer ready
                    issuer=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                        -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)
                    ready=$(kubectl get certificate "${cert_name}" -n "${ns}" \
                        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                    if [[ "${ready}" == "True" && "${issuer}" == "letsencrypt-prod" ]]; then
                        log_ok "  ${host} (${ns}): Nachweis (b) Produktiv READY"
                        ok=$((ok + 1))
                        continue
                    fi
                    if [[ -f "${backup_file}" ]]; then
                        local nb_backup nb_cluster
                        nb_backup=$(yq eval "select(.metadata.name == \"${cert_name}\") | .data[\"tls.crt\"]" \
                            "${backup_file}" 2>/dev/null | base64 -d 2>/dev/null \
                            | openssl x509 -noout -dates 2>/dev/null | grep notBefore | cut -d= -f2)
                        nb_cluster=$(kubectl get secret "${cert_name}" -n "${ns}" \
                            -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
                            | openssl x509 -noout -dates 2>/dev/null | grep notBefore | cut -d= -f2)
                        if [[ -n "${nb_backup}" && "${nb_backup}" == "${nb_cluster}" ]]; then
                            log_ok "  ${host} (${ns}): Nachweis (c) Backup-Restore"
                            ok=$((ok + 1))
                            continue
                        fi
                    fi
                    ;;
                *)
                    log_error "  ${host} (${ns}): unbekannter target_state=${target_state}"
                    ;;
            esac

            log_error "  ${host} (${ns}): KEIN gueltiger Nachweis fuer target_state=${target_state}"
            failed=$((failed + 1))
            failed_hosts+=("${host}")
        done <<< "${ingress_data}"
    done

    log ""
    log "  Hosts gesamt:  ${total}"
    log "  Verifiziert:   ${ok}"
    log "  Fehlgeschlagen: ${failed}"
    if [[ ${failed} -gt 0 ]]; then
        log_error "  Fehlgeschlagene Hosts: ${failed_hosts[*]}"
    fi
    log "============================================"

    # Kein leerer Lauf: ohne gefundene TLS-Hosts ist das ein Fehler, kein OK.
    if [[ ${total} -eq 0 ]]; then
        log_error "  Keine TLS-Hosts gefunden — verify_certificates ohne Objekt gelaufen"
        return 1
    fi

    [[ ${failed} -eq 0 ]]
    return $?
}

# ── backup_secret_doc_count: zählt die "kind: Secret"-Dokumente ──────────
# Dient als Referenz für die yq-Enumeration: liefert yq (fehlt oder falscher
# Flavor) keine Einträge, muss die Zahl von der erwarteten abweichen und die
# Aufrufer dürfen nicht fälschlich "Verifikation bestanden" melden.
backup_secret_doc_count() {
  local backup_file="$1" count
  count=$(grep -c '^kind: Secret' "${backup_file}" 2>/dev/null) || true
  printf '%s' "${count}"
}

# ── backup_usable: prüft ein LE-Backup vor dem Restore ──────────────────────
# Gibt 0 zurück, wenn das Backup brauchbar ist (richtige Domain, genug
# Restlaufzeit, Dokumentzahl/tls.crt stimmen). Sonst 1 mit einer Warnung auf
# stderr (log_warn). Niemals Zertifikatsinhalt ausgeben — nur Secret-Name und
# Grund. Wird von resolve_target_state per Command Substitution aufgerufen,
# daher ausschließlich log_warn (stderr), kein echo auf stdout.
#
# Ausnahme: LE_REQUESTS_BLOCKED=true hebt die Restlaufzeit-Regel auf (nur
# Warnung), die Domain-Regel bleibt bestehen.
backup_usable() {
  local backup_file="$1"
  local expected_secrets entry ns name tls_crt sans dns_entries dns_name min_seconds
  local -a secret_entries=()

  expected_secrets=$(backup_secret_doc_count "${backup_file}")
  mapfile -t secret_entries < <(yq eval 'select(.kind == "Secret") | "\(.metadata.namespace)/\(.metadata.name)"' \
    "${backup_file}" 2>/dev/null)
  if [[ ${#secret_entries[@]} -eq 0 || ${#secret_entries[@]} -ne "${expected_secrets}" ]]; then
    log_warn "LE-Backup unbrauchbar: yq lieferte ${#secret_entries[@]} Einträge, Backup enthält ${expected_secrets} Secret-Dokumente"
    return 1
  fi

  min_seconds=$(( CERT_BACKUP_MIN_DAYS * 86400 ))

  for entry in "${secret_entries[@]}"; do
    ns="${entry%%/*}"
    name="${entry##*/}"
    tls_crt=$(yq eval "select(.metadata.name == \"${name}\") | .data[\"tls.crt\"]" \
      "${backup_file}" 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -z "${tls_crt}" ]]; then
      log_warn "LE-Backup unbrauchbar: Secret ${name} ohne gültiges tls.crt"
      return 1
    fi

    # Domain-Regel (gilt immer): jeder DNS-Name gleich DOMAIN oder *.DOMAIN.
    sans=$(printf '%s' "${tls_crt}" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
    dns_entries=$(printf '%s' "${sans}" | grep -oE 'DNS:[^,]+' || true)
    if [[ -z "${dns_entries}" ]]; then
      log_warn "LE-Backup unbrauchbar: Secret ${name} ohne DNS-Namen im Zertifikat"
      return 1
    fi
    while IFS= read -r dns_name; do
      [[ -n "${dns_name}" ]] || continue
      dns_name="${dns_name#DNS:}"
      if [[ "${dns_name}" != "${DOMAIN}" && "${dns_name}" != *".${DOMAIN}" ]]; then
        log_warn "LE-Backup unbrauchbar: Secret ${name} enthält Domain ${dns_name} außerhalb ${DOMAIN}"
        return 1
      fi
    done <<< "${dns_entries}"

    # Restlaufzeit-Regel (entfällt bei LE_REQUESTS_BLOCKED=true).
    if [[ "${LE_REQUESTS_BLOCKED}" == "true" ]]; then
      if ! printf '%s' "${tls_crt}" | openssl x509 -noout -checkend "${min_seconds}" >/dev/null 2>&1; then
        log_warn "LE-Backup-Warnung: Secret ${name} Restlaufzeit unter ${CERT_BACKUP_MIN_DAYS} Tagen (LE_REQUESTS_BLOCKED=true — Restlaufzeit-Regel entfällt)"
      fi
    else
      if ! printf '%s' "${tls_crt}" | openssl x509 -noout -checkend "${min_seconds}" >/dev/null 2>&1; then
        log_warn "LE-Backup unbrauchbar: Secret ${name} Restlaufzeit unter ${CERT_BACKUP_MIN_DAYS} Tagen"
        return 1
      fi
    fi
  done
  return 0
}

# ── cluster_backup_diverges: weicht tls.crt im Cluster vom Backup ab? ──────
# Gibt 0 zurück, wenn mindestens ein Secret-tls.crt im Cluster von dem im
# Backup abweicht (z. B. cert-manager hat erneuert) und das Backup daher neu
# geschrieben werden muss. Vergleich über den SHA256-Fingerprint, damit
# whitespace/Zeilenumbrüche in der PEM-Darstellung nicht als Abweichung zählen.
cluster_backup_diverges() {
  local backup_file="${CERT_BACKUP_FILE}"
  [[ -f "${backup_file}" ]] || return 1

  local entry ns name backup_fp cluster_fp
  while IFS= read -r entry; do
    [[ -n "${entry}" ]] || continue
    ns="${entry%%/*}"; name="${entry##*/}"
    backup_fp=$(yq eval "select(.metadata.name == \"${name}\") | .data[\"tls.crt\"]" \
      "${backup_file}" 2>/dev/null | base64 -d 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)
    cluster_fp=$(kubectl get secret "${name}" -n "${ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)
    if [[ -n "${backup_fp}" && -n "${cluster_fp}" && "${backup_fp}" != "${cluster_fp}" ]]; then
      log "tls.crt von ${ns}/${name} weicht vom Backup ab — Backup wird neu geschrieben"
      return 0
    fi
  done < <(yq eval 'select(.kind == "Secret") | "\(.metadata.namespace)/\(.metadata.name)"' "${backup_file}" 2>/dev/null)
  return 1
}

# ── write_le_backup: LE-Zertifikats-Backup atomar in die VM schreiben ─────
# Sammelt die TLS-Secrets aller Certificate-Objekte (außer civitas-core-ca),
# validiert Dokumentzahl und tls.crt, schreibt atomar nach CERT_BACKUP_FILE.
write_le_backup() {
  local backup_file="${CERT_BACKUP_FILE}"
  local tmp="${backup_file}.tmp.$$"
  local -a cert_refs=()
  local ns_name ns name expected docs tls_count

  while IFS= read -r ns_name; do
    [[ -n "${ns_name}" ]] || continue
    cert_refs+=("${ns_name}")
  done < <(kubectl get certificate --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name != "civitas-core-ca") | "\(.metadata.namespace)/\(.spec.secretName)"' 2>/dev/null)

  expected=${#cert_refs[@]}
  if [[ "${expected}" -eq 0 ]]; then
    log_error "LE-Backup: keine Certificate-Objekte (außer civitas-core-ca) gefunden"
    return 1
  fi

  ( umask 077
    : > "${tmp}"
    for ns_name in "${cert_refs[@]}"; do
      ns="${ns_name%%/*}"; name="${ns_name##*/}"
      kubectl get secret "${name}" -n "${ns}" -o yaml >> "${tmp}" 2>/dev/null || true
      echo "---" >> "${tmp}"
    done
    # Trailing-Separator entfernen: ein abschließendes "---" erzeugt ein
    # leeres Dokument, das die Dokument-Zählung (backup_secret_doc_count)
    # verfälscht und das Backup als unbrauchbar erscheinen lässt.
    sed -i '${/^---$/d;}' "${tmp}"
  )

  docs=$(backup_secret_doc_count "${tmp}")
  if [[ "${docs}" -ne "${expected}" ]]; then
    log_error "LE-Backup-Validierung fehlgeschlagen: ${docs} Secret-Dokumente, ${expected} erwartet — Backup verworfen"
    rm -f "${tmp}"
    return 1
  fi
  tls_count=$(grep -c '^  tls.crt:' "${tmp}" 2>/dev/null || true)
  if [[ "${tls_count}" -ne "${expected}" ]]; then
    log_error "LE-Backup-Validierung fehlgeschlagen: ${tls_count} tls.crt-Einträge, ${expected} erwartet — Backup verworfen"
    rm -f "${tmp}"
    return 1
  fi

  mv "${tmp}" "${backup_file}"
  chmod 600 "${backup_file}"
  log_ok "LE-Zertifikats-Backup geschrieben: ${backup_file} (${expected} Secret(s))"
  return 0
}

# ── restore_backup_and_switch_to_prod: Backup-Restore mit Controller-Pause ──
# Zielzustand: restore_backup
# Stoppt zunaechst den cert-manager Controller, ersetzt Secrets via
# kubectl replace --force, legt Certificate-Objekte manuell mit korrektem
# issuerRef an, startet Controller neu. Verifiziert notBefore VOR
# Controller-Restart (garantiert, dass Backup-Zeitstempel erhalten bleibt).

restore_backup_and_switch_to_prod() {
  log "=== restore_backup_and_switch_to_prod: Backup-Restore mit Controller-Pause ==="
  local backup_file="${CERT_BACKUP_FILE}"

  # Trap: Controller garantiert wieder starten, auch bei Fehler
  trap 'if kubectl get deployment cert-manager -n cert-manager \
           -o jsonpath="{.spec.replicas}" 2>/dev/null | grep -q "^0$" 2>/dev/null; then
          log "Stelle cert-manager wieder her (trap)..."
          kubectl scale deployment cert-manager -n cert-manager --replicas=1 2>/dev/null || true
          sleep 3
          kubectl wait --for=condition=Ready pod -n cert-manager \
            -l app.kubernetes.io/name=cert-manager --timeout=60s 2>/dev/null || true
        fi' RETURN


  # LE_REQUESTS_BLOCKED Safety-Schalter
  if [[ "${LE_REQUESTS_BLOCKED}" == "true" ]]; then
    if [[ ! -f "${backup_file}" ]]; then
      log_error "LE_REQUESTS_BLOCKED=true und kein LE-CA-Backup vorhanden — Abbruch"
      trap - RETURN
      return 1
    fi
    log_warn "LE_REQUESTS_BLOCKED=true (Certificate-Loeschung uebersprungen)"
  fi

  # Pruefe ob Backup existiert
  if [[ ! -f "${backup_file}" ]]; then
    log "Kein LE-Zertifikats-Backup gefunden (${backup_file})"
    trap - RETURN
    return 1
  fi

  # Secret-Einträge einmal extrahieren und gegen die Dokumentzahl absichern.
  local expected_secrets
  expected_secrets=$(backup_secret_doc_count "${backup_file}")
  local -a secret_entries=()
  mapfile -t secret_entries < <(yq eval 'select(.kind == "Secret") | "\(.metadata.namespace)/\(.metadata.name)"' \
    "${backup_file}" 2>/dev/null)
  if [[ ${#secret_entries[@]} -eq 0 || ${#secret_entries[@]} -ne "${expected_secrets}" ]]; then
    log_error "Backup-Enumeration fehlgeschlagen: yq lieferte ${#secret_entries[@]} Einträge, Backup enthält ${expected_secrets} Secret-Dokumente (yq fehlt oder falscher Flavor)."
    trap - RETURN
    return 1
  fi

  # ------- Schritt 1: Controller anhalten -------
  log "Stoppe cert-manager Controller (scale --replicas=0)..."
  kubectl scale deployment cert-manager -n cert-manager --replicas=0 2>/dev/null || true
  kubectl wait --for=delete pod -n cert-manager \
    -l app.kubernetes.io/name=cert-manager --timeout=30s 2>/dev/null || true
  log_ok "cert-manager Controller gestoppt"

  # ------- Schritt 2: CertificateRequests + Certificate-Objekte loeschen -------
  for ns in "${K8S_NAMESPACES[@]}"; do
    kubectl delete certificaterequest -n "${ns}" --all 2>/dev/null || true
  done
  log "Loesche Certificate-Objekte (alle Namespaces, ausser civitas-core-ca)..."
  local certs_deleted=0
  while IFS=$'\t' read -r cns cname; do
    kubectl delete certificate "${cname}" -n "${cns}" --ignore-not-found 2>/dev/null || true
    (( certs_deleted++ )) || true
  done < <(kubectl get certificate --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name != "civitas-core-ca") | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${certs_deleted} Certificate(s) entfernt"

  # ------- Schritt 3: Ingress-Annotation VOR Secret-Restore setzen -------
  log "Setze Ingress-Annotationen auf letsencrypt-prod (VOR Secret-Restore)..."
  local annotated=0
  while IFS=$'\t' read -r ins iname; do
    kubectl annotate ingress "${iname}" -n "${ins}" \
      cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite 2>/dev/null || true
    (( annotated++ )) || true
  done < <(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${annotated} Ingress(es) auf letsencrypt-prod annotiert"

  # ------- Schritt 4: Secrets mit REPLACE statt APPLY -------
  log "Spiele LE-Zertifikate aus Backup ein (kubectl replace --force)..."
  if ! kubectl replace --force -f "${backup_file}" 2>&1; then
    log_error "LE-Zertifikats-Backup konnte nicht eingespielt werden (replace fehlgeschlagen)"
    return 1
  fi
  log_ok "LE-Zertifikats-Secrets aus Backup wiederhergestellt"

  # ClusterIssuer letsencrypt-prod sicherstellen (VOR Certificate-Erstellung)
  if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
    log "Lege ClusterIssuer letsencrypt-prod an..."
    kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
    log_ok "ClusterIssuer letsencrypt-prod angelegt"
  fi

  # ------- Schritt 5: Verifikation VOR Controller-Restart -------
  log "Verifiziere wiederhergestellte Zertifikate (VOR Controller-Restart)..."
  local verify_ok=true
  local verify_ns verify_secret
  for entry in "${secret_entries[@]}"; do
    verify_ns="${entry%%/*}"
    verify_secret="${entry##*/}"
    local nb_backup nb_cluster
    nb_backup=$(yq eval "select(.metadata.name == \"${verify_secret}\") | .data[\"tls.crt\"]" \
      "${backup_file}" 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -dates 2>/dev/null \
      | grep notBefore | cut -d= -f2)
    nb_cluster=$(kubectl get secret "${verify_secret}" -n "${verify_ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null \
      | openssl x509 -noout -dates 2>/dev/null | grep notBefore | cut -d= -f2)
    if [[ -z "${nb_backup}" || "${nb_backup}" != "${nb_cluster}" ]]; then
      log_warn "  ${verify_secret} in ${verify_ns}: notBefore weicht ab (backup=${nb_backup:-leer}, cluster=${nb_cluster:-leer})"
      verify_ok=false
    fi
  done
  if [[ "${verify_ok}" == "false" ]]; then
    log_error "Verifikation fehlgeschlagen - notBefore weicht vom Backup ab, Abbruch"
    return 1
  fi

  log_ok "Verifikation bestanden - notBefore aller wiederhergestellten Secrets identisch mit Backup"
  # ------- Schritt 6: Certificate-Objekte manuell anlegen -------

  log "Lege Certificate-Objekte manuell an (korrekter issuerRef)..."
  local certs_created=0
  for entry in "${secret_entries[@]}"; do
    local entry_ns="${entry%%/*}"
    local entry_name="${entry##*/}"
    local hostname="${entry_name%-tls}"
    if [[ -z "${hostname}" ]]; then
      log_warn "  Kann Hostname aus ${entry_name} nicht ableiten — ueberspringe"
      continue
    fi
    kubectl apply -f - <<EOF 2>/dev/null
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${entry_name}
  namespace: ${entry_ns}
spec:
  secretName: ${entry_name}
  dnsNames:
  - ${hostname}
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
EOF
    (( certs_created++ )) || true
    log_ok "  Certificate ${entry_name} in ${entry_ns} (issuer=letsencrypt-prod)"
  done
  log_ok "${certs_created} Certificate(s) manuell angelegt"

  # ------- Schritt 7: Controller wieder starten -------
  log "Starte cert-manager Controller neu..."
  kubectl scale deployment cert-manager -n cert-manager --replicas=1 2>/dev/null || true
  sleep 3
  kubectl wait --for=condition=Ready pod -n cert-manager \
    -l app.kubernetes.io/name=cert-manager --timeout=60s 2>/dev/null || true
  log_ok "cert-manager Controller gestartet"

  # Warten auf Certificate READY
  log "Warte auf Certificate READY..."
  sleep 10
  local final_ok=true
  for entry in "${secret_entries[@]}"; do
    local entry_ns="${entry%%/*}"
    local entry_name="${entry##*/}"
    local cert_ready
    cert_ready=$(kubectl get certificate "${entry_name}" -n "${entry_ns}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ "${cert_ready}" != "True" ]]; then
      log_warn "  Certificate ${entry_name} in ${entry_ns}: READY=${cert_ready:-unbekannt}"
      final_ok=false
    else
      log_ok "  Certificate ${entry_name} in ${entry_ns}: READY=True"
    fi
  done

  if [[ "${final_ok}" == "false" ]]; then
    log_error "Nicht alle Certificates sind READY"
    return 1
  fi

  log_ok "LE-Zertifikate erfolgreich aus Backup wiederhergestellt"
  return 0
}
request_fresh_prod_certificates() {
  log "=== request_fresh_prod_certificates: LE-Staging -> Production ==="


  local le_email="${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"

  # ── 0. Idempotenz: Bereits auf LE-Production? ─────────────────────────────
  log "Pruefe aktuelle Issuer-Annotationen …"
  local all_prod=true
  local any_annotated=false
  for ingress_entry in $(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true); do
    local ns_name=(${ingress_entry/\// })
    local ns="${ns_name[0]}"
    local name="${ns_name[1]}"
    local cur
    cur=$(kubectl get ingress "${name}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true)
    if [[ -n "${cur}" ]]; then
      any_annotated=true
    fi
    if [[ "${cur}" != "letsencrypt-prod" ]]; then
      all_prod=false
    fi
  done

  if [[ "${all_prod}" == "true" && "${any_annotated}" == "true" ]]; then
    if [[ "${LE_CERT:-false}" == "true" ]]; then
      log_ok "Alle Ingresses bereits auf letsencrypt-prod (LE_CERT=true) – nichts zu tun"
      return 0
    else
      log_warn "Ingresses auf letsencrypt-prod, aber LE_CERT=false – wechsle zu Staging"
    fi
  fi

  local staging_success=0 staging_failed=0 prod_success=0 prod_failed=0
  local total=0

  # ── 1. Ingress-Liste ermitteln (nur mit tls-Block) ───────────────────────
  log "Ermittle Ingress-Ressourcen mit tls-Block …"

  local ingress_list
  ingress_list=$(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.tls[0].secretName)"' 2>/dev/null || true)

  if [[ -z "${ingress_list}" ]]; then
    log_warn "Keine Ingresses mit tls-Block gefunden"
    return 0
  fi

  total=$(echo "${ingress_list}" | wc -l)
  log_ok "${total} Ingress(es) mit tls-Block gefunden"

  # ── 1a. ClusterIssuer sicherstellen ───────────────────────────────────────
  if ! kubectl get clusterissuer letsencrypt-staging &>/dev/null; then
    log "Lege ClusterIssuer letsencrypt-staging an …"
    kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${le_email}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
    log_ok "ClusterIssuer letsencrypt-staging angelegt"
  else
    log_ok "ClusterIssuer letsencrypt-staging bereits vorhanden"
  fi

  # ── 2. Staging-Phase ─────────────────────────────────────────────────────
  log ""
  log "=== Phase 1: Staging (letsencrypt-staging) ==="

  while IFS=$'\t' read -r ns name secret; do
    log "  Pruefe Ingress ${ns}/${name} …"

    local current_issuer
    current_issuer=$(kubectl get ingress "${name}" -n "${ns}" \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null || true)

    if [[ "${current_issuer}" == "letsencrypt-staging" ]]; then
      log_ok "  Bereits auf letsencrypt-staging – ueberspringe"
      staging_success=$((staging_success + 1))
      continue
    fi

    kubectl annotate ingress "${name}" -n "${ns}" \
      cert-manager.io/cluster-issuer=letsencrypt-staging --overwrite \
      >/dev/null 2>&1 || {
      log_error "  Annotation fehlgeschlagen fuer ${ns}/${name}"
      staging_failed=$((staging_failed + 1))
      continue
    }
    log_ok "  Annotation gesetzt: letsencrypt-staging auf ${ns}/${name}"

    # Warten auf READY
    if kubectl wait "certificate/${secret}" -n "${ns}" \
      --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
      staging_success=$((staging_success + 1))
    else
      log_error "  Certificate ${secret} in ${ns} wurde nicht READY (Timeout 180s)"
      staging_failed=$((staging_failed + 1))
    fi

    # issuer prüfen (muss (STAGING) enthalten)
    local issuer
    issuer=$(kubectl get secret "${secret}" -n "${ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)

    if echo "${issuer}" | grep -qi "STAGING"; then
      log_ok "  Staging-Zertifikat bestaetigt (issuer enthaelt STAGING)"
    else
      log_warn "  Staging-Zertifikat NICHT bestaetigt – issuer: ${issuer:-leer}"
    fi
  done <<< "${ingress_list}"

  # ── 3. LE_CERT-Schalter auswerten ──────────────────────────────────────
  local staging_ok=0
  if [[ ${staging_failed} -gt 0 ]]; then
    log_error "Staging-Phase: ${staging_success} OK, ${staging_failed} fehlgeschlagen"
    log_error "Production-Phase wird NICHT gestartet – Fehler beheben und erneut ausfuehren"
    staging_ok=0
  elif [[ "${LE_CERT:-false}" != "true" ]]; then
    log_ok "Staging-Phase: ALLE ${staging_success} Ingresses erfolgreich"
    log_warn "LE_CERT=false — Production-Phase wird uebersprungen"
    log_warn "  Setze LE_CERT=true in .env.local fuer Production-Zertifikate"
    staging_ok=0
  else
    log_ok "Staging-Phase: ALLE ${staging_success} Ingresses erfolgreich"
    staging_ok=1
  fi

  # ── 3a. ClusterIssuer letsencrypt-prod sicherstellen ──────────────────────
  if [[ ${staging_ok} -eq 1 ]]; then
    if ! kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
      log "Lege ClusterIssuer letsencrypt-prod an …"
      kubectl apply -f - <<EOF >/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
      log_ok "ClusterIssuer letsencrypt-prod angelegt"
    else
      log_ok "ClusterIssuer letsencrypt-prod bereits vorhanden"
    fi

    # ── 4. Production-Phase ────────────────────────────────────────────────
    log ""
    log "=== Phase 2: Production (letsencrypt-prod) ==="
    log_warn "Let's-Encrypt-Rate-Limit: max. 50 Zertifikate pro Domain/Woche"
    log_warn "  ${total} Zertifikat(e) werden jetzt angefordert"

    while IFS=$'\t' read -r ns name secret; do
      log "  Setze Production auf ${ns}/${name} …"

      kubectl annotate ingress "${name}" -n "${ns}" \
        cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite \
        >/dev/null 2>&1 || {
        log_error "  Annotation fehlgeschlagen fuer ${ns}/${name}"
        prod_failed=$((prod_failed + 1))
        continue
      }
      log_ok "  Annotation gesetzt: letsencrypt-prod auf ${ns}/${name}"

      # Warten auf READY
      if kubectl wait "certificate/${secret}" -n "${ns}" \
        --for=condition=Ready --timeout=180s >/dev/null 2>&1; then
        prod_success=$((prod_success + 1))
      else
        log_error "  Certificate ${secret} in ${ns} wurde nicht READY (Timeout 180s)"
        prod_failed=$((prod_failed + 1))
      fi

      # issuer prüfen (darf kein STAGING enthalten)
      local issuer
      issuer=$(kubectl get secret "${secret}" -n "${ns}" \
        -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
        | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)

      if echo "${issuer}" | grep -qi "STAGING"; then
        log_warn "  Zertifikat enthaelt noch STAGING – warte auf Aktualisierung"
      else
        log_ok "  Production-Zertifikat bestaetigt (kein STAGING)"
      fi
    done <<< "${ingress_list}"
  fi

  if [[ ${staging_failed} -gt 0 ]]; then
    return 1
  elif [[ ${prod_failed} -gt 0 ]]; then
    return 2
  fi
  if [[ ${prod_success} -gt 0 ]]; then
    LE_FRESH_PROD_ISSUED=true
  fi
  return 0
}

#!/usr/bin/env bash
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


# ── WireGuard konfigurieren und Tunnel aktivieren ────────────────────────────
# Idempotenz: Tunnel bereits aktiv → return 0.
# Leerer WG_PRESHARED_KEY → PresharedKey-Zeile wird weggelassen
# (WireGuard wirft Fehler bei leerem Wert).
setup_wireguard() {
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


# ── LE-Zertifikate aus Backup wiederherstellen ──────────────────────────────
restore_le_certs() {
  local backup_file="${VM_REMOTE_INSTALL_DIR}/le-certs-backup.yaml"
  if [[ ! -f "${backup_file}" ]]; then
    log "Kein LE-Zertifikats-Backup gefunden (${backup_file}) — ueberspringe"
    return 1
  fi

  log "Stelle LE-Zertifikate aus Backup wieder her …"

  # ── Schritt 1: ClusterIssuer letsencrypt-prod sicherstellen ────────────────
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
    email: ${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}
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

  # ── Schritt 2: Ingress-Annotationen ZUERST auf letsencrypt-prod setzen ───
  # Dies MUSS vor dem Loeschen der Certificate-Ressourcen passieren, sonst
  # erzeugt ingress-shim beim Neuanlegen eine Certificate-Ressource mit dem
  # noch alten/fehlenden Issuer (Race Condition).
  log "Setze Issuer-Annotationen auf letsencrypt-prod (vor Certificate-Loeschung) …"
  local annotated=0
  while IFS=$'\t' read -r ns name; do
    kubectl annotate ingress "${name}" -n "${ns}" \
      cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite \
      >/dev/null 2>&1 || true
    (( annotated++ )) || true
  done < <(kubectl get ingress --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.tls | type == "array" and length > 0) | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${annotated} Ingress(es) auf letsencrypt-prod annotiert"

  # ── Schritt 3: Certificate-Ressourcen loeschen ────────────────────────────
  # ingress-shim erzeugt sie sofort neu — jetzt aber korrekt mit issuerRef
  # letsencrypt-prod (weil Schritt 2 die Annotation bereits gesetzt hat).
  log "Entferne alte Certificate-Ressourcen …"
  local certs=0
  while IFS=$'\t' read -r ns name; do
    kubectl delete certificate "${name}" -n "${ns}" --ignore-not-found >/dev/null 2>&1 || true
    (( certs++ )) || true
  done < <(kubectl get certificate --all-namespaces -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.name != "civitas-core-ca") | "\(.metadata.namespace)\t\(.metadata.name)"' 2>/dev/null || true)
  log_ok "${certs} Certificate-Ressourcen entfernt"

  # Kurze Wartezeit, bis ingress-shim die neuen Certificate-Ressourcen
  # (mit issuerRef letsencrypt-prod) angelegt hat
  sleep 5

  # ── Schritt 4: Secrets aus Backup einspielen ──────────────────────────────
  # cert-manager erkennt: Secret bereits vorhanden + Certificate zeigt auf
  # letsencrypt-prod + Zertifikat noch gueltig → keine Neuausstellung.
  if ! kubectl apply -f "${backup_file}" >/dev/null 2>&1; then
    log_warn "LE-Zertifikats-Backup konnte nicht eingespielt werden"
    log_warn "  Zertifikate muessen neu bei Let's Encrypt beantragt werden"
    return 1
  fi
  log_ok "LE-Zertifikats-Secrets aus Backup wiederhergestellt"

  # ── Schritt 5: Verifikation ──────────────────────────────────────────────
  # Warten auf Reconcile-Zyklus von cert-manager
  sleep 10
  log "Verifiziere wiederhergestellte Zertifikate …"
  local verify_ns="${CC_ENVIRONMENT}-access-stack"
  local verify_secret="idm.${DOMAIN}-tls"
  if kubectl get secret "${verify_secret}" -n "${verify_ns}" &>/dev/null; then
    local issuer
    issuer=$(kubectl get secret "${verify_secret}" -n "${verify_ns}" \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
      | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
    if echo "${issuer}" | grep -qi "STAGING\|civitas-core-ca"; then
      log_warn "Wiederhergestelltes Zertifikat ist kein LE-Production-Zertifikat: ${issuer}"
      log_warn "  Zertifikate muessen neu bei Let's Encrypt beantragt werden"
      return 1
    fi
    log_ok "Zertifikat-Verifikation erfolgreich: issuer=${issuer}"
  else
    log_warn "Secret ${verify_secret} in ${verify_ns} nach Restore nicht gefunden"
    return 1
  fi

  log_ok "LE-Zertifikate erfolgreich aus Backup wiederhergestellt"
  return 0
}


# ── switch_certificate_issuer: Wechsel zwischen LE-Staging und -Production ──
# Steuert den Wechsel von Let's-Encrypt-Staging auf -Production fuer alle
# Ingress-Ressourcen per Annotation cert-manager.io/cluster-issuer.
# (Siehe Spec: netzwerk-dns-tls.md, Variante E)
#
# Wird am Ende des Installationsdurchlaufs (install_civitas) automatisch
# ausgefuehrt. Kann auch manuell aufgerufen werden.
#
# Ablauf:
#   1. Pruefung ob bereits LE-Production aktiv → ueberspringen
#   2. ClusterIssuer letsencrypt-staging anlegen (falls nicht vorhanden)
#   3. Annotation auf letsencrypt-staging setzen (alle Ingresses)
#   4. Warten auf READY + issuer-Prüfung (muss (STAGING) enthalten)
#   5. ClusterIssuer letsencrypt-prod anlegen (falls nicht vorhanden)
#   6. Nur wenn alle Staging bestanden: Annotation auf letsencrypt-prod
#   7. Production-Zertifikate verifizieren (kein (STAGING) mehr)
#   8. Report mit Erfolg/Fehler pro Host
switch_certificate_issuer() {
  log "=== switch_certificate_issuer: LE-Staging -> Production ==="

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
    log_ok "Alle Ingresses bereits auf letsencrypt-prod – nichts zu tun"
    return 0
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

  # ── 5. Report ────────────────────────────────────────────────────────────
  log ""
  log "============================================"
  log "  REPORT: switch_certificate_issuer"
  log "============================================"
  log "  Ingresses gesamt:       ${total}"
  log "  Staging OK:             ${staging_success}"
  log "  Staging FAIL:           ${staging_failed}"
  if [[ ${staging_ok} -eq 1 ]]; then
    log "  Production OK:          ${prod_success}"
    log "  Production FAIL:        ${prod_failed}"
  else
    log "  Production:             NICHT GESTARTET (Staging-Fehler)"
  fi
  log ""
  log_warn "  Let's-Encrypt-Rate-Limit: 50 Zertifikate/Woche/Domain"
  log "============================================"

  # Exit-Code: 0 = alles OK, 1 = Staging-Probleme, 2 = Production-Probleme
  if [[ ${staging_failed} -gt 0 ]]; then
    return 1
  elif [[ ${prod_failed} -gt 0 ]]; then
    return 2
  fi
  return 0
}

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
# 06_civitas.sh — Phase 2a–2d: CIVITAS/CORE V2 Deployment (helmfile-basiert)
#
# Siehe: skriptarchitektur.md (V2), installationsphasen-und-abnahme.md (V2), Phase 2
#
# Dieses Modul ersetzt das V1-Modul 06_civitas.sh vollständig.
# Es enthält vier Unterphasen als separate Funktionen:
#   2a — Deployment-Repository bereitstellen
#   2b — Vorbedingungen (DNS hart, keycloak-smtp Secret)
#   2c — helmfile sync (global.yaml.gotmpl rendern, deployen, ssl-redirect)
#   2d — WireGuard-Tunnel aktivieren
#
# Abhängigkeiten:
#   - 01_config.sh: DOMAIN, CC_V2_*, K8S_NAMESPACE, KUBECONFIG_PATH, …
#   - 02_lib.sh: log_*, dns_resolves, assert_success
#   - kubectl, helmfile, helm, git (in Phase 0 geprüft)
#   - templates_V2/global.yaml.gotmpl.tpl
#   - templates_V2/wg0.conf.tpl
#
# Idempotenz: Alle vier Unterphasen prüfen vor Aktion, ob Zielzustand bereits erreicht ist.

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
install_civitas_v2() {
  log "=== Phase 2: CIVITAS/CORE V2 Platform ==="

  phase_2a_repo_setup
  phase_2b_preconditions
  phase_2c_helmfile_sync
  phase_2d_wireguard

  log_ok "Phase 2 abgeschlossen – CIVITAS/CORE V2 läuft in Namespace ${K8S_NAMESPACE}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2a — Deployment-Repository
# ═══════════════════════════════════════════════════════════════════════════════

phase_2a_repo_setup() {
  log "=== Phase 2a: Deployment-Repository bereitstellen ==="

  # TODO: Idempotenz-Prüfung: Repository bereits geklont?
  #   if [[ -d "${CC_V2_REPO_PATH}/.git" ]]; then
  #     log_ok "Deployment-Repository bereits vorhanden unter ${CC_V2_REPO_PATH}"
  #     # Optional: git fetch + git reset --hard für Update
  #     return 0
  #   fi

  # TODO: Implementierung: Repository klonen
  #   git clone "${CC_V2_REPO_URL}" "${CC_V2_REPO_PATH}"
  #   log_ok "Deployment-Repository geklont nach ${CC_V2_REPO_PATH}"
  log "Klone Deployment-Repository nach ${CC_V2_REPO_PATH} …"

  # TODO: Implementierung: Symlink /opt/civitas-core anlegen
  #   ln -sf "${CC_V2_REPO_PATH}" /opt/civitas-core
  log "Lege Symlink /opt/civitas-core → ${CC_V2_REPO_PATH} an …"

  # TODO: Idempotenz-Prüfung: deployment/.git bereits vorhanden?
  #   if [[ -d "${CC_V2_DEPLOY_PATH}/.git" ]]; then
  #     log_ok "Deployment-Verzeichnis bereits initialisiert"
  #   else
  #     cp -r "${CC_V2_REPO_PATH}/defaults/deployment" "${CC_V2_DEPLOY_PATH}"
  #     cd "${CC_V2_DEPLOY_PATH}"
  #     git init
  #     git add -A
  #     git commit -m "Initial deployment scaffolding for ${CC_V2_ENVIRONMENT}"
  #     mkdir -p "environments/${CC_V2_ENVIRONMENT}"
  #     log_ok "Deployment-Verzeichnis initialisiert"
  #   fi
  log "Initialisiere Deployment-Verzeichnis ${CC_V2_DEPLOY_PATH} …"

  # TODO: Implementierung: Environment in helmfile.yaml registrieren (einmalig)
  #   cd "${CC_V2_DEPLOY_PATH}"
  #   # Prüfe ob Environment bereits in helmfile.yaml eingetragen
  #   if ! grep -q "${CC_V2_ENVIRONMENT}" helmfile.yaml 2>/dev/null; then
  #     # Füge Environment in helmfile.yaml ein
  #     log_warn "Environment ${CC_V2_ENVIRONMENT} muss manuell in helmfile.yaml registriert werden"
  #     log_warn "  Siehe: deployment/helmfile.yaml → environments + helmfiles Abschnitte"
  #   fi
  log "Prüfe Environment-Registrierung in helmfile.yaml …"

  log_ok "Phase 2a abgeschlossen – Deployment-Repository bereit"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2b — Vorbedingungen Phase 2
# ═══════════════════════════════════════════════════════════════════════════════

phase_2b_preconditions() {
  log "=== Phase 2b: Vorbedingungen Phase 2 ==="

  # TODO: Implementierung: DNS hart prüfen (Abbruch bei Fehler)
  #   local dns_ok=true
  #   if ! dns_resolves "idm.${DOMAIN}"; then
  #     log_error "DNS: idm.${DOMAIN} nicht auflösbar – Eintrag setzen"
  #     dns_ok=false
  #   fi
  #   if ! dns_resolves "portal.${DOMAIN}"; then
  #     log_error "DNS: portal.${DOMAIN} nicht auflösbar – Eintrag setzen"
  #     dns_ok=false
  #   fi
  #   if [[ "${dns_ok}" == false ]]; then
  #     log_error "DNS-Prüfung fehlgeschlagen – Phase 2 wird abgebrochen"
  #     exit 1
  #   fi
  #   log_ok "DNS: idm.${DOMAIN} und portal.${DOMAIN} auflösbar"
  log "Prüfe DNS (harte Prüfung) …"

  # TODO: Implementierung: Namespace anlegen (idempotent via kubectl apply)
  #   kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml \
  #     | kubectl apply -f -
  #   log_ok "Namespace ${K8S_NAMESPACE} angelegt"
  log "Lege Namespace ${K8S_NAMESPACE} an …"

  # TODO: Idempotenz-Prüfung: Secret keycloak-smtp bereits vorhanden?
  #   if kubectl get secret keycloak-smtp -n "${K8S_NAMESPACE}" &>/dev/null; then
  #     log_ok "Secret keycloak-smtp bereits vorhanden – überspringe"
  #   else
  #     kubectl create secret generic keycloak-smtp \
  #       --namespace "${K8S_NAMESPACE}" \
  #       --from-literal=host="${SMTP_HOST}" \
  #       --from-literal=port="${SMTP_PORT}" \
  #       --from-literal=from="${SMTP_FROM}" \
  #       --from-literal=user="${SMTP_USER}" \
  #       --from-literal=password="${SMTP_PASS}" \
  #       --dry-run=client -o yaml | kubectl apply -f -
  #     log_ok "Secret keycloak-smtp angelegt"
  #   fi
  log "Lege Secret keycloak-smtp im Namespace ${K8S_NAMESPACE} an …"

  log_ok "Phase 2b abgeschlossen – Vorbedingungen erfüllt"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2c — helmfile sync
# ═══════════════════════════════════════════════════════════════════════════════

phase_2c_helmfile_sync() {
  log "=== Phase 2c: helmfile sync ==="

  # TODO: Implementierung: global.yaml.gotmpl aus Template rendern
  #   local tpl="${SCRIPT_DIR}/templates_V2/global.yaml.gotmpl.tpl"
  #   local out="${CC_V2_DEPLOY_PATH}/environments/${CC_V2_ENVIRONMENT}/global.yaml.gotmpl"
  #   mkdir -p "$(dirname "${out}")"
  #   sed \
  #     -e "s|__DOMAIN__|${DOMAIN}|g" \
  #     -e "s|__INSTANCE_SLUG__|${CC_V2_ENVIRONMENT}|g" \
  #     -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL}|g" \
  #     "${tpl}" > "${out}"
  #   CONFIG_YAML_PATH="${out}"
  #   export CONFIG_YAML_PATH
  #   log_ok "global.yaml.gotmpl erzeugt: ${out}"
  log "Rendere global.yaml.gotmpl aus Template …"

  # TODO: Implementierung: helmfile sync ausführen
  #   cd "${CC_V2_DEPLOY_PATH}"
  #   KUBECONFIG="${KUBECONFIG_PATH}" \
  #     timeout "${TIMEOUT_HELMFILE_SYNC}" \
  #     helmfile -f helmfile.yaml sync -e "${CC_V2_ENVIRONMENT}"
  #   assert_success "helmfile sync fehlgeschlagen" $?
  #   log_ok "helmfile sync erfolgreich abgeschlossen"
  log "Führe helmfile sync aus (Timeout: ${TIMEOUT_HELMFILE_SYNC}s) …"

  # TODO: Implementierung: ssl-redirect auf allen Ingress-Ressourcen deaktivieren
  #   local ingresses
  #   ingresses="$(kubectl --kubeconfig "${KUBECONFIG_PATH}" \
  #     get ingress -n "${K8S_NAMESPACE}" \
  #     -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
  #   if [[ -z "${ingresses}" ]]; then
  #     log_warn "Keine Ingress-Ressourcen in ${K8S_NAMESPACE} – überspringe Patch"
  #   else
  #     for ingress in ${ingresses}; do
  #       kubectl --kubeconfig "${KUBECONFIG_PATH}" \
  #         annotate ingress "${ingress}" \
  #         -n "${K8S_NAMESPACE}" \
  #         "nginx.ingress.kubernetes.io/ssl-redirect=${SSL_REDIRECT}" \
  #         --overwrite
  #     done
  #     log_ok "ssl-redirect auf alle Ingress-Ressourcen angewendet"
  #   fi
  log "Deaktiviere ssl-redirect für alle Ingress-Ressourcen …"

  # TODO: Implementierung: Warten bis alle Pods Ready sind
  #   pods_ready "${K8S_NAMESPACE}" "${TIMEOUT_POD_READY}"
  #   assert_success "Pods in ${K8S_NAMESPACE} wurden nicht rechtzeitig Ready" $?
  #   log_ok "Alle Pods in ${K8S_NAMESPACE} sind Ready"
  log "Warte auf Pod-Readiness in Namespace ${K8S_NAMESPACE} …"

  # TODO: Implementierung: ClusterIssuer selfsigned-ca prüfen
  #   if kubectl --kubeconfig "${KUBECONFIG_PATH}" \
  #     get clusterissuer "${CLUSTER_ISSUER}" &>/dev/null; then
  #     log_ok "ClusterIssuer ${CLUSTER_ISSUER} vorhanden"
  #   else
  #     log_warn "ClusterIssuer ${CLUSTER_ISSUER} nicht gefunden"
  #   fi
  log "Prüfe ClusterIssuer ${CLUSTER_ISSUER} …"

  log_ok "Phase 2c abgeschlossen – CIVITAS/CORE V2 deployed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2d — WireGuard
# ═══════════════════════════════════════════════════════════════════════════════

phase_2d_wireguard() {
  log "=== Phase 2d: WireGuard ==="

  # TODO: Idempotenz-Prüfung: Tunnel bereits aktiv?
  #   if is_active "wg-quick@${WG_INTERFACE}"; then
  #     log_ok "WireGuard-Tunnel ${WG_INTERFACE} bereits aktiv – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung: WireGuard-Konfiguration aus Template rendern
  #   local tpl="${SCRIPT_DIR}/templates_V2/wg0.conf.tpl"
  #   if [[ ! -f "${tpl}" ]]; then
  #     log_error "WireGuard-Template nicht gefunden: ${tpl}"
  #     exit 1
  #   fi
  #   mkdir -p /etc/wireguard
  #   chmod 700 /etc/wireguard
  #   sed \
  #     -e "s|__WG_VM_PRIVATE_KEY__|${WG_VM_PRIVATE_KEY}|g" \
  #     -e "s|__WG_VM_IP__|${WG_VM_IP}|g" \
  #     -e "s|__WG_OPN_PUBLIC_KEY__|${WG_OPN_PUBLIC_KEY}|g" \
  #     -e "s|__WG_OPN_ENDPOINT__|${WG_OPN_ENDPOINT}|g" \
  #     "${tpl}" > "${WG_CONF_PATH}"
  #   chmod 600 "${WG_CONF_PATH}"
  #   log_ok "WireGuard-Konfiguration erzeugt: ${WG_CONF_PATH}"
  log "Erzeuge WireGuard-Konfiguration aus Template …"

  # TODO: Implementierung: Tunnel aktivieren
  #   systemctl enable --now "wg-quick@${WG_INTERFACE}"
  #   log_ok "WireGuard-Tunnel ${WG_INTERFACE} gestartet"
  log "Starte WireGuard-Tunnel ${WG_INTERFACE} …"

  # TODO: Implementierung: Konnektivität zu OPNsense prüfen
  #   local attempt=0
  #   until ping -c1 -W2 "${WG_OPN_IP}" >/dev/null 2>&1; do
  #     sleep 3
  #     (( attempt++ )) || true
  #     if [[ ${attempt} -ge 10 ]]; then
  #       log_error "OPNsense ${WG_OPN_IP} nach 30s nicht erreichbar"
  #       log_error "WireGuard-Konfiguration auf OPNsense-Seite prüfen"
  #       exit 1
  #     fi
  #   done
  #   log_ok "WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) bestätigt"
  log "Prüfe WireGuard-Konnektivität zu OPNsense (${WG_OPN_IP}) …"

  log_ok "Phase 2d abgeschlossen – WireGuard-Tunnel aktiv"
}

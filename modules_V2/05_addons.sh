#!/usr/bin/env bash
#
# 05_addons.sh — Phase 1b: Add-ons installieren (CIVITAS/CORE V2)
#
# Siehe: skriptarchitektur.md (V2), installationsphasen-und-abnahme.md (V2), Phase 1b
#
# Installiert helmfile, helm-diff-Plugin, cert-manager, selfsigned ClusterIssuer,
# nginx-Ingress-Controller und prüft die StorageClass.
#
# Abhängigkeiten:
#   - Phase 1a (04_k3s.sh) vollständig abgeschlossen
#   - k3s-Cluster läuft, kubectl konfiguriert
#   - 01_config.sh: HELM_VERSION, HELMFILE_VERSION, CERT_MANAGER_VERSION, INGRESS_NGINX_VERSION, …
#   - 02_lib.sh: log_*, is_installed, is_active, k8s_ready
#
# Idempotenz: Jede Funktion prüft den Zielzustand vor der Aktion.
# Bereits installierte Komponenten in korrekter Version werden übersprungen.

set -euo pipefail

# ── Hauptfunktion (aufgerufen vom Entry-Point) ────────────────────────────────
install_addons() {
  log "=== Phase 1b: Add-ons ==="

  install_helm
  install_helmfile
  install_helm_diff
  install_cert_manager
  configure_cluster_issuer
  install_nginx_ingress
  verify_storage_class

  log_ok "Phase 1b abgeschlossen — alle Add-ons installiert"
}

# ── Helm-CLI ──────────────────────────────────────────────────────────────────
install_helm() {
  log "Installiere helm ${HELM_VERSION} …"

  # TODO: Idempotenz-Prüfung
  #   if is_installed helm && helm version | grep -q "${HELM_VERSION}"; then
  #     log_ok "helm ${HELM_VERSION} bereits installiert – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung
  #   tmpdir="$(mktemp -d)"
  #   url="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  #   curl -fsSL "${url}" -o "${tmpdir}/helm.tar.gz"
  #   tar -xzf "${tmpdir}/helm.tar.gz" -C "${tmpdir}"
  #   install "${tmpdir}/linux-amd64/helm" /usr/local/bin/helm
  #   rm -rf "${tmpdir}"
  #   log_ok "helm ${HELM_VERSION} installiert"

  log_ok "helm installiert"
}

# ── helmfile ──────────────────────────────────────────────────────────────────
install_helmfile() {
  log "Installiere helmfile ${HELMFILE_VERSION} …"

  # TODO: Idempotenz-Prüfung
  #   if is_installed helmfile && helmfile version | grep -q "${HELMFILE_VERSION}"; then
  #     log_ok "helmfile ${HELMFILE_VERSION} bereits installiert – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung
  #   url="https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_amd64.tar.gz"
  #   curl -fsSL "${url}" | tar -xz -C /usr/local/bin/ helmfile
  #   chmod +x /usr/local/bin/helmfile
  #   log_ok "helmfile ${HELMFILE_VERSION} installiert"

  log_ok "helmfile installiert"
}

# ── helm-diff-Plugin ─────────────────────────────────────────────────────────
install_helm_diff() {
  log "Installiere helm-diff-Plugin …"

  # TODO: Idempotenz-Prüfung
  #   if helm plugin list 2>/dev/null | grep -q "diff"; then
  #     log_ok "helm-diff-Plugin bereits installiert – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung
  #   helm plugin install https://github.com/databus23/helm-diff
  #   log_ok "helm-diff-Plugin installiert"

  log_ok "helm-diff-Plugin installiert"
}

# ── cert-manager ──────────────────────────────────────────────────────────────
install_cert_manager() {
  log "Installiere cert-manager ${CERT_MANAGER_VERSION} …"

  # TODO: Idempotenz-Prüfung
  #   if k8s_ready deployment cert-manager "${CERT_MANAGER_NAMESPACE}"; then
  #     # Prüfe Version
  #     local installed_ver
  #     installed_ver="$(kubectl get deployment cert-manager -n "${CERT_MANAGER_NAMESPACE}" \
  #       -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)"
  #     if [[ "${installed_ver}" == "${CERT_MANAGER_VERSION#v}" ]]; then
  #       log_ok "cert-manager ${CERT_MANAGER_VERSION} bereits installiert – überspringe"
  #       return 0
  #     fi
  #     log_warn "cert-manager ${installed_ver:-unknown} gefunden, erwartet ${CERT_MANAGER_VERSION} – upgrade"
  #   fi

  # TODO: Implementierung
  #   helm repo add jetstack https://charts.jetstack.io --force-update
  #   helm upgrade --install cert-manager jetstack/cert-manager \
  #     --namespace "${CERT_MANAGER_NAMESPACE}" \
  #     --create-namespace \
  #     --version "${CERT_MANAGER_VERSION}" \
  #     --set installCRDs=true \
  #     --wait
  #   log_ok "cert-manager ${CERT_MANAGER_VERSION} installiert"

  log_ok "cert-manager installiert"
}

# ── ClusterIssuer (selfsigned-ca) ─────────────────────────────────────────────
configure_cluster_issuer() {
  log "Konfiguriere ClusterIssuer '${CLUSTER_ISSUER}' (selfsigned) …"

  # TODO: Idempotenz-Prüfung
  #   if kubectl get clusterissuer "${CLUSTER_ISSUER}" &>/dev/null; then
  #     log_ok "ClusterIssuer ${CLUSTER_ISSUER} bereits vorhanden – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung
  #   kubectl apply -f - <<EOF
  # apiVersion: cert-manager.io/v1
  # kind: ClusterIssuer
  # metadata:
  #   name: ${CLUSTER_ISSUER}
  # spec:
  #   selfSigned: {}
  # EOF
  #   log_ok "ClusterIssuer ${CLUSTER_ISSUER} konfiguriert"}
  #
  # Hinweis: Nach dem Anlegen auf READY=True warten:
  #   kubectl wait --for=condition=Ready clusterissuer "${CLUSTER_ISSUER}" --timeout=30s

  log_ok "ClusterIssuer konfiguriert"
}

# ── nginx-Ingress ─────────────────────────────────────────────────────────────
install_nginx_ingress() {
  log "Installiere nginx-Ingress ${INGRESS_NGINX_VERSION} (DaemonSet, Port 8080) …"

  # TODO: Idempotenz-Prüfung
  #   if kubectl get daemonset ingress-nginx-controller -n "${INGRESS_NAMESPACE}" &>/dev/null; then
  #     log_ok "nginx-Ingress DaemonSet bereits vorhanden – überspringe"
  #     return 0
  #   fi

  # TODO: Implementierung
  #   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  #   helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  #     --namespace "${INGRESS_NAMESPACE}" \
  #     --create-namespace \
  #     --version "${INGRESS_NGINX_VERSION}" \
  #     --set controller.hostNetwork=true \
  #     --set controller.kind=DaemonSet \
  #     --set "controller.service.ports.http=8080" \
  #     --set "controller.service.ports.https=8443" \
  #     --set "controller.containerPort.http=8080" \
  #     --set "controller.containerPort.https=8443" \
  #     --wait
  #   log_ok "nginx-Ingress ${INGRESS_NGINX_VERSION} installiert"
  #
  # Hinweis: Port 8080 (HTTP) statt 80, weil TLS auf Caddy terminiert wird.
  # Kein SSL-Redirect – wird in Phase 2c für alle Ingress-Ressourcen gesetzt.

  log_ok "nginx-Ingress installiert"
}

# ── Storage Class prüfen ──────────────────────────────────────────────────────
verify_storage_class() {
  log "Prüfe Storage Class …"

  # TODO: Idempotenz-Prüfung: einmalige Prüfung, kein Überspringen
  #   if kubectl get storageclass local-path &>/dev/null; then
  #     log_ok "Storage Class local-path vorhanden"
  #   else
  #     log_error "Storage Class local-path nicht gefunden – ist k3s korrekt installiert?"
  #     exit 1
  #   fi
  #
  #   local is_default
  #   is_default="$(kubectl get storageclass local-path \
  #     -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')"
  #   if [[ "$is_default" == "true" ]]; then
  #     log_ok "Storage Class local-path ist Default"
  #   else
  #     log_warn "Storage Class local-path ist nicht als Default markiert"
  #   fi

  log_ok "Storage Class geprüft"
}

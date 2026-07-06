#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Modul 05 — Add-ons (Phase 1b)
# Installiert helm-CLI, cert-manager, ClusterIssuer, nginx-Ingress.
# Prüft Storage Class (local-path, von k3s mitgeliefert).
# ──────────────────────────────────────────────────────────────────────────────

install_addons() {
  log "=== Phase 1b: Add-ons ==="

  install_helm
  install_gateway_api_crds
  install_cert_manager

  # Warten bis cert-manager-Webhook Ready ist, sonst Race-Condition bei CRDs
  log "Warte auf cert-manager-Webhook ..."
  kubectl wait pods --all -n "${CERT_MANAGER_NAMESPACE}" \
    --for=condition=Ready --timeout=120s
  log_ok "cert-manager Webhook Ready"

  configure_cluster_issuer    # zweistufig, Java-kompatibel
  setup_ca_trust              # CA in System-Store + certifi (vor nginx)

  install_nginx_ingress
  verify_storage_class
}

# ── Helm-CLI ──────────────────────────────────────────────────────────────────
install_helm() {
  log "Installiere helm-CLI ${HELM_VERSION} ..."

  if is_installed helm && helm version | grep -q "${HELM_VERSION}"; then
    log_ok "helm ${HELM_VERSION} bereits installiert"
    return 0
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  local url="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"

  curl -fsSL "${url}" -o "${tmpdir}/helm.tar.gz"
  tar -xzf "${tmpdir}/helm.tar.gz" -C "${tmpdir}"
  install "${tmpdir}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${tmpdir}"

  log_ok "helm ${HELM_VERSION} installiert"
}

# ── Gateway API CRDs ──────────────────────────────────────────────────────────
install_gateway_api_crds() {
  log "Installiere Kubernetes Gateway API CRDs (${GATEWAY_API_VERSION}) …"

  if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
    log_ok "Gateway API CRDs bereits installiert"
    return 0
  fi

  kubectl apply -f \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

  local waited=0
  until kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; do
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge 30 ]]; then
      log_error "Gateway-API-CRDs nicht nach 30s registriert"
      exit 1
    fi
  done
  log_ok "Gateway API CRDs installiert (${GATEWAY_API_VERSION})"
}

# ── cert-manager ──────────────────────────────────────────────────────────────
install_cert_manager() {
  log "Installiere cert-manager ${CERT_MANAGER_VERSION} ..."

  if k8s_ready deployment cert-manager "${CERT_MANAGER_NAMESPACE}"; then
    log_ok "cert-manager bereits installiert"
    return 0
  fi

  helm repo add jetstack https://charts.jetstack.io --force-update

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace "${CERT_MANAGER_NAMESPACE}" \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set installCRDs=true \
    --set config.enableGatewayAPI=true \
    --wait

  log_ok "cert-manager ${CERT_MANAGER_VERSION} installiert"
}

# ── ClusterIssuer (zweistufig, Java-kompatibel) ───────────────────────────────
configure_cluster_issuer() {
  log "Konfiguriere zweistufigen CA-Issuer (Java-kompatibel) ..."

  # --- Stufe 1: Bootstrap-Issuer (nur zum CA-Cert-Ausstellen) ---
  if ! kubectl get clusterissuer civitas-bootstrap-selfsigned &>/dev/null; then
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: civitas-bootstrap-selfsigned
spec:
  selfSigned: {}
EOF
    log_ok "Bootstrap-ClusterIssuer angelegt"
  else
    log_ok "Bootstrap-ClusterIssuer bereits vorhanden"
  fi

  # --- Stufe 2: Root-CA-Certificate mit nicht-leerem Subject ---
  if ! kubectl get certificate civitas-core-ca -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null; then
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: civitas-core-ca
  namespace: ${CERT_MANAGER_NAMESPACE}
spec:
  isCA: true
  commonName: "civitas-core-ca"
  subject:
    organizations: ["civitas-core"]
    countries: ["DE"]
  secretName: civitas-core-ca-secret
  privateKey:
    algorithm: RSA
    size: 4096
  duration: 87600h
  issuerRef:
    name: civitas-bootstrap-selfsigned
    kind: ClusterIssuer
    group: cert-manager.io
EOF
    log_ok "Root-CA-Certificate angelegt"
  else
    log_ok "Root-CA-Certificate bereits vorhanden"
  fi

  # Warten bis CA-Secret ausgestellt ist
  log "Warte auf CA-Secret civitas-core-ca-secret ..."
  local waited=0
  until kubectl get secret civitas-core-ca-secret -n "${CERT_MANAGER_NAMESPACE}" &>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if [[ $waited -gt 120 ]]; then
      log_error "CA-Secret nicht bereit nach 120s"
      exit 1
    fi
  done
  log_ok "CA-Secret vorhanden nach ${waited}s"

  # --- Stufe 3: Produktiver ClusterIssuer (Name selfsigned-issuer bleibt!) ---
  local existing_type
  existing_type=$(kubectl get clusterissuer selfsigned-issuer \
    -o jsonpath='{.spec}' 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('ca' if 'ca' in d else 'selfSigned')" 2>/dev/null || echo "missing")

  case "$existing_type" in
    ca)
      log_ok "ClusterIssuer selfsigned-issuer bereits korrekt (CA-Typ)"
      ;;
    selfSigned)
      log_warn "ClusterIssuer selfsigned-issuer ist selfSigned-Typ — ersetze durch CA-Typ"
      kubectl delete clusterissuer selfsigned-issuer
      ;&  # fallthrough
    missing)
      kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  ca:
    secretName: civitas-core-ca-secret
EOF
      log_ok "ClusterIssuer selfsigned-issuer (CA-Typ) angelegt"
      ;;
  esac

  # Abnahme: READY=True
  kubectl wait clusterissuer/selfsigned-issuer \
    --for=condition=Ready --timeout=60s \
    && log_ok "ClusterIssuer selfsigned-issuer READY" \
    || { log_error "ClusterIssuer selfsigned-issuer nicht READY"; exit 1; }
}

# ── CA-Trust (System-Store + certifi) ─────────────────────────────────────────
setup_ca_trust() {
  log "Phase 1.5d: CA-Trust in System-Store und certifi einrichten ..."

  local ca_cert_local="/usr/local/share/ca-certificates/civitas-core-ca.crt"
  local certifi_bundle=""
  if [[ -d "${CC_CLI_VENV_PATH}" ]]; then
    certifi_bundle=$(find "${CC_CLI_VENV_PATH}" -name "cacert.pem" 2>/dev/null | head -1)
  fi

  # CA-Cert aus Secret extrahieren
  mkdir -p "$(dirname "${ca_cert_local}")"
  kubectl get secret civitas-core-ca-secret \
    -n "${CERT_MANAGER_NAMESPACE}" \
    -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${ca_cert_local}" \
    || { log_error "CA-Cert aus Secret konnte nicht extrahiert werden"; exit 1; }

  # Issuer-DN-Validierung — darf nicht leer sein
  local issuer
  issuer=$(openssl x509 -in "${ca_cert_local}" -noout -issuer 2>/dev/null || echo "")
  if echo "$issuer" | grep -q "CN="; then
    log_ok "CA-Zertifikat Issuer-DN: $issuer"
  else
    log_error "CA-Zertifikat hat leeren Issuer-DN — Abbruch"
    log_error "openssl output: $issuer"
    exit 1
  fi

  # System-Trust-Store
  update-ca-certificates
  log_ok "System-Trust-Store aktualisiert"

  # certifi im venv — Ansible nutzt diesen Bundle, nicht den System-Store
  if [[ -n "${certifi_bundle}" ]]; then
    if ! grep -q "civitas-core-ca" "${certifi_bundle}"; then
      cat "${ca_cert_local}" >> "${certifi_bundle}"
      log_ok "CA zu certifi-Bundle hinzugefuegt: ${certifi_bundle}"
    else
      log_ok "CA bereits im certifi-Bundle vorhanden"
    fi
  else
    log_warn "certifi cacert.pem nicht gefunden in ${CC_CLI_VENV_PATH}"
    log_warn "cc_cli exec koennte mit CERTIFICATE_VERIFY_FAILED scheitern"
  fi
}

# ── nginx-Ingress ─────────────────────────────────────────────────────────────
install_nginx_ingress() {
  log "Installiere nginx-Ingress ${NGINX_INGRESS_VERSION} ..."

  if kubectl get daemonset ingress-nginx-controller -n "${INGRESS_NAMESPACE}" &>/dev/null; then
    log_ok "nginx-Ingress DaemonSet bereits vorhanden — überspringe"
    return 0
  fi

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update

  local values_file
  values_file="$(mktemp)"

  cat > "${values_file}" << 'EOF'
controller:
  hostNetwork: true
  kind: DaemonSet
  service:
    enabled: false
EOF

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --create-namespace \
    --version "${NGINX_INGRESS_VERSION}" \
    -f "${values_file}" \
    --wait \
    --timeout 600s

  rm -f "${values_file}"
  log_ok "nginx-Ingress ${NGINX_INGRESS_VERSION} installiert"
}

# ── Storage Class prüfen ──────────────────────────────────────────────────────
verify_storage_class() {
  log "Prüfe Storage Class ..."

  if kubectl get storageclass local-path &>/dev/null; then
    log_ok "Storage Class local-path vorhanden"
  else
    log_error "Storage Class local-path nicht gefunden — ist k3s korrekt installiert?"
    exit 1
  fi

  local is_default
  is_default="$(kubectl get storageclass local-path \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}')"
  if [[ "$is_default" == "true" ]]; then
    log_ok "Storage Class local-path ist Default"
  else
    log_warn "Storage Class local-path ist nicht als Default markiert"
  fi
}

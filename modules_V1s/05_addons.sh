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
  install_cico_utils          # cico-shutdown / cico-uncordon

  install_prometheus_operator_crds   # CRDs vor cc_cli exec (APISIX ServiceMonitor)

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

# ── Prometheus-Operator CRDs ──────────────────────────────────────────────────
install_prometheus_operator_crds() {
  log "Installiere Prometheus-Operator-CRDs (v0.89.0) …"

  if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    log_ok "Prometheus-Operator-CRDs bereits installiert"
    return 0
  fi

  kubectl apply --server-side -f \
    "https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.89.0/stripped-down-crds.yaml" \
    || { log_error "Prometheus-Operator-CRDs Installation fehlgeschlagen"; exit 1; }

  local waited=0
  until kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; do
    sleep 3
    waited=$((waited + 3))
    if [[ $waited -ge 30 ]]; then
      log_error "ServiceMonitor-CRD nicht nach 30s registriert"
      exit 1
    fi
  done
  log_ok "Prometheus-Operator-CRDs installiert (v0.89.0)"
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

  # ── ISRG Root X1 (öffentliche LE-Root für externe Zertifikate) ──────────
  # ca_path im Inventory zeigt auf diese Datei. Die Datei wurde unmittelbar
  # zuvor mit `>` aus dem Kubernetes-Secret überschrieben und enthält daher
  # garantiert nur die interne CA — ein Idempotenz-Check via openssl ist
  # strukturell nicht möglich. Der Download läuft bei jedem Durchlauf; bei
  # Fehlschlag wird die finale Verifikation am Funktionsende zuschlagen.
  local le_root_url="https://letsencrypt.org/certs/isrgrootx1.pem"
  if curl -fsSL "${le_root_url}" >> "${ca_cert_local}"; then
    log_ok "ISRG Root X1 ergänzt in ${ca_cert_local}"
  else
    log_warn "ISRG Root X1 konnte nicht heruntergeladen werden — ${le_root_url}"
    log_warn "  CA-Bundle enthält nur die interne CA — cc_cli exec wird später scheitern"
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

  # ── Finale Verifikation: CA-Bundle muss beide Trust-Anker enthalten ────
  # Die Datei wurde zu Beginn mit der internen CA überschrieben (Schritt 1)
  # und im ISRG-Block (Schritt 2) um die LE-Root ergänzt. Fehlt die LE-Root
  # (Download-Fehler, abgebrochener Lauf), enthält die Datei nur 1 Zertifikat.
  local cert_count
  cert_count=$(grep -c "BEGIN CERTIFICATE" "${ca_cert_local}" 2>/dev/null || echo 0)
  if [[ "${cert_count}" -lt 2 ]]; then
    log_error "CA-Bundle enthält nur ${cert_count} Zertifikat(e) (erwartet ≥ 2)"
    log_error "  ISRG Root X1 fehlt — cc_cli exec wird mit CERTIFICATE_VERIFY_FAILED scheitern"
    exit 1
  fi
  log_ok "CA-Bundle enthält ${cert_count} Zertifikat(e) — beide Trust-Anker vorhanden"
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


# ── CIVITAS/CORE-Shutdown und -Uncordon (cico-utils) ─────────────────────────
# Installiert die Skripte cico-shutdown und cico-uncordon nach /usr/local/bin
# und aktiviert den systemd-Dienst cico-uncordon.service für automatisches
# Uncordon nach k3s-Neustart.
install_cico_utils() {
  log "Installiere CIVITAS/CORE-Shutdown-Utilities …"

  # ── cico-shutdown ──────────────────────────────────────────────────────
  if [[ ! -f /usr/local/bin/cico-shutdown ]]; then
    cat > /usr/local/bin/cico-shutdown << 'CICO_SCRIPT'
#!/usr/bin/env bash
#
# cico-shutdown — CIVITAS/CORE VM sauber herunterfahren
#
# Fuehrt einen ordentlichen Shutdown der CIVITAS/CORE-VM durch:
#   1. kubectl drain (Node cordon + Pod-Eviction)
#   2. Warten auf Pod-Terminierung (polling loop mit Timeout)
#   3. Force-Cleanup verbleibender Pods (VOR dem k3s-Stop!)
#   4. k3s-Dienst stoppen
#   5. sync + shutdown -h now
#
# Aufruf:
#   cico-shutdown                     # normaler Shutdown
#   TIMEOUT=300 cico-shutdown         # laengerer Timeout (Default: 300s)
#   K3S_NODE=civitas-core-v1s cico-shutdown  # Node-Name explizit erzwingen
#
# WICHTIG: K3S_NODE wird per Default aus "hostname" ermittelt, NICHT mehr
# hart codiert. Nach jeder Umbenennung der VM (z.B. civitas-core ->
# civitas-core-v1s) muss der Node-Name zur Laufzeit stimmen, sonst
# drained das Skript ein veraltetes/falsches Node-Objekt und die
# tatsaechlich laufenden Pods werden nie evictiert (siehe Vorfall
# 2026-08-31: doppeltes Node-Objekt nach Hostname-Wechsel, dadurch
# Zombie-Pods nach hartem k3s-Stop).
#
# Siehe: installationsphasen-und-abnahme.md, Abschnitt "CIVITAS/CORE-Shutdown"

set -euo pipefail

K3S_NODE="${K3S_NODE:-$(hostname)}"
TIMEOUT="${TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

echo "[cico-shutdown] === CIVITAS/CORE VM — Sauberer Shutdown ==="
echo "[cico-shutdown] Node:     ${K3S_NODE}"
echo "[cico-shutdown] Timeout:  ${TIMEOUT}s"
echo ""

# Sicherheitscheck: existiert der ermittelte Node im Cluster ueberhaupt?
if ! kubectl get node "${K3S_NODE}" >/dev/null 2>&1; then
  echo "[cico-shutdown] FEHLER: Node '${K3S_NODE}' nicht im Cluster gefunden."
  echo "[cico-shutdown] Verfuegbare Nodes:"
  kubectl get nodes -o wide || true
  echo "[cico-shutdown] Bitte K3S_NODE explizit setzen, z.B.:"
  echo "[cico-shutdown]   K3S_NODE=<richtiger-name> cico-shutdown"
  exit 1
fi

# Hinweis auf veraltete/zusaetzliche Node-Objekte (z.B. nach Hostname-Wechsel)
other_nodes=$(kubectl get nodes -o name | grep -v "node/${K3S_NODE}$" || true)
if [[ -n "${other_nodes}" ]]; then
  echo "[cico-shutdown] WARN: Weitere Node-Objekte im Cluster vorhanden:"
  echo "${other_nodes}"
  echo "[cico-shutdown] WARN: Ggf. veraltete Node-Objekte nach einem frueheren"
  echo "[cico-shutdown]       Hostname-Wechsel manuell pruefen (kubectl delete node <name>)."
fi

# Schritt 1: Node drainen
echo "[cico-shutdown] Drain node ${K3S_NODE} ..."
kubectl drain "${K3S_NODE}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --disable-eviction \
  --timeout="${TIMEOUT}s" 2>&1 || \
  echo "[cico-shutdown] WARN: drain beendet (moeglicherweise nicht vollstaendig)"

# Schritt 2: Warten bis alle Pods terminiert sind
echo "[cico-shutdown] Warte auf Pod-Terminierung (max. ${TIMEOUT}s) ..."
elapsed=0
while true; do
  local_pods=$(kubectl get pods -A \
    --field-selector="spec.nodeName=${K3S_NODE}" \
    -o name 2>/dev/null | wc -l)

  if [[ "${local_pods}" -eq 0 ]]; then
    echo "[cico-shutdown] Alle Pods terminiert (nach ${elapsed}s)."
    break
  fi

  if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
    echo "[cico-shutdown] WARN: Timeout ${TIMEOUT}s erreicht — ${local_pods} Pod(s) noch aktiv"
    kubectl get pods -A --field-selector="spec.nodeName=${K3S_NODE}" -o wide 2>/dev/null || true
    break
  fi

  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

# Schritt 3: Force-Cleanup verbleibender Pods (VOR dem k3s-Stop!)
#
# Wenn nach dem Timeout noch Pods aktiv sind, muessen sie hart geloescht
# werden, SOLANGE Kubelet/API-Server noch laufen. Sonst bleiben sie mit
# gesetztem deletionTimestamp in etcd stehen und blockieren nach dem
# naechsten Boot die Neuerstellung (v.a. StatefulSets mit PVC).
remaining=$(kubectl get pods -A \
  --field-selector="spec.nodeName=${K3S_NODE}" \
  -o name 2>/dev/null || true)

if [[ -n "${remaining}" ]]; then
  echo "[cico-shutdown] Force-Cleanup verbleibender Pods ..."
  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    pod_ns_name=$(kubectl get pods -A --field-selector="spec.nodeName=${K3S_NODE}" \
      -o jsonpath="{range .items[?(@.metadata.name==\"${pod#pod/}\")]}{.metadata.namespace}{end}" 2>/dev/null || true)
    echo "[cico-shutdown]   force-delete ${pod} (ns: ${pod_ns_name:-unbekannt})"
    if [[ -n "${pod_ns_name}" ]]; then
      kubectl delete pod "${pod#pod/}" -n "${pod_ns_name}" --grace-period=0 --force 2>&1 || \
        echo "[cico-shutdown]   WARN: force-delete fehlgeschlagen fuer ${pod}"
    fi
  done <<< "${remaining}"

  echo "[cico-shutdown] Warte kurz auf Bestaetigung der Force-Loeschung ..."
  sleep 10
  kubectl get pods -A --field-selector="spec.nodeName=${K3S_NODE}" -o wide 2>/dev/null || true
fi

# Schritt 4: k3s stoppen
echo "[cico-shutdown] Stoppe k3s ..."
systemctl stop k3s || echo "[cico-shutdown] WARN: k3s konnte nicht gestoppt werden"

# Schritt 5: Herunterfahren
echo "[cico-shutdown] sync && shutdown -h now ..."
sync
shutdown -h now
CICO_SCRIPT
    chmod +x /usr/local/bin/cico-shutdown
    log_ok "cico-shutdown installiert"
  else
    log_ok "cico-shutdown bereits installiert"
  fi

  # ── cico-uncordon ─────────────────────────────────────────────────────
  if [[ ! -f /usr/local/bin/cico-uncordon ]]; then
    cat > /usr/local/bin/cico-uncordon << 'UNCORDON_SCRIPT'
#!/usr/bin/env bash
#
# cico-uncordon — CIVITAS/CORE Node Uncordon (post-boot recovery)
#
# Wartet auf die k3s-API und hebt die Cordon-Markierung des Knotens auf.
# Wird automatisch durch cico-uncordon.service nach k3s-Start ausgefuehrt.
#
# Aufruf:
#   cico-uncordon                    # Knotenname aus "hostname" ermittelt (Default)
#   K3S_NODE=my-node cico-uncordon   # Abweichender Knotenname
#
# Exit-Codes:
#   0 — Node erfolgreich uncordoned oder war bereits schedulable
#   1 — k3s-API nach 180s nicht verfuegbar

set -euo pipefail

K3S_NODE="${K3S_NODE:-$(hostname)}"
TIMEOUT="${TIMEOUT:-180}"

echo "[cico-uncordon] Warte auf k3s-API (Node ${K3S_NODE}) ..."

elapsed=0
until kubectl get nodes "${K3S_NODE}" &>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
        echo "[cico-uncordon] FEHLER: k3s-API nach ${TIMEOUT}s nicht verfuegbar."
        exit 1
    fi
done
echo "[cico-uncordon] k3s-API verfuegbar (${elapsed}s)"

cordoned=$(kubectl get node "${K3S_NODE}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "false")

if [[ "${cordoned}" == "true" ]]; then
    echo "[cico-uncordon] Node ${K3S_NODE} ist cordon'd — hebe Sperre auf ..."
    kubectl uncordon "${K3S_NODE}"
    echo "[cico-uncordon] Node ${K3S_NODE} ist jetzt schedulable."
else
    echo "[cico-uncordon] Node ${K3S_NODE} ist bereits schedulable — nichts zu tun."
fi
UNCORDON_SCRIPT
    chmod +x /usr/local/bin/cico-uncordon
    log_ok "cico-uncordon installiert"
  else
    log_ok "cico-uncordon bereits installiert"
  fi

  # ── systemd-Dienst aktivieren ──────────────────────────────────────────
  if [[ ! -f /etc/systemd/system/cico-uncordon.service ]]; then
    cat > /etc/systemd/system/cico-uncordon.service << 'SERVICE_EOF'
[Unit]
Description=CIVITAS/CORE – Automatisches Uncordon nach k3s-Start
After=k3s.service
Requires=k3s.service
Documentation=https://doc.data-dna.eu/de/specs/civitas-core-plugin/serveraufbau-v1/installationsphasen-und-abnahme

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cico-uncordon
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    systemctl daemon-reload
    systemctl enable cico-uncordon.service
    log_ok "cico-uncordon.service installiert und aktiviert"
  else
    if systemctl is-enabled cico-uncordon.service &>/dev/null; then
      log_ok "cico-uncordon.service bereits aktiviert"
    else
      systemctl enable cico-uncordon.service
      log_ok "cico-uncordon.service nachtraeglich aktiviert"
    fi
  fi

  log_ok "CIVITAS/CORE-Shutdown-Utilities installiert"
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

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
#
# Update-Verhalten: Jede Datei wird zuerst in eine Temp-Datei im Zielverzeichnis
# geschrieben und per cmp -s mit der vorhandenen Datei verglichen. Bei
# identischem Inhalt wird nichts geändert („bereits aktuell“); bei Abweichung
# wird ein Backup angelegt und die Datei ersetzt. So erhalten bestehende VMs
# beim erneuten Lauf des Installers die aktualisierten Skripte.

install_or_update_file() {
  # $1 Zielpfad, $2 Dateimodus (oktal); Inhalt wird über stdin übergeben.
  local path="$1" mode="$2" tmp backup ts
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  cat > "${tmp}"

  if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
    rm -f "${tmp}"
    log_ok "${path} bereits aktuell"
    return 0
  fi

  if [[ -f "${path}" ]]; then
    ts="$(date '+%Y%m%d-%H%M%S')"
    backup="${path}.bak-${ts}"
    cp -a "${path}" "${backup}"
    log "Sicherung angelegt: ${backup}"
  fi

  chmod "${mode}" "${tmp}"
  mv "${tmp}" "${path}"
  log_ok "${path} aktualisiert"
}

install_cico_utils() {
  log "Installiere CIVITAS/CORE-Shutdown-Utilities …"

  # ── cico-shutdown ──────────────────────────────────────────────────────
  install_or_update_file /usr/local/bin/cico-shutdown 0755 << 'CICO_SCRIPT'
#!/usr/bin/env bash
# cico-shutdown — CIVITAS/CORE-VM (Single-Node-k3s) geordnet herunterfahren
#
# Ablauf:
#   1. Node cordonen und drainen; jeder Pod nutzt seine eigene Grace Period
#   2. Warten, bis auf dem Node keine Nicht-DaemonSet-Pods mehr laufen
#   3. k3s stoppen, danach k3s-killall.sh (beendet die Container-Shims)
#   4. sync, systemctl poweroff
#
# Umgebung:
#   K3S_NODE=<name>  Node-Name (Default: der einzige Node im Cluster)
#   MARGIN=30        Aufschlag auf die laengste Pod-Grace in Sekunden
#   MAX_WAIT=900     Obergrenze fuer die Wartezeit in Sekunden
#   FORCE=1          bei Timeout trotzdem k3s stoppen und herunterfahren
#   DRY_RUN=1        nur lesen, Plan anzeigen
#   NO_POWEROFF=1    alles ausser dem abschliessenden poweroff
#
# Exit-Codes: 0 ok, 1 Fehler/Vorbedingung, 2 Pods nicht rechtzeitig beendet

set -Eeuo pipefail

K3S_NODE="${K3S_NODE:-}"
MARGIN="${MARGIN:-30}"
MAX_WAIT="${MAX_WAIT:-900}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
NO_POWEROFF="${NO_POWEROFF:-0}"
LOG_FILE="${LOG_FILE:-/var/log/cico-shutdown.log}"
LOCK_FILE="${LOCK_FILE:-/run/cico-shutdown.lock}"
K3S_KILLALL="${K3S_KILLALL:-/usr/local/bin/k3s-killall.sh}"
POLL=5
SETTLE=30
NODE=""
UNCORDON_ON_EXIT=0

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

log() { printf '%s [cico-shutdown] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
die() { log "FEHLER: $*"; exit 1; }

cleanup() {
  local rc=$?
  if [[ "${UNCORDON_ON_EXIT}" -eq 1 ]]; then
    log "WARN: Abbruch (Exit ${rc}) — gebe Node ${NODE} wieder frei"
    kubectl uncordon "${NODE}" >/dev/null 2>&1 \
      || log "WARN: uncordon fehlgeschlagen — manuell: kubectl uncordon ${NODE}"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; exit 1 ;;
esac

[[ "${EUID}" -eq 0 ]] || die "Muss als root laufen."
command -v kubectl >/dev/null 2>&1 || die "kubectl nicht gefunden."
exec 9>"${LOCK_FILE}"
flock -n 9 || die "Es laeuft bereits eine Instanz von cico-shutdown."

pod_rows() {
  kubectl get pods -A --field-selector "spec.nodeName=${NODE}" \
    -o custom-columns='KIND:.metadata.ownerReferences[0].kind,PHASE:.status.phase,GRACE:.spec.terminationGracePeriodSeconds' \
    --no-headers
}
max_grace() {
  pod_rows | awk '$1!="DaemonSet" && $2!="Succeeded" && $2!="Failed" && $3+0>m {m=$3+0} END {print m+0}'
}
active_pods() {
  pod_rows | awk '$1!="DaemonSet" && $2!="Succeeded" && $2!="Failed" {n++} END {print n+0}'
}

resolve_node() {
  local nodes count
  if [[ -n "${K3S_NODE}" ]]; then
    NODE="${K3S_NODE}"
  else
    nodes="$(kubectl get nodes -o name 2>/dev/null | sed 's#^node/##')" || true
    count="$(printf '%s\n' "${nodes}" | grep -c . || true)"
    if [[ "${count}" -ne 1 ]]; then
      log "Node-Name nicht eindeutig (${count} Nodes). Verfuegbar:"
      kubectl get nodes 2>&1 | tee -a "${LOG_FILE}" || true
      die "Bitte K3S_NODE=<name> setzen."
    fi
    NODE="${nodes}"
  fi
  kubectl get node "${NODE}" >/dev/null 2>&1 || die "Node '${NODE}' nicht im Cluster gefunden."
}

log "=== CIVITAS/CORE VM — geordneter Shutdown ==="
resolve_node

grace="$(max_grace)" || die "Pod-Abfrage fehlgeschlagen (API nicht erreichbar?)"
active="$(active_pods)" || die "Pod-Abfrage fehlgeschlagen (API nicht erreichbar?)"
wait_s=$((grace + MARGIN))
if [[ "${wait_s}" -lt 60 ]]; then wait_s=60; fi
if [[ "${wait_s}" -gt "${MAX_WAIT}" ]]; then wait_s="${MAX_WAIT}"; fi

log "Node:                 ${NODE}"
log "Aktive Pods (ohne DS): ${active}"
log "Laengste Pod-Grace:   ${grace}s"
log "Drain-Timeout:        ${wait_s}s (Grace + ${MARGIN}s, max. ${MAX_WAIT}s)"

if [[ "${DRY_RUN}" == 1 ]]; then
  log "DRY_RUN=1 — geplant: drain, warten, systemctl stop k3s, ${K3S_KILLALL}, sync, poweroff. Nichts ausgefuehrt."
  exit 0
fi

UNCORDON_ON_EXIT=1
log "Drain ${NODE} ..."
if ! kubectl drain "${NODE}" \
      --ignore-daemonsets --delete-emptydir-data --disable-eviction \
      --timeout="${wait_s}s" 2>&1 | tee -a "${LOG_FILE}"; then
  log "WARN: drain nicht vollstaendig durchgelaufen"
fi

elapsed=0
while :; do
  left="$(active_pods)" || die "Pod-Abfrage fehlgeschlagen (API nicht erreichbar?)"
  if [[ "${left}" -eq 0 ]]; then
    log "Alle Pods (ohne DaemonSets) beendet."
    break
  fi
  if [[ "${elapsed}" -ge "${SETTLE}" ]]; then
    log "WARN: ${left} Pod(s) laufen noch:"
    kubectl get pods -A --field-selector "spec.nodeName=${NODE}" -o wide 2>&1 | tee -a "${LOG_FILE}" || true
    if [[ "${FORCE}" != 1 ]]; then
      log "Abbruch ohne Herunterfahren (Exit 2). Mit FORCE=1 trotzdem fortfahren."
      exit 2
    fi
    log "FORCE=1 — fahre trotz laufender Pods fort."
    break
  fi
  sleep "${POLL}"
  elapsed=$((elapsed + POLL))
done

UNCORDON_ON_EXIT=0
log "Stoppe k3s ..."
systemctl stop k3s || log "WARN: systemctl stop k3s fehlgeschlagen"

if [[ -x "${K3S_KILLALL}" ]]; then
  log "Beende Container-Shims (${K3S_KILLALL}) ..."
  "${K3S_KILLALL}" >>"${LOG_FILE}" 2>&1 || log "WARN: ${K3S_KILLALL} meldete einen Fehler"
else
  log "WARN: ${K3S_KILLALL} nicht gefunden — Container-Shims bleiben bis zum Poweroff bestehen"
fi

if pgrep -f containerd-shim >/dev/null 2>&1; then
  log "WARN: containerd-shim-Prozesse laufen noch:"
  pgrep -af containerd-shim 2>&1 | tee -a "${LOG_FILE}" || true
fi

sync
if [[ "${NO_POWEROFF}" == 1 ]]; then
  log "NO_POWEROFF=1 — kein poweroff. Danach: systemctl start k3s; systemctl start cico-uncordon; kubectl get node"
  exit 0
fi
log "systemctl poweroff"
systemctl poweroff
CICO_SCRIPT

  # ── cico-uncordon ─────────────────────────────────────────────────────
  install_or_update_file /usr/local/bin/cico-uncordon 0755 << 'UNCORDON_SCRIPT'
#!/usr/bin/env bash
# cico-uncordon — CIVITAS/CORE Node Uncordon (post-boot recovery)
#
# Wartet auf die k3s-API und hebt die Cordon-Markierung des Knotens auf.
# Wird automatisch durch cico-uncordon.service nach k3s-Start ausgefuehrt.
#
# Node-Name: K3S_NODE aus der Umgebung, sonst der einzige Node im Cluster.
# Bei keinem oder mehreren Nodes bricht das Skript mit klarer Meldung ab.
#
# Aufruf:
#   cico-uncordon                    # einziger Node wird aus dem Cluster ermittelt
#   K3S_NODE=my-node cico-uncordon   # abweichender Node-Name
#
# Exit-Codes:
#   0 — Node erfolgreich uncordoned oder war bereits schedulable
#   1 — k3s-API nach 180s nicht verfuegbar oder Node-Name nicht eindeutig

set -euo pipefail

K3S_NODE="${K3S_NODE:-}"
TIMEOUT="${TIMEOUT:-180}"

echo "[cico-uncordon] Warte auf k3s-API (max. ${TIMEOUT}s) ..."

elapsed=0
until kubectl get nodes >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
        echo "[cico-uncordon] FEHLER: k3s-API nach ${TIMEOUT}s nicht verfuegbar."
        exit 1
    fi
done
echo "[cico-uncordon] k3s-API verfuegbar (${elapsed}s)"

# Node-Name ermitteln
if [[ -n "${K3S_NODE}" ]]; then
    NODE="${K3S_NODE}"
else
    nodes="$(kubectl get nodes -o name 2>/dev/null | sed 's#^node/##')" || true
    count="$(printf '%s\n' "${nodes}" | grep -c . || true)"
    if [[ "${count}" -ne 1 ]]; then
        echo "[cico-uncordon] FEHLER: Node-Name nicht eindeutig (${count} Nodes)."
        echo "[cico-uncordon] Verfuegbare Nodes:"
        kubectl get nodes || true
        echo "[cico-uncordon] Bitte K3S_NODE=<name> setzen."
        exit 1
    fi
    NODE="${nodes}"
fi

if ! kubectl get node "${NODE}" >/dev/null 2>&1; then
    echo "[cico-uncordon] FEHLER: Node '${NODE}' nicht im Cluster gefunden."
    kubectl get nodes || true
    exit 1
fi

cordoned=$(kubectl get node "${NODE}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "false")

if [[ "${cordoned}" == "true" ]]; then
    echo "[cico-uncordon] Node ${NODE} ist cordon'd — hebe Sperre auf ..."
    kubectl uncordon "${NODE}"
    echo "[cico-uncordon] Node ${NODE} ist jetzt schedulable."
else
    echo "[cico-uncordon] Node ${NODE} ist bereits schedulable — nichts zu tun."
fi
UNCORDON_SCRIPT

  # ── systemd-Dienst ─────────────────────────────────────────────────────
  install_or_update_file /etc/systemd/system/cico-uncordon.service 0644 << 'SERVICE_EOF'
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
  if systemctl is-enabled cico-uncordon.service &>/dev/null; then
    log_ok "cico-uncordon.service ist aktiviert"
  else
    systemctl enable cico-uncordon.service
    log_ok "cico-uncordon.service aktiviert"
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

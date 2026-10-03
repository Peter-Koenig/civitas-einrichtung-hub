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
# 01_config.sh — CIVITAS/CORE Installationsskript: Konfiguration
# Alle konfigurierbaren Parameter zentral definiert. Kein anderes Modul
# enthält hartcodierte Werte.
# ──────────────────────────────────────────────────────────────────────────────

# ── Versionspinning ──────────────────────────────────────────────────────────
K3S_VERSION="v1.32.3+k3s1"          # k3s-Release
HELM_VERSION="v3.17.0"              # Helm-CLI

CERT_MANAGER_VERSION="v1.16.0"      # cert-manager Helm-Chart
NGINX_INGRESS_VERSION="4.12.0"      # ingress-nginx Helm-Chart
GATEWAY_API_VERSION="v1.2.1"        # Kubernetes Gateway API CRDs (standard channel)

# ── Plattform ────────────────────────────────────────────────────────────────
DOMAIN_NAME="${DOMAIN_NAME:?'DOMAIN_NAME muss als Umgebungsvariable gesetzt sein (z.B. example.org)'}"
DOMAIN="udp.${DOMAIN_NAME}"
# K8S_NAMESPACE (Singular) wurde entfernt — alle Prüfungen nutzen K8S_NAMESPACES-Array
KUBECONFIG_PATH="${HOME}/.kube/config"
export KUBECONFIG="${KUBECONFIG_PATH}"
K3S_DATA_DIR="/var/lib/rancher/k3s"

# ── k3s-Installationsoptionen ────────────────────────────────────────────────
# Traefik wird deaktiviert (nginx-Ingress wird nachinstalliert).
# local-path-provisioner bleibt aktiv (Default-StorageClass).
# servicelb und metrics-server bleiben aktiv (k3s-Standardverhalten).
# Node-Name explizit pinnen: verhindert k3s-Geister-Nodes bei Cloud-Init-Hostname-Drift.
# `hostname` liefert im VM-Kontext (nach Cloud-Init) den finalen VM-Namen;
# über die Umgebungsvariable K3S_NODE_NAME überschreibbar.
K3S_NODE_NAME="${K3S_NODE_NAME:-$(hostname)}"
K3S_EXEC_ARGS="--disable traefik --node-name ${K3S_NODE_NAME}"

# ── Add-ons ──────────────────────────────────────────────────────────────────
CERT_MANAGER_NAMESPACE="cert-manager"
INGRESS_NAMESPACE="ingress-nginx"

# ── Steuervariablen (aus .env.local) ────────────────────────────────────
LE_CERT="${LE_CERT:-false}"              # false = nur Staging, true = Staging + Production
LE_REQUESTS_BLOCKED="${LE_REQUESTS_BLOCKED:-false}" # true = keinerlei neue Zertifikatsanforderungen (Safety-Schalter)
APISIX_DASHBOARD="${APISIX_DASHBOARD:-false}"  # APISIX-Dashboard aktivieren
RUN_TESTS="${RUN_TESTS:-false}"          # E2E-Tests nach Installation ausführen

# ── SMTP (Werte aus Umgebungsvariablen — nie hartcoden) ──────────────────────
SMTP_HOST="${SMTP_HOST:?'SMTP_HOST muss als Umgebungsvariable gesetzt sein'}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:?'SMTP_USER muss als Umgebungsvariable gesetzt sein'}"
SMTP_PASS="${SMTP_PASS:?'SMTP_PASS muss als Umgebungsvariable gesetzt sein'}"

# ── Admin (Werte aus Umgebungsvariablen) ─────────────────────────────────────
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"
# → master_password + initiales platform_admin-Passwort (identisch, kein separater Wert)
ADMIN_PASS="${ADMIN_PASS:?'ADMIN_PASS muss als Umgebungsvariable gesetzt sein'}"

# ── cc-cli (CIVITAS/CORE GitLab Package Registry) ────────────────────────────
CC_CLI_VERSION="1.5.0"
ANSIBLE_VERSION="10.6.0"   # ansible-core 2.17.x, kompatibel mit cc-cli 1.5.0
CC_CLI_REGISTRY_URL="https://gitlab.com/api/v4/projects/62227605/packages/pypi/simple"
CC_CLI_VENV_PATH="/opt/civitas-core-venv"

# ── cc-cli Inventory (Ansible-Inventory für CIVITAS/CORE) ────────────────────
ENVIRONMENT="cc-prd"                    # Environment-Name (cc-prd/cc-stg/cc-dev)
SMTP_FROM="no-reply@${DOMAIN_NAME}"       # Absenderadresse für E-Mails

# ── cc-cli: Kubernetes-Konfiguration ──────────────────────────────────────────
K8S_CONTEXT="${K8S_CONTEXT:-default}"               # kubectl context aus kubeconfig
STORAGECLASS_RWO="${STORAGECLASS_RWO:-local-path}"
STORAGECLASS_RWX="${STORAGECLASS_RWX:-local-path}"
STORAGECLASS_LOC="${STORAGECLASS_LOC:-local-path}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
CERT_MANAGER_ISSUER="${CERT_MANAGER_ISSUER:-selfsigned-issuer}"

# ── cc-cli: Deployment-Umgebung ────────────────────────────────────────────────
CC_ENVIRONMENT="${CC_ENVIRONMENT:-cc-prd}"       # Ansible-Environment-Name

# Von cc_cli angelegte Namespaces (Muster: {ENVIRONMENT}-{stack})
K8S_NAMESPACES=(
  "${CC_ENVIRONMENT}-access-stack"
  "${CC_ENVIRONMENT}-dashboard-stack"
  "${CC_ENVIRONMENT}-database-stack"
  "${CC_ENVIRONMENT}-operation-stack"
)

CC_CLI_WORKDIR="/tmp/civitas-core-deploy"        # CWD für cc_cli validate/exec

# ── Phase 2.0 — Repository ───────────────────────────────────────────────────
CC_V1_REPO_URL="https://gitlab.com/civitas-connect/civitas-core/civitas-core-v1/civitas-core.git"
CC_V1_REPO_PATH="/opt/civitas-core-v1"
CC_V1_REPO_BRANCH="main"
CC_CLI_PLAYBOOK_DIR="${CC_V1_REPO_PATH}/core_platform"   # Verzeichnis mit playbook.yml

# ── V1s — Soft-Fork geoportal-components (statische Masterportal-Config) ─────
# V1s = CIVITAS/CORE V1 mit statischer statt S3-basierter Masterportal-
# Konfiguration. Das Portal-Backend-Image wird aus einem Soft-Fork von
# geoportal-components lokal gebaut und in den k3s-containerd-Store importiert.
# Siehe serveraufbau-v1s/portal-backend-image-build.md.
V1S_FORK_URL="https://gitlab.com/civitas-connect/civitas-core/civitas-core-v1/geoportal-components.git"
V1S_FORK_PATH="/opt/geoportal-components-v1s"          # Lokaler Soft-Fork-Klon in der VM
V1S_FORK_BRANCH="main"                                 # Branch des Soft-Fork-Klons
V1S_INSTANCE_NAME="Standard"                           # Instanzname, case-sensitiv, == PORTAL_INSTANCE_NAME
V1S_IMAGE_TAG="${V1S_IMAGE_TAG:-v1s-local}"            # Lokaler Image-Tag (z. B. v1s-YYYY-MM-DD)
V1S_IMAGE_REF="geoportal_backend:${V1S_IMAGE_TAG}"     # Vollständige Image-Referenz für Build + Import
V1S_DOCKER_INSTALLED_BY_SCRIPT="false"                 # Laufzeit-Flag: Docker vom Skript installiert? (steuert Deinstallation)

# ── Timeouts ─────────────────────────────────────────────────────────────────
TIMEOUT_CC_CLI_EXEC=2700             # Sekunden für cc_cli exec (45 Min; Monitoring-Reaktivierung Turn 5 lädt zusätzliche Helm-Charts)
TIMEOUT_POD_READY=300               # Sekunden für kubectl wait


# ── PBS (Proxmox Backup Server) ──────────────────────────────────────────────
PBS_STORAGE="${PBS_STORAGE-backup-p2d2-kinglui}"    # leer = Backup-Prüfung überspringen

# ── VM-Provisionierung (per .env überschreibbar) ──────────────────────────────
VM_ID="${VM_ID:-2010}"                       # Proxmox VM-ID
VM_NAME="${VM_NAME:-civitas-core}"           # Anzeigename in Proxmox
VM_RAM_MB="${VM_RAM_MB:-40960}"              # RAM in MiB (40 GiB)
VM_CORES="${VM_CORES:-12}"                   # vCPUs
VM_DISK_GB="${VM_DISK_GB:-300}"              # Disk-Größe in GiB
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"              # Bridge-Netzwerk
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-zfs-civitas}"  # Proxmox-Storage für VM-Disk
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2}"
CLOUD_IMAGE_CACHE="${CLOUD_IMAGE_CACHE:-/var/lib/vz/template/qcow}"  # Cache-Verzeichnis (24h gültig)

# ── VM-Netzwerk (statisch, per .env überschreibbar) ───────────────────────────
VM_IP_STATIC="${VM_IP_STATIC:-192.168.12.139}"  # IPv4-Adresse der VM
VM_IP_PREFIX="${VM_IP_PREFIX:-24}"              # IPv4-Präfixlänge
VM_GW="${VM_GW:-192.168.12.1}"                  # IPv4-Gateway
VM_IP6_STATIC="${VM_IP6_STATIC:-}"               # IPv6-Adresse der VM (leer = IPv6 aus)
VM_IP6_PREFIX="${VM_IP6_PREFIX:-64}"            # IPv6-Präfixlänge
VM_GW6="${VM_GW6:-}"                             # IPv6-Gateway (Pflicht, wenn VM_IP6_STATIC gesetzt)

# ── SOHO-Gateway (Default = VM-Gateway) ───────────────────────────────────────
SOHO_GATEWAY="${SOHO_GATEWAY:-${VM_GW}}"

# ── SSH-Zugang zur VM ──
VM_SSH_PUBKEY="${VM_SSH_PUBKEY:-}"                   # optional: Public Key(s) für direkten Login, eine Zeile pro Key
VM_REMOVE_INSTALL_KEY="${VM_REMOVE_INSTALL_KEY:-false}"  # true = Installations-Key am Ende aus der VM entfernen
INSTALL_KEY_DIR="${INSTALL_KEY_DIR:-${HOME}/.local/share/civitas-install/${VM_ID}}"

# ── Remote-Ausführung in der VM ─────────────────────────────────────────────
VM_REMOTE_INSTALL_DIR="/root/civitas-install"   # Zielverzeichnis für scp/SSH in der VM
CERT_BACKUP_FILENAME="${CERT_BACKUP_FILE:-le-certs-backup.yaml}"
if [[ "${CERT_BACKUP_FILENAME}" == /* ]]; then
    CERT_BACKUP_FILE="${CERT_BACKUP_FILENAME}"
else
    CERT_BACKUP_FILE="${VM_REMOTE_INSTALL_DIR}/${CERT_BACKUP_FILENAME}"
fi

# ── Credentials-Ausgabe ─────────────────────────────────────────────────────
CREDENTIALS_OUTPUT_PATH="${CREDENTIALS_OUTPUT_PATH:-/root/civitas-install/credentials.env}"
# Zielpfad für automatisch generierte Dienst-Passwörter (chmod 600).
# Darf NICHT im CC_CLI_PLAYBOOK_DIR liegen, da dieses nach cc_cli exec
# bereinigt wird.

# ROOT_PASSWORD optional. Wenn gesetzt, wird es nach dem SSH-Zugang per stdin
# (chpasswd) in der VM gesetzt, NICHT per qm set --cipassword. Nie hartcoden.
ROOT_PASSWORD="${ROOT_PASSWORD:-}"

# ── Netzwerkmodus: WireGuard optional (WG_ENABLE) ──────────────────────────────
# WG_ENABLE=true  (Default): WireGuard aktiv, die WG_*-Secrets sind Pflicht.
# WG_ENABLE=false:            WireGuard aus, WG_* werden ignoriert (nicht Pflicht).
# Ergebnis: WG_ENABLED=true|false wird exportiert (Groß-/Kleinschreibung egal).
# Hinweis: log_error ist hier noch nicht verfügbar (02_lib.sh wird nach
# 01_config.sh gesourct), daher Fehlerausgabe über echo >&2.
resolve_wg_enable() {
  local mode="${WG_ENABLE:-true}" v missing=()
  case "${mode,,}" in
    true)  WG_ENABLED="true" ;;
    false) WG_ENABLED="false" ;;
    *) echo "FEHLER: WG_ENABLE='${mode}' ungültig (true|false)" >&2; return 1 ;;
  esac
  if [[ "${WG_ENABLED}" == "true" ]]; then
    for v in WG_VM_PRIVATE_KEY WG_OPN_PUBLIC_KEY WG_OPN_ENDPOINT; do
      [[ -n "${!v:-}" ]] || missing+=("${v}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "FEHLER: WG_ENABLE=true, aber Pflichtvariablen fehlen: ${missing[*]} — setzen oder WG_ENABLE=false" >&2
      return 1
    fi
  fi
  export WG_ENABLED
}
resolve_wg_enable || exit 1

# ── WireGuard-Secrets (aus Umgebungsvariablen — nie hartcoden) ────────────────
# Bei WG_ENABLE=false duerfen diese leer bleiben.
WG_VM_PRIVATE_KEY="${WG_VM_PRIVATE_KEY:-}"
WG_OPN_PUBLIC_KEY="${WG_OPN_PUBLIC_KEY:-}"
WG_PRESHARED_KEY="${WG_PRESHARED_KEY:-}"  # optional
WG_OPN_ENDPOINT="${WG_OPN_ENDPOINT:-}"

# ── WireGuard-Netzwerk (Klartext) ──────────────────────────────────────────────
WG_INTERFACE="wg0"
WG_VM_IP="10.10.10.5/24"
WG_OPN_IP="10.10.10.1"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_ALLOWED_IPS="10.10.10.0/24"
WG_CONF_PATH="/etc/wireguard/${WG_INTERFACE}.conf"

# ── Versionspinning-Regel (nur als Kommentar, kein Code) ─────────────────────
# Alle *_VERSION-Variablen werden beim Skriptbau auf konkrete Werte gesetzt.
# Änderungen nur durch bewusste Wartungsaktionen. Niemals "latest" verwenden.

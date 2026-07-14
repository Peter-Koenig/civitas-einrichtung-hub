#!/usr/bin/env bash
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
K8S_NAMESPACE="civitas-core"
KUBECONFIG_PATH="${HOME}/.kube/config"
export KUBECONFIG="${KUBECONFIG_PATH}"
K3S_DATA_DIR="/var/lib/rancher/k3s"

# ── k3s-Installationsoptionen ────────────────────────────────────────────────
# Traefik wird deaktiviert (nginx-Ingress wird nachinstalliert).
# local-path-provisioner bleibt aktiv (Default-StorageClass).
# servicelb und metrics-server bleiben aktiv (k3s-Standardverhalten).
K3S_EXEC_ARGS="--disable traefik"

# ── Add-ons ──────────────────────────────────────────────────────────────────
CERT_MANAGER_NAMESPACE="cert-manager"
INGRESS_NAMESPACE="ingress-nginx"

# ── Steuervariablen (aus .env.local) ────────────────────────────────────
LE_CERT="${LE_CERT:-false}"              # false = nur Staging, true = Staging + Production
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

# ── Timeouts ─────────────────────────────────────────────────────────────────
TIMEOUT_CC_CLI_EXEC=1800             # Sekunden für cc_cli exec
TIMEOUT_POD_READY=300               # Sekunden für kubectl wait


# ── Netzwerk ─────────────────────────────────────────────────────────────────
SOHO_GATEWAY="192.168.12.1"

# ── PBS (Proxmox Backup Server) ──────────────────────────────────────────────
PBS_STORAGE="backup-p2d2-kinglui"

# ── VM-Provisionierung ────────────────────────────────────────────────────────
VM_ID="2010"                                # Proxmox VM-ID
VM_NAME="civitas-core"                      # Anzeigename in Proxmox
VM_RAM_MB="40960"                           # RAM in MiB (40 GiB)
VM_CORES="12"                               # vCPUs
VM_DISK_GB="300"                            # Disk-Größe in GiB
VM_BRIDGE="vmbr0"                           # Bridge-Netzwerk
PROXMOX_STORAGE="local-zfs-civitas"          # Proxmox-Storage für VM-Disk
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"
CLOUD_IMAGE_CACHE="${CLOUD_IMAGE_CACHE:-/var/lib/vz/template/qcow}"  # Cache-Verzeichnis (24h gültig)

# ── VM-Netzwerk (statisch) ────────────────────────────────────────────────────
VM_IP_STATIC="192.168.12.139"               # IPv4-Adresse der VM
VM_IP_PREFIX="24"                           # IPv4-Präfixlänge
VM_GW="192.168.12.1"                        # IPv4-Gateway
VM_IP6_STATIC="fd01:1:1:1::139"            # IPv6-Adresse der VM (ohne Prefix)
VM_IP6_PREFIX="64"                          # IPv6-Präfixlänge
VM_GW6="fd01:1:1:1:de39:6fff:febe:9962"    # IPv6-Gateway
SSH_PUBKEY_PATH="${HOME}/.ssh/authorized_keys"  # SSH-Public-Key für root-Zugang

# ── Remote-Ausführung in der VM ─────────────────────────────────────────────
VM_REMOTE_INSTALL_DIR="/root/civitas-install"   # Zielverzeichnis für scp/SSH in der VM

# ── Credentials-Ausgabe ─────────────────────────────────────────────────────
CREDENTIALS_OUTPUT_PATH="${CREDENTIALS_OUTPUT_PATH:-/root/civitas-install/credentials.env}"
# Zielpfad für automatisch generierte Dienst-Passwörter (chmod 600).
# Darf NICHT im CC_CLI_PLAYBOOK_DIR liegen, da dieses nach cc_cli exec
# bereinigt wird.

# ROOT_PASSWORD wird aus Umgebungsvariable gelesen — nie hartcoden!
ROOT_PASSWORD="${ROOT_PASSWORD:?'ROOT_PASSWORD muss als Umgebungsvariable gesetzt sein'}"

# ── WireGuard-Secrets (aus Umgebungsvariablen — nie hartcoden) ────────────────
WG_VM_PRIVATE_KEY="${WG_VM_PRIVATE_KEY:?'WG_VM_PRIVATE_KEY muss als Umgebungsvariable gesetzt sein'}"
WG_OPN_PUBLIC_KEY="${WG_OPN_PUBLIC_KEY:?'WG_OPN_PUBLIC_KEY muss als Umgebungsvariable gesetzt sein'}"
WG_PRESHARED_KEY="${WG_PRESHARED_KEY:-}"  # optional
WG_OPN_ENDPOINT="${WG_OPN_ENDPOINT:?'WG_OPN_ENDPOINT muss als Umgebungsvariable gesetzt sein'}"

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

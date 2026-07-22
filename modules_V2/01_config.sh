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
# 01_config.sh — CIVITAS/CORE V2 Installationsskript: Konfiguration
# Alle konfigurierbaren Parameter zentral definiert. Kein anderes Modul enthält
# hartcodierte Werte.
# ──────────────────────────────────────────────────────────────────────────────

# ── Versionspinning ──────────────────────────────────────────────────────────
K3S_VERSION="v1.32.3+k3s1"
HELM_VERSION="v3.18.0"
HELMFILE_VERSION="1.1.9"
CERT_MANAGER_VERSION="v1.17.0"
INGRESS_NGINX_VERSION="4.12.0"

# ── VM-Provisionierung ───────────────────────────────────────────────────────
VM_ID=2010
VM_NAME="civitas-core"
VM_RAM_MB=40960
VM_CORES=12
VM_DISK_GB=300
VM_BRIDGE="vmbr0"
VM_IP_STATIC="192.168.12.139"
VM_IP_CIDR="192.168.12.139/24"
VM_GATEWAY="192.168.12.1"
PROXMOX_STORAGE="local-zfs-civitas"
CLOUD_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"

# ── Plattform ────────────────────────────────────────────────────────────────
DOMAIN="udp.data-dna.eu"
ADMIN_EMAIL="admin@data-dna.eu"
CC_V2_ENVIRONMENT="cc-prd"
CC_V2_REPO_URL="https://gitlab.com/civitas-connect/civitas-core/civitas-core-v2/civitas-core-deployment.git"
CC_V2_REPO_PATH="/opt/civitas-core-v2"
CC_V2_DEPLOY_PATH="/opt/civitas-core-v2/deployment"
KUBECONFIG_PATH="${HOME}/.kube/config"
export KUBECONFIG="${KUBECONFIG_PATH}"

# ── Ingress / TLS (Caddy-Terminierung) ───────────────────────────────────────
CLUSTER_ISSUER="selfsigned-ca"
INGRESS_CLASS="nginx"
SSL_REDIRECT="false"

# ── Kubernetes-Namespace ─────────────────────────────────────────────────────
K8S_NAMESPACE="${CC_V2_ENVIRONMENT}"

# ── k3s-Installationsoptionen ────────────────────────────────────────────────
K3S_EXEC_ARGS="--disable traefik"

# ── Add-ons ──────────────────────────────────────────────────────────────────
CERT_MANAGER_NAMESPACE="cert-manager"
INGRESS_NAMESPACE="ingress-nginx"

# ── SMTP (Werte aus Umgebungsvariablen — nie hartcoden) ──────────────────────
SMTP_HOST="${SMTP_HOST:?'SMTP_HOST muss als Umgebungsvariable gesetzt sein'}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:?'SMTP_USER muss als Umgebungsvariable gesetzt sein'}"
SMTP_PASS="${SMTP_PASS:?'SMTP_PASS muss als Umgebungsvariable gesetzt sein'}"
SMTP_FROM="${SMTP_FROM:-no-reply@data-dna.eu}"

# ── ROOT_PASSWORD (Pflicht) ──────────────────────────────────────────────────
ROOT_PASSWORD="${ROOT_PASSWORD:?'ROOT_PASSWORD muss als Umgebungsvariable gesetzt sein'}"

# ── Timeouts ─────────────────────────────────────────────────────────────────
TIMEOUT_HELMFILE_SYNC=900
TIMEOUT_POD_READY=300

# ── Netzwerk ─────────────────────────────────────────────────────────────────
SOHO_GATEWAY="192.168.12.1"
CLOUD_IMAGE_NAME="debian-13-genericcloud-amd64-daily.qcow2"
CLOUD_IMAGE_PATH="/tmp/${CLOUD_IMAGE_NAME}"

# ── WireGuard-Secrets (aus Umgebungsvariablen — nie hartcoden) ───────────────
WG_VM_PRIVATE_KEY="${WG_VM_PRIVATE_KEY:?'WG_VM_PRIVATE_KEY muss als Umgebungsvariable gesetzt sein'}"
WG_OPN_PUBLIC_KEY="${WG_OPN_PUBLIC_KEY:?'WG_OPN_PUBLIC_KEY muss als Umgebungsvariable gesetzt sein'}"
WG_OPN_ENDPOINT="${WG_OPN_ENDPOINT:?'WG_OPN_ENDPOINT muss als Umgebungsvariable gesetzt sein'}"

# ── WireGuard-Netzwerk (Klartext) ────────────────────────────────────────────
WG_INTERFACE="wg0"
WG_VM_IP="10.10.10.5"
WG_OPN_IP="10.10.10.1"
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
WG_ALLOWED_IPS="10.10.10.0/24"
WG_CONF_PATH="/etc/wireguard/${WG_INTERFACE}.conf"

# ── Versionspinning-Regel (nur als Kommentar, kein Code) ─────────────────────
# Alle *_VERSION-Variablen werden beim Skriptbau auf konkrete Werte gesetzt.
# Änderungen nur durch bewusste Wartungsaktionen. Niemals "latest" verwenden.

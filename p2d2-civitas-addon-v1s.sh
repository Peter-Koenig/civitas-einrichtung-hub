#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-civitas-addon-v1s.sh — p2d2-AddOn für CIVITAS/CORE V1s
#
# Rudimentäres Skript-Skelett (Schritt 1 von 2). Installiert die drei FERTIGEN
# Bausteine (PostgreSQL, GeoServer, MapProxy) in der manuell verifizierten
# Reihenfolge; Frontend ist ein klar markierter Platzhalter (Baustein noch nicht
# fertig, siehe addon_30_frontend.sh).
#
# V1s-Kopplung: dieses AddOn setzt auf CIVITAS/CORE V1s auf (nicht V1, nicht V2).
#
# Ausführungskontext: läuft dort, wo kubectl-Zugriff auf den Cluster besteht
# (Workstation mit p2d2-addon-installer.kubeconfig oder k3s-Node).
#
# TODO (später, NICHT jetzt): Stage-Scope-Parameter `--stage=main|all`. Die Module
# iterieren intern bereits über alle bekannten Stages — dort lässt sich der Scope
# später ohne Grundumbau nachrüsten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (rudimentär; später aus inventory/01_config.sh) ─────────────────────
export ADDON_NS="${ADDON_NS:-cc-prd-geodata-stack}"
export ADDON_DB_NS="${ADDON_DB_NS:-cc-prd-database-stack}"
export ADDON_DOMAIN="${ADDON_DOMAIN:-udp.data-dna.eu}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/p2d2-addon-installer.kubeconfig}"

# ── Log-Helfer (minimal, self-contained; analog modules_V1s/02_lib.sh) ────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ── Module laden ───────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules_addon_V1s/addon_00_postgresql.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_10_geoserver.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_20_mapproxy.sh"
source "${SCRIPT_DIR}/modules_addon_V1s/addon_30_frontend.sh"

# ── Startmeldung ────────────────────────────────────────────────────────────────
log "============================================"
log " p2d2-AddOn (CIVITAS/CORE V1s) — Installation"
log " Namespace: ${ADDON_NS}"
log " DB-Namespace: ${ADDON_DB_NS}"
log " Domain:       ${ADDON_DOMAIN}"
log "============================================"

# ── Bausteine in Reihenfolge ────────────────────────────────────────────────────
install_addon_postgresql
install_addon_geoserver
install_addon_mapproxy
install_addon_frontend

log ""
log "============================================"
log " p2d2-AddOn (V1s) — Installation abgeschlossen."
log "============================================"

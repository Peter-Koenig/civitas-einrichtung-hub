#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# verify-uninstall.sh — rein lesende Bestandsaufnahme nach `p2d2-civitas-addon-v1s.sh
# --uninstall`. Prüft in den 5 Modulen (frontend → iam → mapproxy → geoserver →
# postgresql), ob noch Fragmente einer Installation übrig sind.
#
# WICHTIG: KEINE Löschlogik — nur Diagnose. Es werden exakt die Prüfbefehle aus der
# laufenden Verifikation (Turn 71/72 bzw. overlay_addon_V1s/k8s/UNINSTALL-CHECKLIST.md)
# ausgeführt, keine neuen Prüfungen.
#
# Es werden alle 14 vom Installationsskript verwalteten PostgreSQL-Rollen geprüft
# (P2D2-Admin/-RO/-Admin-Role/-RO-Role, P2D2-User-<STAGE>, P2D2-<STAGE>). Die frühere
# "Fund-3"-Ausklammerung ist mit dem ai-run
# 2026-09-28-p2d2-standalone-addon-modulabgleich (Turns 6–10) geklärt.
#
# Aufruf (Defaults passen für civitas-core-V1s, per Env überschreibbar):
#   ./supplement/verify-uninstall.sh
#   NS=... DBNS=... DOMAIN=... ./supplement/verify-uninstall.sh

set -uo pipefail

# ── Config (Defaults analog p2d2-civitas-addon-v1s.sh) ─────────────────────────
NS="${NS:-cc-prd-geodata-stack}"
DBNS="${DBNS:-cc-prd-database-stack}"
DOMAIN="${DOMAIN:-udp.data-dna.eu}"
# IAM/Keycloak (analog addon_25_iam.sh)
IAM_REALM="${IAM_REALM:-cc-prd}"
IAM_NS="${IAM_NS:-cc-prd-access-stack}"
IAM_ADMIN_SECRET="${IAM_ADMIN_SECRET:-cc-prd-keycloak-admin}"

# ── Log-Helfer ─────────────────────────────────────────────────────────────────
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }

# Zähler für gefundene Reste (am Ende zusammengefasst).
RESTE=0
note_reste() { log_warn "Reste: $*"; RESTE=$((RESTE + 1)); }

log "=== p2d2-AddOn: Bestandsaufnahme nach --uninstall (rein lesend) ==="
log "    NS=${NS}  DBNS=${DBNS}  DOMAIN=${DOMAIN}"

# ── 1. Frontend ────────────────────────────────────────────────────────────────
log ""
log "== 1. Frontend (K8s-Ressourcen) =="
fe=$(kubectl -n "$NS" get deploy,svc,cm,secret,ingress,pvc,jobs -o name 2>/dev/null \
  | grep -E 'p2d2|f-de1|f-de2|f-fv' || true)
if [[ -z "$fe" ]]; then
  log_ok "keine p2d2-/f-<stage>-Ressourcen"
else
  note_reste "Frontend-Ressourcen vorhanden:"
  printf '      %s\n' $fe
fi

fe_tls=$(kubectl -n "$NS" get secret -o name 2>/dev/null \
  | grep -E "^secret/(www|dev|f-de1|f-de2|f-fv)\.${DOMAIN}-tls$" || true)
if [[ -z "$fe_tls" ]]; then
  log_ok "keine Frontend-TLS-Secrets (<host>-tls)"
else
  note_reste "Frontend-TLS-Secrets vorhanden:"
  printf '      %s\n' $fe_tls
fi

# ── 2. IAM/Keycloak ────────────────────────────────────────────────────────────
log ""
log "== 2. IAM/Keycloak =="
token=""
if kubectl -n "$IAM_NS" get secret "$IAM_ADMIN_SECRET" &>/dev/null; then
  master_user=$(kubectl -n "$IAM_NS" get secret "$IAM_ADMIN_SECRET" \
    -o jsonpath='{.data.MASTER_USERNAME}' | base64 -d 2>/dev/null || true)
  master_pass=$(kubectl -n "$IAM_NS" get secret "$IAM_ADMIN_SECRET" \
    -o jsonpath='{.data.MASTER_PASSWORD}' | base64 -d 2>/dev/null || true)
  if [[ -n "$master_user" && -n "$master_pass" ]]; then
    token=$(curl -sk --max-time 15 \
      "https://idm.${DOMAIN}/realms/master/protocol/openid-connect/token" \
      --data-urlencode "client_id=admin-cli" \
      --data-urlencode "username=${master_user}" \
      --data-urlencode "password=${master_pass}" \
      --data-urlencode "grant_type=password" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null || true)
  fi
fi

if [[ -z "$token" ]]; then
  note_reste "Keycloak-Token nicht erhältlich — IAM-Reste manuell prüfen"
else
  # OIDC-Client p2d2
  cid=$(curl -sk --max-time 15 "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/clients" \
    -H "Authorization: Bearer ${token}" 2>/dev/null \
    | jq -r '.[] | select(.clientId=="p2d2") | .id // empty' 2>/dev/null | head -1 || true)
  if [[ -z "$cid" ]]; then log_ok "OIDC-Client p2d2 nicht vorhanden"; else note_reste "OIDC-Client p2d2 vorhanden (id ${cid})"; fi

  # OSM-IdP-Broker osm
  osm_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/identity-provider/instances/osm" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)
  if [[ "$osm_code" == "404" ]]; then log_ok "OSM-IdP-Broker osm nicht vorhanden"; else note_reste "OSM-IdP-Broker osm vorhanden (HTTP ${osm_code})"; fi

  # 6 Demo-User
  users=""
  for e in hans.muster jule.kovalenko chisom.eze arman.ekov meera.pillai valentina.cruz; do
    u=$(curl -sk --max-time 15 \
      "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/users?email=${e}%40nospam.scanea.de&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)
    [[ -n "$u" ]] && users="${users} ${e}@nospam.scanea.de"
  done
  if [[ -z "$users" ]]; then log_ok "keine Demo-User"; else note_reste "Demo-User vorhanden:${users}"; fi
fi

# ── 3. MapProxy ────────────────────────────────────────────────────────────────
log ""
log "== 3. MapProxy =="
mp=$(kubectl -n "$NS" get deploy,svc,cm,pvc -o name 2>/dev/null | grep mapproxy || true)
if [[ -z "$mp" ]]; then
  log_ok "keine MapProxy-Ressourcen (deploy/svc/cm/pvc)"
else
  note_reste "MapProxy-Ressourcen vorhanden:"
  printf '      %s\n' $mp
fi

# ── 4. GeoServer ───────────────────────────────────────────────────────────────
log ""
log "== 4. GeoServer =="
gs_user=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d 2>/dev/null || true)
gs_pw=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "$gs_user" && -n "$gs_pw" ]]; then
  ws_names=$(curl -sS -u "$gs_user:$gs_pw" \
    "https://geoportal.${DOMAIN}/geoserver/rest/workspaces.json" 2>/dev/null \
    | jq -r '.workspaces.workspace[]?.name // empty' 2>/dev/null || true)
  ws_found=""
  for ws in main dev de1 de2 fv friedhofsplaene; do
    printf '%s\n' "$ws_names" | grep -qx "$ws" && ws_found="${ws_found} ${ws}"
  done
  if [[ -z "$ws_found" ]]; then
    log_ok "keine p2d2-Workspaces (main/dev/de1/de2/fv/friedhofsplaene)"
  else
    note_reste "GeoServer-Workspaces vorhanden:${ws_found}"
  fi
else
  note_reste "GeoServer-Admin-Secret nicht lesbar — Workspaces manuell prüfen"
fi

# Physische Raster-Dateien im Pod (-A zeigt nur echte Inhalte; das Verzeichnis
# geotiffs/ selbst bleibt laut Turn 73 stehen und ist kein Rest).
gs_pod=$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)
if [[ -n "$gs_pod" ]]; then
  ls_out=$(kubectl -n "$NS" exec "$gs_pod" -- sh -c 'ls -A /opt/geoserver/data_dir/data/geotiffs 2>/dev/null' 2>/dev/null || true)
  if [[ -z "$ls_out" ]]; then
    log_ok "keine Raster-Dateien unter data/geotiffs/ im GeoServer-Pod"
  else
    note_reste "Raster-Dateien im GeoServer-Pod vorhanden:"
    printf '%s\n' "$ls_out" | sed 's/^/      /'
  fi
else
  log_warn "GeoServer-Pod nicht gefunden — Raster-Dateien nicht prüfbar"
fi

# ── 5. PostgreSQL ──────────────────────────────────────────────────────────────
log ""
log "== 5. PostgreSQL =="
superuser=$(kubectl -n "$DBNS" get secret postgres.central-db.credentials.postgresql.acid.zalan.do \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "$superuser" ]]; then
  # Schemata (p2d2_*)
  schemas=$(kubectl -n "$DBNS" exec central-db-0 -- psql -U "$superuser" -d p2d2 -tAc \
    "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'p2d2\\_%' ORDER BY nspname;" 2>/dev/null || true)
  if [[ -z "$schemas" ]]; then
    log_ok "keine p2d2_-Schemata"
  else
    note_reste "p2d2-Schemata vorhanden:"
    printf '      %s\n' $schemas
  fi

  # Rollen: alle 14 vom Installationsskript verwalteten P2D2-*-Rollen.
  roles=$(kubectl -n "$DBNS" exec central-db-0 -- psql -U "$superuser" -d p2d2 -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN ('P2D2-Admin','P2D2-RO','P2D2-Admin-Role','P2D2-RO-Role','P2D2-User-MAIN','P2D2-User-DEVELOP','P2D2-User-DE1','P2D2-User-DE2','P2D2-User-FV','P2D2-MAIN','P2D2-DEVELOP','P2D2-DE1','P2D2-DE2','P2D2-FV') ORDER BY rolname;" 2>/dev/null || true)
  if [[ -z "$roles" ]]; then
    log_ok "keine P2D2-*-Rollen"
  else
    note_reste "P2D2-*-Rollen vorhanden:"
    printf '      %s\n' $roles
  fi
else
  note_reste "Postgres-Superuser-Secret nicht lesbar — DB-Reste manuell prüfen"
fi

# ── Zusammenfassung ────────────────────────────────────────────────────────────
log ""
log "============================================"
if [[ "$RESTE" -eq 0 ]]; then
  log_ok "Keine Reste gefunden — Zustand sauber (Stand: $(date '+%Y-%m-%d %H:%M:%S'))."
else
  log_warn "${RESTE} Rest(e) gefunden — siehe Ausgabe oben."
fi
log "============================================"

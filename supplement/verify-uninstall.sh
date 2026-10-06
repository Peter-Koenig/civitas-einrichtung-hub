#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# verify-uninstall.sh — rein lesende Bestandsaufnahme nach `p2d2-civitas-addon-v1s.sh
# --uninstall`. Prüft in den 5 Modulen (frontend → iam → mapproxy → geoserver →
# postgresql), ob noch Fragmente einer Installation übrig sind.
#
# WICHTIG: KEINE Löschlogik — nur Diagnose.
#
# Exit-Codes: 0 = keine Reste, 1 = Reste gefunden, 2 = Konfiguration fehlt
# (DOMAIN/DOMAIN_NAME nicht gesetzt und nicht aus .env.p2d2-addon lesbar).
#
# Aufruf (Defaults passen für civitas-core-V1s, per Env überschreibbar):
#   DOMAIN=udp.projekte-koenig.eu ./supplement/verify-uninstall.sh
#   NS=... DBNS=... DOMAIN=... ./supplement/verify-uninstall.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Config (Defaults analog p2d2-civitas-addon-v1s.sh) ─────────────────────────
NS="${NS:-cc-prd-geodata-stack}"
DBNS="${DBNS:-cc-prd-database-stack}"
# Uninstall-TLS-Handhabung (Schritt 2c-3): auto/true = <host>-tls-Secrets sind
# erlaubt und werden als bewusst behalten gemeldet; false = strikt (Reste).
KEEP_TLS="${KEEP_TLS:-auto}"
# IAM/Keycloak (analog addon_25_iam.sh)
IAM_REALM="${IAM_REALM:-cc-prd}"
IAM_NS="${IAM_NS:-cc-prd-access-stack}"
IAM_ADMIN_SECRET="${IAM_ADMIN_SECRET:-cc-prd-keycloak-admin}"
# Portal (addon_35_portal.sh): Namespace + ConfigMap-Name.
PORTAL_NS="${PORTAL_NS:-cc-prd-access-stack}"
PORTAL_CM="${PORTAL_CM:-apps.js}"
# APISIX-Admin-Key (gleiche Quelle wie der Uninstall, addon_20_mapproxy.sh).
APISIX_CREDS="${APISIX_CREDS:-/root/civitas-install/credentials.env}"
# Uninstall-Image-Entfernung (N7): false = Images bewusst behalten, true = Rest.
REMOVE_IMAGES="${REMOVE_IMAGES:-${P2D2_UNINSTALL_REMOVE_IMAGES:-false}}"

# ── DOMAIN-Auflösung: kein Default mehr. Reihenfolge: DOMAIN -> ADDON_DOMAIN ->
#    DOMAIN_NAME (Umgebung) -> .env.p2d2-addon (ADDON_DOMAIN, dann DOMAIN_NAME).
#    Fehlt alles, Abbruch mit Exit 2.
_resolve_domain() {
  local env_file val
  [[ -n "${DOMAIN:-}" ]] && return 0
  [[ -n "${ADDON_DOMAIN:-}" ]] && { DOMAIN="${ADDON_DOMAIN}"; return 0; }
  [[ -n "${DOMAIN_NAME:-}" ]] && { DOMAIN="${DOMAIN_NAME}"; return 0; }
  for env_file in "${SCRIPT_DIR}/../.env.p2d2-addon" "${SCRIPT_DIR}/../../.env.p2d2-addon"; do
    [[ -f "$env_file" ]] || continue
    val="$(grep -E '^(export[[:space:]]+)?ADDON_DOMAIN=' "$env_file" | tail -1 \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//')"
    [[ -n "$val" ]] && { DOMAIN="$val"; return 0; }
    val="$(grep -E '^(export[[:space:]]+)?DOMAIN_NAME=' "$env_file" | tail -1 \
      | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"'][[:space:]]*$//')"
    [[ -n "$val" ]] && { DOMAIN="$val"; return 0; }
  done
  return 1
}
if ! _resolve_domain; then
  echo "FEHLER: DOMAIN/DOMAIN_NAME nicht gesetzt und nicht aus .env.p2d2-addon lesbar." >&2
  echo "Aufruf: DOMAIN=udp.projekte-koenig.eu $0" >&2
  exit 2
fi

# ── Master-Pod dynamisch (Label-basiert), Fallback central-db-0 ────────────────
pg_master_pod() {
  local pod
  pod="$(kubectl -n "$DBNS" get pods -l application=spilo -l cluster-name=central-db \
    -l spilo-role=master --field-selector=status.phase=Running -o name 2>/dev/null \
    | head -1 | sed 's|pod/||')"
  [[ -n "$pod" ]] || pod="central-db-0"
  printf '%s' "$pod"
}

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
# <host>.<DOMAIN>-tls-Secrets werden in Check 1b als "bewusst behalten" geführt
# (KEEP_TLS != false); hier nicht zusätzlich als Rest melden (Fehlalarm vermeiden).
if [[ -n "$fe" && "$KEEP_TLS" != "false" ]]; then
  fe=$(printf '%s\n' "$fe" | grep -vE "^secret/(www|dev|f-de1|f-de2|f-fv)\.${DOMAIN}-tls$" || true)
fi
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
elif [[ "$KEEP_TLS" == "false" ]]; then
  note_reste "Frontend-TLS-Secrets vorhanden (KEEP_TLS=false — Rest):"
  printf '      %s\n' $fe_tls
else
  log_ok "Frontend-TLS-Secrets vorhanden (bewusst behalten, KEEP_TLS=${KEEP_TLS}):"
  printf '      %s\n' $fe_tls
fi

# Certificate-Objekte der 5 Stage-Hosts (cert-manager). Das TLS-Secret bleibt
# (E3), das Certificate-Objekt muss weg sein.
cert_json="$(kubectl -n "$NS" get certificate -o json 2>/dev/null)"
cert_rc=$?
if [[ "$cert_rc" -ne 0 ]]; then
  note_reste "Certificate-Abfrage nicht möglich — Zertifikats-Reste manuell prüfen"
else
  cert_rest=""
  for host in www dev f-de1 f-de2 f-fv; do
    n="$(printf '%s' "$cert_json" | jq -r --arg s "${host}.${DOMAIN}-tls" '.items[]? | select(.spec.secretName == $s) | .metadata.name' 2>/dev/null | head -1 || true)"
    [[ -n "$n" ]] && cert_rest="${cert_rest} ${n}"
  done
  if [[ -z "$cert_rest" ]]; then
    log_ok "keine Frontend-Certificate-Objekte"
  else
    note_reste "Frontend-Certificate-Objekte vorhanden:${cert_rest}"
  fi
fi

# Webhook-Controller-RBAC (ServiceAccount/Role/RoleBinding)
sa_rb="$(kubectl -n "$NS" get serviceaccount,role,rolebinding -o name 2>/dev/null)"
sa_rb_rc=$?
if [[ "$sa_rb_rc" -ne 0 ]]; then
  note_reste "Webhook-RBAC nicht pruefbar (Abfrage fehlgeschlagen)"
else
  webhook_rest=""
  for n in "serviceaccount/p2d2-webhook-controller" "role/p2d2-webhook-controller-role" "rolebinding/p2d2-webhook-controller-binding"; do
    printf '%s\n' "$sa_rb" | grep -qx "$n" && webhook_rest="${webhook_rest} ${n}"
  done
  if [[ -z "$webhook_rest" ]]; then
    log_ok "keine Webhook-Controller-RBAC-Reste"
  else
    note_reste "Webhook-Controller-RBAC vorhanden:${webhook_rest}"
  fi
fi

# ── 1b. Portal-Kacheln ────────────────────────────────────────────────────────
log ""
log "== 1b. Portal-Kacheln (apps.js) =="
portal_js="$(kubectl -n "$PORTAL_NS" get cm "$PORTAL_CM" -o jsonpath='{.data.apps\.js}' 2>/dev/null)"
portal_rc=$?
if [[ "$portal_rc" -ne 0 ]]; then
  note_reste "Portal-ConfigMap ${PORTAL_NS}/${PORTAL_CM} nicht lesbar — Kacheln manuell prüfen"
else
  marker="$(printf '%s' "$portal_js" | grep -c -- '// p2d2-addon:begin' || true)"
  ids="$(printf '%s' "$portal_js" | grep -cE 'id: "p2d2-' || true)"
  if [[ "$marker" -gt 0 || "$ids" -gt 0 ]]; then
    note_reste "Portal-Kacheln weiterhin vorhanden (Marker: ${marker}, p2d2-IDs: ${ids})"
  else
    log_ok "keine Portal-Kacheln (apps.js)"
  fi
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
  # OIDC-Client p2d2 (HTTP-Status explizit, damit ein REST-Fehler nicht "nicht
  # vorhanden" vortäuscht).
  cid_http=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
    "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/clients" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)
  if [[ "$cid_http" != "200" ]]; then
    note_reste "Keycloak-Clients nicht abfragbar (HTTP ${cid_http:-0}) — OIDC-Client manuell prüfen"
  else
    cid=$(curl -sk --max-time 15 "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/clients" \
      -H "Authorization: Bearer ${token}" 2>/dev/null \
      | jq -r '.[] | select(.clientId=="p2d2") | .id // empty' 2>/dev/null | head -1 || true)
    if [[ -z "$cid" ]]; then log_ok "OIDC-Client p2d2 nicht vorhanden"; else note_reste "OIDC-Client p2d2 vorhanden (id ${cid})"; fi
  fi

  # OSM-IdP-Broker osm
  osm_code=$(curl -sk --max-time 15 -o /dev/null -w "%{http_code}" \
    "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/identity-provider/instances/osm" \
    -H "Authorization: Bearer ${token}" 2>/dev/null || true)
  if [[ "$osm_code" == "404" ]]; then log_ok "OSM-IdP-Broker osm nicht vorhanden"; else note_reste "OSM-IdP-Broker osm vorhanden (HTTP ${osm_code})"; fi

  # 6 Demo-User (HTTP-Status je Abfrage prüfen; Fehler = nicht pruefbar)
  users=""
  demo_err=0
  for e in hans.muster jule.kovalenko chisom.eze arman.ekov meera.pillai valentina.cruz; do
    demo_http=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
      "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/users?email=${e}%40nospam.scanea.de&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null || true)
    if [[ "$demo_http" != "200" ]]; then
      demo_err=1
      continue
    fi
    u=$(curl -sk --max-time 15 \
      "https://idm.${DOMAIN}/admin/realms/${IAM_REALM}/users?email=${e}%40nospam.scanea.de&exact=true" \
      -H "Authorization: Bearer ${token}" 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)
    [[ -n "$u" ]] && users="${users} ${e}@nospam.scanea.de"
  done
  if [[ "$demo_err" -ne 0 ]]; then
    note_reste "Demo-User-Abfrage nicht pruefbar (HTTP ${demo_http:-0}) — Demo-User manuell prüfen"
  elif [[ -z "$users" ]]; then
    log_ok "keine Demo-User"
  else
    note_reste "Demo-User vorhanden:${users}"
  fi
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

# APISIX mapserver-route/-upstream (gleicher Zugangsweg wie Uninstall).
ak=$(sed -n 's/^APISIX_ADMIN_ROLE_KEY=//p' "$APISIX_CREDS" 2>/dev/null | head -1 || true)
if [[ -z "$ak" ]]; then
  note_reste "APISIX_ADMIN_ROLE_KEY nicht lesbar — mapserver-route/-upstream nicht pruefbar"
else
  apisix_base="https://api-admin.${DOMAIN}/apisix/admin"
  for pair in routes:mapserver-route upstreams:mapserver-upstream; do
    coll="${pair%%:*}"; name="${pair#*:}"
    apisix_http=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' -H "X-API-KEY: ${ak}" "${apisix_base}/${coll}" 2>/dev/null || true)
    if [[ "$apisix_http" != "200" ]]; then
      note_reste "APISIX ${name} nicht pruefbar (HTTP ${apisix_http:-0})"
      continue
    fi
    found=$(curl -sk --max-time 15 -H "X-API-KEY: ${ak}" "${apisix_base}/${coll}" 2>/dev/null \
      | jq -r --arg n "$name" '.list[]? | select(.value.name==$n) | .value.name' 2>/dev/null | head -1 || true)
    if [[ -n "$found" ]]; then note_reste "APISIX ${name} vorhanden"; else log_ok "APISIX ${name} nicht vorhanden"; fi
  done
fi

# ── 4. GeoServer ───────────────────────────────────────────────────────────────
log ""
log "== 4. GeoServer =="
gs_user=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d 2>/dev/null || true)
gs_pw=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "$gs_user" && -n "$gs_pw" ]]; then
  # HTTP-Status explizit auswerten: != 200 bedeutet "nicht pruefbar" (Rest),
  # nicht "keine Workspaces" (falsch-grün). Hinweis: curl -u legt die
  # Zugangsdaten in der Prozessliste offen (bekannt, hier nicht geändert).
  gs_http=$(curl -sS -u "$gs_user:$gs_pw" -o /dev/null -w '%{http_code}' \
    "https://geoportal.${DOMAIN}/geoserver/rest/workspaces.json" 2>/dev/null || true)
  if [[ "$gs_http" != "200" ]]; then
    note_reste "GeoServer-REST nicht erreichbar (HTTP ${gs_http:-0}) — Workspaces nicht pruefbar"
  else
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
  fi
else
  note_reste "GeoServer-Admin-Secret nicht lesbar — Workspaces manuell prüfen"
fi

# Physische Raster-Dateien im Pod (-A zeigt nur echte Inhalte; das Verzeichnis
# geotiffs/ selbst bleibt laut Turn 73 stehen und ist kein Rest).
gs_pod=$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)
if [[ -n "$gs_pod" ]]; then
  ls_out="$(kubectl -n "$NS" exec "$gs_pod" -- sh -c 'ls -A /opt/geoserver/data_dir/data/geotiffs 2>/dev/null' 2>/dev/null)"
  ls_rc=$?
  if [[ "$ls_rc" -ne 0 ]]; then
    note_reste "Raster-Dateien im GeoServer-Pod nicht pruefbar (exec-Fehler)"
  elif [[ -z "$ls_out" ]]; then
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
# Operator-/Datenbankebene: preparedDatabases.p2d2 muss entfernt sein. Nur p2d2
# wird bewertet — fremde preparedDatabases (frost/geodata/keycloak/quantumleap/
# stellio_*/superset*) sind KEINE Reste und bleiben unangetastet.
p2d2_cr=$(kubectl -n "$DBNS" get postgresql central-db -o jsonpath='{.spec.preparedDatabases.p2d2}' 2>/dev/null || true)
if [[ -n "$p2d2_cr" ]]; then
  note_reste "preparedDatabases.p2d2 weiterhin im CR central-db vorhanden"
else
  log_ok "preparedDatabases.p2d2 aus central-db entfernt"
fi

superuser=$(kubectl -n "$DBNS" get secret postgres.central-db.credentials.postgresql.acid.zalan.do \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
db_pod=$(pg_master_pod)

if [[ -n "$superuser" ]]; then
  # Datenbank-Existenz über die Maintenance-DB postgres; Verbindungsfehler ist ein
  # Rest (nicht "nicht vorhanden").
  db_out="$(kubectl -n "$DBNS" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='p2d2';" 2>/dev/null)"
  db_rc=$?
  db_exists=0
  if [[ "$db_rc" -ne 0 ]]; then
    note_reste "PostgreSQL nicht erreichbar — DB-Zustand manuell prüfen"
  elif [[ -n "$(printf '%s' "$db_out" | tr -d '[:space:]')" ]]; then
    note_reste "Datenbank p2d2 weiterhin vorhanden (pg_database)"
    db_exists=1
  else
    log_ok "Datenbank p2d2 nicht vorhanden"
  fi

  # Schemata (p2d2_*) — nur prüfbar, wenn die Datenbank existiert.
  if [[ "$db_exists" -eq 1 ]]; then
    schemas="$(kubectl -n "$DBNS" exec "$db_pod" -- psql -U "$superuser" -d p2d2 -tAc \
      "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'p2d2\\_%' ORDER BY nspname;" 2>/dev/null)"
    schemas_rc=$?
    if [[ "$schemas_rc" -ne 0 ]]; then
      note_reste "Schema-Abfrage fehlgeschlagen (Verbindung) — Schemata manuell prüfen"
    elif [[ -z "$(printf '%s' "$schemas" | tr -d '[:space:]')" ]]; then
      log_ok "keine p2d2_-Schemata"
    else
      note_reste "p2d2-Schemata vorhanden:"
      printf '      %s\n' $schemas
    fi
  else
    log "    Schemaprüfung: n/a (Datenbank nicht vorhanden)"
  fi

  # Rollen: alle 14 vom Installationsskript verwalteten P2D2-*-Rollen über -d postgres.
  roles="$(kubectl -n "$DBNS" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN ('P2D2-Admin','P2D2-RO','P2D2-Admin-Role','P2D2-RO-Role','P2D2-User-MAIN','P2D2-User-DEVELOP','P2D2-User-DE1','P2D2-User-DE2','P2D2-User-FV','P2D2-MAIN','P2D2-DEVELOP','P2D2-DE1','P2D2-DE2','P2D2-FV') ORDER BY rolname;" 2>/dev/null)"
  roles_rc=$?
  if [[ "$roles_rc" -ne 0 ]]; then
    note_reste "Rollen-Abfrage fehlgeschlagen (Verbindung) — P2D2-*-Rollen manuell prüfen"
  elif [[ -z "$(printf '%s' "$roles" | tr -d '[:space:]')" ]]; then
    log_ok "keine P2D2-*-Rollen"
  else
    note_reste "P2D2-*-Rollen vorhanden:"
    printf '      %s\n' $roles
  fi

  # Operator-Rollen (p2d2_*): LOGIN + NOLOGIN — vom Uninstall neu entfernt.
  op_roles="$(kubectl -n "$DBNS" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN ('p2d2_owner','p2d2_reader','p2d2_writer','p2d2_owner_user','p2d2_reader_user','p2d2_writer_user') ORDER BY rolname;" 2>/dev/null)"
  op_roles_rc=$?
  if [[ "$op_roles_rc" -ne 0 ]]; then
    note_reste "Operator-Rollen-Abfrage fehlgeschlagen (Verbindung) — p2d2_*-Rollen manuell prüfen"
  elif [[ -z "$(printf '%s' "$op_roles" | tr -d '[:space:]')" ]]; then
    log_ok "keine p2d2_*-Operator-Rollen"
  else
    note_reste "p2d2_*-Operator-Rollen vorhanden:"
    printf '      %s\n' $op_roles
  fi
else
  note_reste "Postgres-Superuser-Secret nicht lesbar — DB-Reste manuell prüfen"
fi

# Operator-Secrets im DB-Namespace (vom Uninstall neu entfernt).
op_secrets=""
for s in p2d2-owner-user.central-db.credentials.postgresql.acid.zalan.do \
         p2d2-reader-user.central-db.credentials.postgresql.acid.zalan.do \
         p2d2-writer-user.central-db.credentials.postgresql.acid.zalan.do; do
  if kubectl -n "$DBNS" get secret "$s" >/dev/null 2>&1; then
    op_secrets="${op_secrets} ${s}"
  fi
done
if [[ -z "$op_secrets" ]]; then
  log_ok "keine p2d2-Operator-Secrets"
else
  note_reste "p2d2-Operator-Secrets vorhanden:${op_secrets}"
fi

# ── 6. Frontend-Images (containerd) ───────────────────────────────────────────
log ""
log "== 6. Frontend-Images (containerd) =="
if ! command -v k3s >/dev/null 2>&1; then
  note_reste "k3s nicht verfügbar — Frontend-Images nicht pruefbar"
else
  img_list="$(k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}')"
  img_rc=$?
  if [[ "$img_rc" -ne 0 ]]; then
    note_reste "containerd-Image-Liste nicht lesbar — Frontend-Images nicht pruefbar"
  else
    img_found=""
    for stage in main dev de1 de2 fv; do
      found="$(printf '%s\n' "$img_list" | grep -F "p2d2-frontend-${stage}:" | head -1 || true)"
      [[ -n "$found" ]] && img_found="${img_found} ${found}"
    done
    if [[ -z "$img_found" ]]; then
      log_ok "keine p2d2-Frontend-Images"
    elif [[ "$REMOVE_IMAGES" == "true" ]]; then
      note_reste "p2d2-Frontend-Images vorhanden (REMOVE_IMAGES=true — Rest):${img_found}"
    else
      log_ok "p2d2-Frontend-Images vorhanden (bewusst behalten, REMOVE_IMAGES=${REMOVE_IMAGES}):"
      printf '      %s\n' $img_found
    fi
  fi
fi

# ── Zusammenfassung ────────────────────────────────────────────────────────────
log ""
log "============================================"
if [[ "$RESTE" -eq 0 ]]; then
  log_ok "Keine Reste gefunden — Zustand sauber (Stand: $(date '+%Y-%m-%d %H:%M:%S'))."
  exit 0
else
  log_warn "${RESTE} Rest(e) gefunden — siehe Ausgabe oben."
  exit 1
fi

# p2d2-AddOn (CIVITAS/CORE V1s) — Manuelle Uninstall-Checkliste

Diese Datei ist die **manuelle Absicherung** für den Fall, dass
`p2d2-civitas-addon-v1s.sh --uninstall` mittendrin abbricht (Netzwerk,
API-Timeout, Rechteproblem, Tippfehler, …). Ein Skript kann seinen eigenen
sauberen Abbruch nicht garantieren — diese Checkliste lässt sich von Hand
abarbeiten, bevor ein Neuaufbau (`--install`) versucht wird.

## Vor dem Start: Wo ist der Lauf stehengeblieben?

1. **Letzte Log-Zeile ansehen** — sie nennt das Modul, in dem abgebrochen wurde
   (`Uninstall AddOn 30/25/20/10/00 …`).
2. Die Module laufen in der Reihenfolge
   **`frontend → iam → mapproxy → geoserver → postgresql`**.
3. Die Checkliste **ab dem betroffenen Modul rückwärts** (in Löschreihenfolge)
   durchgehen. Module, die bereits sauber durchliefen, müssen nicht erneut geprüft
   werden — ein `--ignore-not-found`-Uninstall ist idempotent.

## Platzhalter (für alle Befehle gültig)

```bash
NS=cc-prd-geodata-stack      # GeoData-Namespace (Frontend/GeoServer/MapProxy)
DBNS=cc-prd-database-stack   # Datenbank-Namespace (PostgreSQL)
DOMAIN=udp.data-dna.eu       # AddOn-Domain
```

Stages und ihre Ressourcen-Suffixe:

| Stage | Deployment/Service/Ingress | ConfigMap | Secret | TLS-Secret | Alt-PVC |
|---|---|---|---|---|---|
| main  | `p2d2-main`  | `p2d2-main-config`  | `p2d2-main-secret`  | `www.$DOMAIN-tls`   | `p2d2-main-code`  |
| dev   | `p2d2-dev`   | `p2d2-dev-config`   | `p2d2-dev-secret`   | `dev.$DOMAIN-tls`   | `p2d2-dev-code`   |
| de1   | `p2d2-f-de1` | `p2d2-f-de1-config` | `p2d2-f-de1-secret` | `f-de1.$DOMAIN-tls` | `p2d2-f-de1-code` |
| de2   | `p2d2-f-de2` | `p2d2-f-de2-config` | `p2d2-f-de2-secret` | `f-de2.$DOMAIN-tls` | `p2d2-f-de2-code` |
| fv    | `p2d2-f-fv`  | `p2d2-f-fv-config`  | `p2d2-f-fv-secret`  | `f-fv.$DOMAIN-tls`  | `p2d2-f-fv-code`  |

---

## 1. Frontend (`addon_30_frontend.sh`)

### 1.1 Was normalerweise entfernt wird

- **Je Stage:** Deployment, Service, ConfigMap, Secret, Ingress (Name = Service-Name),
  TLS-Secret `<host>-tls`, Alt-PVC `<svc>-code`.
- **Basis:** ConfigMap `p2d2-base-config`, Secret `p2d2-base-secret`.
- **Webhook-Controller:** Deployment/Service `p2d2-webhook-controller`,
  ServiceAccount `p2d2-webhook-controller`, Role `p2d2-webhook-controller-role`,
  RoleBinding `p2d2-webhook-controller-binding`.
- **Builder-Jobs:** alle Jobs mit Namensmuster `p2d2-…-builder…`.
- **Shared-Infra-Secrets:** `p2d2-builder-git-auth`, `p2d2-webhook-secrets`.

### 1.2 Prüfbefehl (Reste erkennen)

```bash
# Alle p2d2-Workloads/Configs im GeoData-Namespace:
kubectl -n "$NS" get deploy,svc,cm,secret,ingress,pvc,jobs -o name | grep -E 'p2d2|f-de1|f-de2|f-fv'
# TLS-Secrets des Frontends (cert-manager):
kubectl -n "$NS" get secret -o name | grep -E "^secret/(www|dev|f-de1|f-de2|f-fv)\.$DOMAIN-tls$"
```

### 1.3 Manueller Löschbefehl (falls Reste gefunden)

```bash
for s in p2d2-main p2d2-dev p2d2-f-de1 p2d2-f-de2 p2d2-f-fv; do
  kubectl -n "$NS" delete deployment "$s" --ignore-not-found
  kubectl -n "$NS" delete service    "$s" --ignore-not-found
  kubectl -n "$NS" delete ingress    "$s" --ignore-not-found
  kubectl -n "$NS" delete pvc        "$s-code" --ignore-not-found
done
kubectl -n "$NS" delete cm p2d2-main-config p2d2-dev-config p2d2-f-de1-config p2d2-f-de2-config p2d2-f-fv-config --ignore-not-found
kubectl -n "$NS" delete secret p2d2-main-secret p2d2-dev-secret p2d2-f-de1-secret p2d2-f-de2-secret p2d2-f-fv-secret --ignore-not-found
kubectl -n "$NS" delete secret "www.$DOMAIN-tls" "dev.$DOMAIN-tls" "f-de1.$DOMAIN-tls" "f-de2.$DOMAIN-tls" "f-fv.$DOMAIN-tls" --ignore-not-found

kubectl -n "$NS" delete cm p2d2-base-config --ignore-not-found
kubectl -n "$NS" delete secret p2d2-base-secret --ignore-not-found

kubectl -n "$NS" delete deploy p2d2-webhook-controller --ignore-not-found
kubectl -n "$NS" delete svc p2d2-webhook-controller --ignore-not-found
kubectl -n "$NS" delete sa p2d2-webhook-controller --ignore-not-found
kubectl -n "$NS" delete role p2d2-webhook-controller-role --ignore-not-found
kubectl -n "$NS" delete rolebinding p2d2-webhook-controller-binding --ignore-not-found

kubectl -n "$NS" delete secret p2d2-builder-git-auth p2d2-webhook-secrets --ignore-not-found

# Builder-Jobs (nur p2d2-…-builder…, niemals fremde Jobs):
kubectl -n "$NS" get jobs -o name | sed 's|.*/||' | grep -E '^p2d2-.*builder' \
  | xargs -r -I{} kubectl -n "$NS" delete job {} --ignore-not-found
```

### 1.4 Ausdrücklich NICHT anfassen

- GeoServer (`geoserver-geoserver`), MapProxy (`mapproxy`), Masterportal,
  `portalBackend`, `ingress-nginx`, `cert-manager` — alles CIVITAS/CORE-Kern
  bzw. eigene Module (siehe unten), nicht das Frontend.
- Keine Jobs/Deployments ohne `p2d2`-Präfix löschen.

---

## 2. IAM/Keycloak (`addon_25_iam.sh`)

### 2.1 Was normalerweise entfernt wird

- OIDC-Client `p2d2` (entfernt Client-Rollen + Token-Mapper mit).
- OSM-IdP-Broker `osm` (entfernt IdP-Mapper mit).
- 6 Demo-User (per E-Mail-Lookup): `hans.muster@`, `jule.kovalenko@`,
  `chisom.eze@`, `arman.ekov@`, `meera.pillai@`, `valentina.cruz@`
  (alle `@nospam.scanea.de`).
- Generierte Datei `/root/civitas-install/p2d2-addon-credentials.env`.
- Es existieren **keine** Realm-Groups (das AddOn legt keine an).

### 2.2 Prüfbefehl (Reste erkennen)

```bash
TOKEN=$(curl -sk "https://idm.$DOMAIN/realms/master/protocol/openid-connect/token" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=$MASTER_USERNAME" \
  --data-urlencode "password=$MASTER_PASSWORD" \
  --data-urlencode "grant_type=password" | jq -r '.access_token')

# Client p2d2 vorhanden?
curl -sk "https://idm.$DOMAIN/admin/realms/cc-prd/clients" -H "Authorization: Bearer $TOKEN" \
  | jq '.[] | select(.clientId=="p2d2") | {id, clientId}'
# OSM-IdP vorhanden?
curl -sk "https://idm.$DOMAIN/admin/realms/cc-prd/identity-provider/instances/osm" \
  -H "Authorization: Bearer $TOKEN" | jq '{alias, providerId}'
# Demo-User vorhanden?
for e in hans.muster jule.kovalenko chisom.eze arman.ekov meera.pillai valentina.cruz; do
  curl -sk "https://idm.$DOMAIN/admin/realms/cc-prd/users?email=$e%40nospam.scanea.de&exact=true" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].email // empty'
done
```

(`MASTER_USERNAME`/`MASTER_PASSWORD` stehen im K8s-Secret `cc-prd-keycloak-admin`
im Namespace `cc-prd-access-stack`, Keys `MASTER_USERNAME`/`MASTER_PASSWORD`.)

### 2.3 Manueller Löschbefehl (falls Reste gefunden)

```bash
# Client p2d2 (Client-ID ermitteln):
CID=$(curl -sk "https://idm.$DOMAIN/admin/realms/cc-prd/clients" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.clientId=="p2d2") | .id')
[ -n "$CID" ] && curl -sk -X DELETE "https://idm.$DOMAIN/admin/realms/cc-prd/clients/$CID" -H "Authorization: Bearer $TOKEN"

# OSM-IdP:
curl -sk -X DELETE "https://idm.$DOMAIN/admin/realms/cc-prd/identity-provider/instances/osm" -H "Authorization: Bearer $TOKEN"

# Demo-User (UID per E-Mail ermitteln, dann löschen):
for e in hans.muster jule.kovalenko chisom.eze arman.ekov meera.pillai valentina.cruz; do
  USER_UID=$(curl -sk "https://idm.$DOMAIN/admin/realms/cc-prd/users?email=$e%40nospam.scanea.de&exact=true" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id // empty')
  [ -n "$USER_UID" ] && curl -sk -X DELETE "https://idm.$DOMAIN/admin/realms/cc-prd/users/$USER_UID" -H "Authorization: Bearer $TOKEN"
done

rm -f /root/civitas-install/p2d2-addon-credentials.env
```

### 2.4 Ausdrücklich NICHT anfassen

- Realm `cc-prd` selbst, `master`-Realm, Keycloak-Admin-User.
- Andere Clients/IdPs (z. B. `admin-cli`, andere Masterportal-Clients).

---

## 3. MapProxy (`addon_20_mapproxy.sh`)

### 3.1 Was normalerweise entfernt wird

- Deployment/Service/ConfigMap/PVC `mapproxy`, `mapproxy-config`, `mapproxy-cache`.
- APISIX-Route `mapserver-route` + APISIX-Upstream `mapserver-upstream`.

### 3.2 Prüfbefehl (Reste erkennen)

```bash
kubectl -n "$NS" get deploy,svc,cm,pvc -o name | grep mapproxy

# APISIX (Admin-Key aus der CIVITAS/CORE-Credentials-Datei):
AK=$(sed -n 's/^APISIX_ADMIN_ROLE_KEY=//p' /root/civitas-install/credentials.env | head -1)
curl -sk -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/routes" \
  | jq '.list[]? | select(.value.name=="mapserver-route") | .value.name'
curl -sk -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/upstreams" \
  | jq '.list[]? | select(.value.name=="mapserver-upstream") | .value.name'
```

### 3.3 Manueller Löschbefehl (falls Reste gefunden)

```bash
kubectl -n "$NS" delete deployment mapproxy --ignore-not-found
kubectl -n "$NS" delete service mapproxy --ignore-not-found
kubectl -n "$NS" delete configmap mapproxy-config --ignore-not-found
kubectl -n "$NS" delete pvc mapproxy-cache --ignore-not-found

AK=$(sed -n 's/^APISIX_ADMIN_ROLE_KEY=//p' /root/civitas-install/credentials.env | head -1)
# Route löschen (ID = .value.id bzw. letztes Pfadsegment von .key):
RID=$(curl -sk -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/routes" \
  | jq -r '.list[]? | select(.value.name=="mapserver-route") | (.value.id // (.key | split("/")[-1]))')
[ -n "$RID" ] && curl -sk -X DELETE -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/routes/$RID"
UID2=$(curl -sk -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/upstreams" \
  | jq -r '.list[]? | select(.value.name=="mapserver-upstream") | (.value.id // (.key | split("/")[-1]))')
[ -n "$UID2" ] && curl -sk -X DELETE -H "X-API-KEY: $AK" "https://api-admin.$DOMAIN/apisix/admin/upstreams/$UID2"
```

### 3.4 Ausdrücklich NICHT anfassen

- Andere APISIX-Routen/-Upstreams (z. B. `geoserver`, `masterportal`, `idm`-Routen).
- GeoServer, Masterportal, APISIX-Gateway selbst.

---

## 4. GeoServer (`addon_10_geoserver.sh`)

### 4.1 Was normalerweise entfernt wird

- Workspaces `main`, `dev`, `de1`, `de2`, `fv`, `friedhofsplaene`
  (jeweils `DELETE …?recurse=true` — entfernt Datastores/FeatureTypes/Coverages mit).
- WFS-T-Secrets `p2d2-geoserver-wfs-user`, `p2d2-geoserver-wfst-{main,develop,de1,de2,fv}`
  (Turn 71 Fund 1; Namensmuster `p2d2-geoserver-*`).
- Physische Raster-Dateien im GeoServer-Pod unter
  `/opt/geoserver/data_dir/data/geotiffs/` (Turn 71 Fund 2).

### 4.2 Prüfbefehl (Reste erkennen)

```bash
ADMIN_USER=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)
ADMIN_PW=$(kubectl -n "$NS" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)
curl -sS -u "$ADMIN_USER:$ADMIN_PW" "https://geoportal.$DOMAIN/geoserver/rest/workspaces.json" \
  | jq '.workspaces.workspace[].name'
# p2d2-Workspaces (main/dev/de1/de2/fv/friedhofsplaene) dürfen NICHT mehr auftauchen.

# WFS-T-Secrets (Turn 71 Fund 1):
kubectl -n "$NS" get secret -o name | grep '^secret/p2d2-geoserver-'

# Physische Raster-Dateien (Turn 71 Fund 2):
GS_POD=$(kubectl -n "$NS" get pods -o name | grep 'geoserver-geoserver-' | head -1)
[ -n "$GS_POD" ] && kubectl -n "$NS" exec "${GS_POD#pod/}" -- ls -la /opt/geoserver/data_dir/data/geotiffs/ 2>/dev/null
```

### 4.3 Manueller Löschbefehl (falls Reste gefunden)

```bash
for ws in friedhofsplaene fv de2 de1 dev main; do
  curl -sS -u "$ADMIN_USER:$ADMIN_PW" -X DELETE \
    "https://geoportal.$DOMAIN/geoserver/rest/workspaces/$ws?recurse=true"
done

# WFS-T-Secrets (Turn 71 Fund 1):
kubectl -n "$NS" get secrets -o name | sed 's|.*/||' | grep '^p2d2-geoserver-' \
  | xargs -r -I{} kubectl -n "$NS" delete secret {} --ignore-not-found

# Physische Raster-Dateien (Turn 71 Fund 2):
GS_POD=$(kubectl -n "$NS" get pods -o name | grep 'geoserver-geoserver-' | head -1)
[ -n "$GS_POD" ] && kubectl -n "$NS" exec "${GS_POD#pod/}" -- sh -c 'rm -rf /opt/geoserver/data_dir/data/geotiffs'
```

### 4.4 Ausdrücklich NICHT anfassen

- GeoServer-Admin-User/-Rollen, andere Workspaces (z. B. `ds_open_data`).
- Die geteilte GeoServer-Instanz (`geoserver-geoserver`) selbst.
- Das Kern-Secret `geoserver-geoserver` (ohne `p2d2-`-Präfix).

---

## 5. PostgreSQL (`addon_00_postgresql.sh`)

### 5.1 Was normalerweise entfernt wird

- Schemata `p2d2_main`, `p2d2_develop`, `p2d2_de1`, `p2d2_de2`, `p2d2_fv`.
- Rollen `P2D2-MAIN`, `P2D2-DEVELOP`, `P2D2-DE1`, `P2D2-DE2`, `P2D2-FV`.

### 5.2 Prüfbefehl (Reste erkennen)

```bash
SUPERUSER=$(kubectl -n "$DBNS" get secret postgres.central-db.credentials.postgresql.acid.zalan.do \
  -o jsonpath='{.data.username}' | base64 -d)

kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c '\dn' | grep p2d2_
kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c '\du' | grep P2D2-
```

### 5.3 Manueller Löschbefehl (falls Reste gefunden)

```bash
for s in p2d2_fv p2d2_de2 p2d2_de1 p2d2_develop p2d2_main; do
  kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c "DROP SCHEMA IF EXISTS \"$s\" CASCADE;"
done
for r in P2D2-FV P2D2-DE2 P2D2-DE1 P2D2-DEVELOP P2D2-MAIN; do
  kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c "DROP ROLE IF EXISTS \"$r\";"
done
```

### 5.4 Ausdrücklich NICHT anfassen

- Zalando-Postgres-**Superuser**, Datenbank `p2d2` selbst, `central-db`-Cluster.
- Fremde Schemata/Rollen ohne `p2d2_`- / `P2D2-`-Präfix.

---

## Abschluss-Verifikation (nach allen Modulen)

```bash
# GeoData-Namespace: keine p2d2-Reste
kubectl -n "$NS" get deploy,svc,cm,secret,ingress,pvc,jobs -o name | grep -E 'p2d2|f-de1|f-de2|f-fv' || echo "OK: keine p2d2-Reste"
# Datenbank: keine p2d2-Schemata/Rollen
kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c '\dn' | grep p2d2_ || echo "OK: keine p2d2-Schemata"
kubectl -n "$DBNS" exec central-db-0 -- psql -U "$SUPERUSER" -d p2d2 -c '\du' | grep P2D2- || echo "OK: keine p2d2-Rollen"
```

Erst wenn alle Prüfungen leer sind, ist der Zustand sauber genug für einen
vollautonomen Reinstall (`./p2d2-civitas-addon-v1s.sh --install`).

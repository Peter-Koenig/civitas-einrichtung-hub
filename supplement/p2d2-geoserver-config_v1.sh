#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-geoserver-config_v1.sh — GeoServer-Konfiguration (CIVITAS/CORE-AddOn).
# Schritt 1: WFS-T-/WFS-Benutzer, Rollen und Kubernetes-Secrets.
# Schritt 2: Workspaces (Name + Namespace-URI) analog zum Standalone.
# Schritt 3: Datastores (PostGIS-Verbindung) analog zum Standalone.
# Schritt 4: FeatureTypes und Default-Styles analog zum Standalone.
#
# Läuft in der CIVITAS/CORE-VM (root, kubectl vorhanden). Legt die fünf
# WFS-T-Benutzer und den WFS-Lese-Benutzer samt Rollen an bzw. setzt deren
# Passwort, erzeugt die Passwörter und speichert sie als Kubernetes-Secrets
# (das Secret ist Single Source of Truth). Legt außerdem die sechs Workspaces,
# die fünf PostGIS-Datastores und die FeatureTypes samt Default-Styles an.
# --uninstall entfernt genau diese Objekte wieder.
#
# Bewusst klein und flach: keine Statusbericht-/-Authz-/k8s-Diagnose.
#
# Aufruf:  bash ./p2d2-geoserver-config_v1.sh [--dry-run] [--uninstall]
#          [--url BASE] [--ns NAMESPACE] [--help|-h]
# Exit:    0 = ok, 1 = Fehler, 2 = Aufruf-/Voraussetzungsfehler.
#
# P2D2_IMPORT_ROLE entfernt (Legacy). Geplant, nicht Teil dieses Skripts: Rolle
# P2D2_OSM_IMPORT, Benutzer p2d2_osm_import, Secret p2d2-geoserver-osm-import,
# Schreibrecht auf geo-containers in allen Stages (Benennung nach dem Muster
# P2D2_WFST_<KEY>).

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Soll-Tabelle (eine Stelle). Spalten:
#   KEY | Workspace | GeoServer-User | Rollen (Komma-getrennt) | Secret
#
# Hinweis DEVELOP: Das Secret heißt laut VARIABLES.md `p2d2-geoserver-wfst-develop`
# (nicht `-dev`); siehe Rückfrage im Bericht.
# ═══════════════════════════════════════════════════════════════════════════
SOL_TABLE='MAIN|main|p2d2_wfst_main|P2D2_WFST_MAIN|p2d2-geoserver-wfst-main
DEVELOP|dev|p2d2_wfst_develop|P2D2_WFST_DEVELOP|p2d2-geoserver-wfst-develop
DE1|de1|p2d2_wfst_de1|P2D2_WFST_DE1|p2d2-geoserver-wfst-de1
DE2|de2|p2d2_wfst_de2|P2D2_WFST_DE2|p2d2-geoserver-wfst-de2
FV|fv|p2d2_wfst_fv|P2D2_WFST_FV|p2d2-geoserver-wfst-fv
RO|-|p2d2_wfs_user|WFS-USER|p2d2-geoserver-wfs-user'

# Benutzer/Rollen, die dieses Skript NIE anfasst.
NEVER_TOUCH_USERS='admin p2d2_wfst_user'

# Workspace-Soll-Tabelle (Schritt 2): Workspace | Namespace-URI.
# Identisch zum Standalone-Export 2026-09-29; keine Workspace-ACLs, keine Umbenennung.
WS_TABLE='main|urn:data-dna:govdata:main
dev|urn:data-dna:govdata:dev
de1|urn:data-dna:govdata:de1
de2|urn:data-dna:govdata:de2
fv|urn:data-dna:govdata:fv
friedhofsplaene|urn:data-dna:tiffdata'

# Datastore-Soll-Tabelle (Schritt 3): KEY | Workspace | Datastore | Schema | DB-User-Variable | Secret.
# Die DB-User-Variable ist der Name des .env-Schlüssels (P2D2_<KEY>_DB_USER); ihr Wert (z. B. P2D2-MAIN)
# kommt als Datastore-Parameter `user`. Das Secret (Key DB_PASSWORD) gehört addon_00 und wird nur gelesen.
DS_TABLE='MAIN|main|main_pg|p2d2_main|P2D2_MAIN_DB_USER|p2d2-main-secret
DEVELOP|dev|dev_pg|p2d2_develop|P2D2_DEVELOP_DB_USER|p2d2-dev-secret
DE1|de1|de1_pg|p2d2_de1|P2D2_DE1_DB_USER|p2d2-f-de1-secret
DE2|de2|de2_pg|p2d2_de2|P2D2_DE2_DB_USER|p2d2-f-de2-secret
FV|fv|fv_pg|p2d2_fv|P2D2_FV_DB_USER|p2d2-f-fv-secret'

# FeatureType-Soll-Tabelle (Schritt 4): Name | Native-Name | Titel (%ws% = Workspace) | cachingEnabled (-/false) | Default-Style.
# Die Titel werden durch Ersetzen von %ws% durch den Workspace-Namen gebildet.
FT_TABLE='geo-containers|p2d2_containers|Geo-Containers (%ws%)|-|polygon
grabflure|v_grabflure_aktuell|grabflure_aktuell|false|polygon
grabflure_versionen|p2d2_grabflure_versionen|grabflure_versionen|false|polygon
graeber|v_graeber_aktuell|Gräber (%ws%)|-|generic
graeber_versionen|p2d2_graeber_versionen|Gräber Versionen (%ws%)|-|polygon'

# Attribut-Mapping (Schritt 4a, nur geo-containers): Native-Spalte -> Ziel-Attribut.
# p2d2_containers hat die Spalte osm_name (kein name); das veröffentlichte Attribut name liest osm_name.
# Kein zusätzlich veröffentlichtes osm_name als Ersatz für name.
ATTR_MAP_TABLE='geo-containers|osm_name|name'

# Layer-ACL-Soll-Tabelle (Schritt 5): Layer | Lesen (.r) | Schreiben (.w).
# %stage% wird durch die P2D2_WFST_<KEY>-Rolle der Stage ersetzt (aus SOL_TABLE, KEY nicht Workspace).
ACL_LAYER_TABLE='geo-containers|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
grabflure|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
graeber|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|ADMIN
grabflure_versionen|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|%stage%,ADMIN
graeber_versionen|ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN|%stage%,ADMIN'

# ═══════════════════════════════════════════════════════════════════════════
# Globals
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_NAME="p2d2-geoserver-config_v1.sh"
NAMESPACE=""
GS_BASE=""          # z. B. https://geoportal.<domain>/geoserver
GS_REST=""          # $GS_BASE/rest
DRY_RUN=0
UNINSTALL=0
# GS_ADMIN_USER/GS_ADMIN_PW werden NICHT vorbelegt: ein in der Umgebung gesetzter
# Wert (Override) muss in preflight() als "${GS_ADMIN_USER:-...}" erhalten bleiben.
HOWTO_FILE=""
HOWTO_FD=3          # Datei-Deskriptor für die How-To-Ausgabe

# Rollen, die wegen noch vorhandener Layer/ACL beim Uninstall NICHT gelöscht werden dürfen (B).
_KEEP_ROLES=()

# Bestand der Workspaces vor dem Install (für Dry-run-Behandlung fehlender Workspaces).
_EXISTING_WS=()

GS_CONFIG_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/geoserver-config" && pwd -P)" || {
  printf '%s\n' 'FEHLER: GeoServer-Konfigurationsdateien fehlen' >&2
  exit 2
}
for part in core catalog security settings; do
  [[ -r "$GS_CONFIG_LIB_DIR/$part.sh" ]] || {
    printf "FEHLER: Konfigurationsdatei fehlt: %s\n" "$part.sh" >&2
    exit 2
  }
done
# shellcheck source=./geoserver-config/core.sh
source "$GS_CONFIG_LIB_DIR/core.sh" || exit 2
# shellcheck source=./geoserver-config/catalog.sh
source "$GS_CONFIG_LIB_DIR/catalog.sh" || exit 2
# shellcheck source=./geoserver-config/security.sh
source "$GS_CONFIG_LIB_DIR/security.sh" || exit 2
# shellcheck source=./geoserver-config/settings.sh
source "$GS_CONFIG_LIB_DIR/settings.sh" || exit 2

# Metadaten-Datei (YAML-Block) liegt neben dem Einstieg im supplement/-Ordner.
GS_METADATA_FILE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/geoserver-metadata.md"
export GS_METADATA_FILE


# ═══════════════════════════════════════════════════════════════════════════
# Logging (ohne Werte/Secrets)
# ═══════════════════════════════════════════════════════════════════════════

# log_gs_error <msg> — Fehler mit optionalem Antworttext (R2).

# Legacy-Umgebungsvariablen: nur Namen melden, nie Werte (K6).

# ═══════════════════════════════════════════════════════════════════════════
# How-To-Ausgabe (A5): pro Schritt Methode/Pfad/Payload/HTTP-Code, ohne Werte.
# ═══════════════════════════════════════════════════════════════════════════

# howto_step "<Methode Pfad>" "<erwartet>" "<erhalten>" "<Beschreibung>"

# ═══════════════════════════════════════════════════════════════════════════
# Argumente
# ═══════════════════════════════════════════════════════════════════════════
usage() {
  printf 'Usage: bash ./%s [--dry-run] [--uninstall] [--allow-incomplete-metadata] [--url BASE] [--ns NAMESPACE] [--help|-h]\n' "$SCRIPT_NAME" >&2
  exit 2
}

print_help() {
  cat <<EOF
${SCRIPT_NAME} — GeoServer-Konfiguration: WFS-T-/WFS-Benutzer, Rollen, Kubernetes-Secrets, Workspaces, Datastores, FeatureTypes und Default-Styles.

Usage: bash ./${SCRIPT_NAME} [--dry-run] [--uninstall] [--url BASE] [--ns NAMESPACE] [--help|-h]

Optionen:
  --dry-run      Nur planen: keine Änderung an GeoServer oder Kubernetes.
  --uninstall    Genau die angelegten Benutzer/Rollen/Secrets/Workspaces/Datastores/FeatureTypes wieder entfernen.
  --allow-incomplete-metadata  Unvollständige Metadaten (TODO/leer) nur als WARN akzeptieren (nur Dev).
  --url BASE     GeoServer-Basis-URL (z. B. https://geoportal.<domain>/geoserver).
  --ns NAMESPACE Kubernetes-Namespace (Standard: ADDON_NS bzw. cc-prd-geodata-stack).
  --help, -h     Diese Hilfe.

Die Dienst-/Layer-Metadaten (Titel, Abstract, Kontakt, Attribution, Genauigkeit)
werden aus supplement/geoserver-metadata.md gelesen und über
geoserver-config/settings.sh angewendet.

Umgebungsvariablen:
  GS_ADMIN_USER, GS_ADMIN_PW   Admin-Zugang für GeoServer-REST. Nur GEMEINSAM setzen;
                               sie haben Vorrang vor dem Secret geoserver-geoserver.

Exit-Codes: 0 = ok, 1 = Fehler, 2 = Aufruf-/Voraussetzungsfehler.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --allow-incomplete-metadata) _GS_ALLOW_INCOMPLETE=1; shift ;;
    --url)
      [[ $# -ge 2 ]] || usage
      GS_BASE="${2%/}"; shift 2 ;;
    --ns)
      [[ $# -ge 2 ]] || usage
      NAMESPACE="$2"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *) log_error "Unbekanntes Argument: $1"; usage ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════
# Konfiguration auflösen (nur diese Schlüssel, nie Komplett-Export)
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# Datastore-Konfiguration (C2): nur diese Schlüssel, keine Defaults im Skript.
# ═══════════════════════════════════════════════════════════════════════════
_DB_HOST=""
_DB_PORT=""
_DB_NAME=""

# _cfg_ok <wert> — 0 wenn gesetzt, nicht leer und nicht CHANGEME.

# load_ds_config — löst die Datastore-Konfiguration auf (nur die benannten Schlüssel).
# Rückgabe 0 ok; 2 bei fehlendem/leerem/CHANGEME-Wert (vor jeder Mutation).

# ADDON_NS
if [[ -z "$NAMESPACE" ]]; then
  NAMESPACE="${ADDON_NS:-}"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="$(_env_resolve ADDON_NS || true)"
  [[ -z "$NAMESPACE" ]] && NAMESPACE="cc-prd-geodata-stack"
fi

# ADDON_DOMAIN (bzw. DOMAIN_NAME → udp.<DOMAIN_NAME>)
if [[ -z "$GS_BASE" ]]; then
  local_addon_domain="${ADDON_DOMAIN:-}"
  [[ -z "$local_addon_domain" ]] && local_addon_domain="$(_env_resolve ADDON_DOMAIN || true)"
  if [[ -z "$local_addon_domain" ]]; then
    local_domain_name="${DOMAIN_NAME:-}"
    [[ -z "$local_domain_name" ]] && local_domain_name="$(_env_resolve DOMAIN_NAME || true)"
    [[ -n "$local_domain_name" ]] && local_addon_domain="udp.${local_domain_name}"
  fi
  [[ -n "$local_addon_domain" ]] && GS_BASE="https://geoportal.${local_addon_domain}/geoserver"
fi
GS_REST="${GS_BASE}/rest"

# ═══════════════════════════════════════════════════════════════════════════
# Kubernetes-Secret-Helfer (selbsttragend; analog addon_03_secrets.sh)
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# Passwort-Generator/Validierung (analog addon_03_secrets.sh)
# ═══════════════════════════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════════════════════════
# GeoServer-REST (Credentials via curl -K - stdin, Body via mktemp 0600)
# ═══════════════════════════════════════════════════════════════════════════
# _curl_user_cfg <user> <pw> — gibt die Zeile `user = "..."` (escaped) auf stdout.
# Escaping gemäß curl -K: innerhalb der Anführungszeichen werden \" und \\ zu " bzw. \.
# Ein CR/LF im Wert würde eine weitere Konfigurationszeile einschleusen -> Fehler.

# _gs_http_code <method> <path> [<payload-file>] [<content-type>]

# _gs_write_body <method> <path> [<payload-file>] [<content-type>] — Schreibaufruf
# (POST/PUT/DELETE) ohne usergroup. Setzt _GS_CODE und _GS_ERR_BODY (erste Antwortzeile,
# max. 200 Zeichen, R2). Wird DIREKT aufgerufen (nicht in einer Subshell), damit die
# globalen Variablen in der aufrufenden Shell ankommen.
_GS_ERR_BODY=""

# ═══════════════════════════════════════════════════════════════════════════
# Preflight
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# Bestand lesen (Benutzer + Rollen), nie Passwörter. Statusbewusst (K8):
# ein HTTP-Fehler ist ein Fehler, keine leere Liste.
# ═══════════════════════════════════════════════════════════════════════════
_GS_CODE=""      # global: HTTP-Code des letzten _gs_get
_GS_BODY_FILE=""  # global: Temp-Datei mit dem Body des letzten _gs_get

# _gs_get <path> — GET; setzt _GS_CODE und _GS_BODY_FILE (Body in Datei).
# Wird direkt (nicht in einer Kommando-Substitution) aufgerufen, damit die
# globalen Variablen in der aufrufenden Shell ankommen.

# read_users — Benutzernamen (sortiert) auf stdout; 0 ok, 1 Lesefehler.

# read_roles — Rollen (sortiert) auf stdout; 0 ok, 1 Lesefehler.

# read_user_roles <user> — Rollen eines Benutzers; 200/404 = ok (404 => leer).

# read_workspaces — Workspace-Namen (sortiert) auf stdout; 0 ok, 1 Fehler.
# Akzeptiert .workspaces.workspace als Array oder als ""/null (leer).

# read_namespace_uri <ws> — Namespace-URI auf stdout (leer bei Fehler); 0 ok, 1 Fehler.

# read_available_natives <ws> <ds> — verfügbare Native-Namen (list=available); 0 ok, 1 Fehler.

# read_featuretypes <ws> <ds> — publizierte FeatureType-Namen; 0 ok, 1 Fehler.
# Akzeptiert .featureTypes.featureType als Array, .featureTypes als ""/null (leer) und 404 (leer).

# read_datastores <ws> — Datastore-Namen (sortiert) für einen Workspace; 0 ok, 1 Fehler.
# Akzeptiert .dataStores.dataStore als Array, .dataStores als ""/null (leer) und 404 (leer).

# _ds_present <ws> <ds> — 0 wenn der Datastore existiert (der Workspace ist damit implizit vorhanden),
# 1 wenn nicht, 2 bei Lesefehler. read_datastores liefert 404 = leer (Workspace fehlt).

# _http_code_url <url> — authentifizierter GET auf eine beliebige URL; gibt HTTP-Code.

# _gs_get_url <url> — authentifizierter GET auf eine beliebige URL (z. B. WFS-Dienst);
# setzt _GS_CODE und _GS_BODY_FILE. Wird direkt aufgerufen (nicht in einer Subshell).

# Globaler Bestand (K8), nach dem Preflight einmal gelesen.
_INV_USERS=()
_INV_ROLES=()
_USER_ROLES=()

# _read_user_roles_into <user> — liest Rollen in das globale Array _USER_ROLES; 0 ok, 1 Fehler.

# _load_inventory — liest Benutzer+Rollen, prüft Plausibilität (admin/ADMIN).
# Rückgabe 0 ok; 2 bei Lesefehler oder Plausibilitätsfehler (vor jeder Mutation).

# _has <needle> <items...> — 0 wenn needle enthalten.

# _inventory_plausible <users_array_name> <roles_array_name> — 0 wenn Admin-Benutzer
# und ADMIN-Rolle vorhanden, sonst 1 (Meldung ohne Werte). Namerefs, bash >= 4.3.

# Sicherheitsnetz: Soll-Tabelle darf nie admin/p2d2_wfst_user enthalten.

# Startprüfung: jeder Workspace aus SOL_TABLE (Spalte 2, außer "-") muss in WS_TABLE stehen.

# _ws_uri <ws> — Namespace-URI aus WS_TABLE; 0 ok, 1 nicht gefunden.

# Startprüfung (C1): jeder DS_TABLE-KEY steht in SOL_TABLE, jeder Workspace in WS_TABLE.

# Startprüfung (D1): die eingebauten Default-Styles polygon/generic müssen existieren.

# ═══════════════════════════════════════════════════════════════════════════
# Install
# ═══════════════════════════════════════════════════════════════════════════
do_install() {
  local -a existing_users existing_roles
  local line key _ user roles secret role password
  local f

  existing_users=("${_INV_USERS[@]}")
  existing_roles=("${_INV_ROLES[@]}")

  log "== Soll/Ist: Benutzer und Rollen =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    local ustate rstate
    ustate="fehlt"; _has "$user" "${existing_users[@]}" && ustate="vorhanden"
    rstate="vorhanden"
    for role in ${roles//,/ }; do
      _has "$role" "${existing_roles[@]}" || rstate="fehlt"
    done
    printf '  %-8s user=%-20s (%s)  rollen=%s\n' "$key" "$user" "$ustate" "$rstate"
  done <<< "$SOL_TABLE"

  # Rollen anlegen (idempotent)
  local -a all_roles
  all_roles=()
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      _has "$role" "${all_roles[@]}" || all_roles+=("$role")
    done
  done <<< "$SOL_TABLE"

  log "== Rollen =="
  for role in "${all_roles[@]}"; do
    if _has "$role" "${existing_roles[@]}"; then
      log "  Rolle vorhanden: $role"
    else
      log "  Rolle anlegen: $role"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "POST security/roles/role/$role" "200/201" "-" "idempotent"
        continue
      fi
      local code
      code="$(_gs_http_code POST "security/roles/role/$role")"
      howto_step "POST security/roles/role/$role" "200/201" "$code" "idempotent"
      [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Rolle $role anlegen fehlgeschlagen (HTTP $code)"; return 1; }
      log_ok "  Rolle $role angelegt"
    fi
  done

  log "== Benutzer + Secrets =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue

    # Passwort aus Secret übernehmen oder erzeugen (Secret = Single Source of Truth).
    # Kein Env-Stage (E3): nur Secret -> erzeugt.
    password="$(_secret_get "$NAMESPACE" "$secret" "password")"
    if _pw_is_valid "$password"; then
      log "  ${key}: Secret-Wert wiederverwendet"
    else
      password="$(_pw_gen)"
      log "  ${key}: neues Passwort erzeugt"
      howto "kubectl -n $NAMESPACE apply secret $secret (Key password) — Wert nicht ausgegeben"
      if [[ "$DRY_RUN" -eq 0 ]]; then
        if ! _secret_apply "$NAMESPACE" "$secret" "password=$password"; then
          log_error "Secret $secret konnte nicht gespeichert werden — Abbruch vor GeoServer-Änderung"
          return 1
        fi
      fi
    fi

    # GeoServer: Benutzer anlegen oder Passwort setzen.
    local uexists
    uexists="nein"; _has "$user" "${existing_users[@]}" && uexists="ja"

    if [[ "$uexists" == "nein" ]]; then
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><userName>%s</userName><password>%s</password><enabled>true</enabled></user>\n' "$user" "$password" > "$f"
        local code
        code="$(_gs_http_code POST 'security/usergroup/users' "$f" 'text/xml')"
        rm -f "$f"
        howto_step "POST security/usergroup/users" "200/201" "$code" "XML <user><userName>$user</userName><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml"
        [[ "$code" == "200" || "$code" == "201" ]] || { log_error "Benutzer $user anlegen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Benutzer $user angelegt"
      else
        howto_step "POST security/usergroup/users" "200/201" "-" "XML <user><userName>$user</userName><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml (geplant)"
        log "  Benutzer $user würde angelegt (dry-run)"
      fi
    else
      if [[ "$DRY_RUN" -eq 0 ]]; then
        f="$(mktemp)"; chmod 600 "$f"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<user><password>%s</password><enabled>true</enabled></user>\n' "$password" > "$f"
        local code
        code="$(_gs_http_code POST "security/usergroup/user/$user" "$f" 'text/xml')"
        rm -f "$f"
        howto_step "POST security/usergroup/user/$user" "200" "$code" "XML <user><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml — Passwort setzen, Benutzer aktivieren"
        [[ "$code" == "200" ]] || { log_error "Passwort für $user setzen fehlgeschlagen (HTTP $code)"; return 1; }
        log_ok "  Passwort für $user gesetzt"
      else
        howto_step "POST security/usergroup/user/$user" "200" "-" "XML <user><password><PASSWORD></password><enabled>true</enabled></user>, Content-Type text/xml — Passwort setzen, Benutzer aktivieren (geplant)"
        log "  Passwort für $user würde gesetzt (dry-run)"
      fi
    fi

    # Rollen zuordnen (idempotent, POST)
    for role in ${roles//,/ }; do
      if [[ "$DRY_RUN" -eq 0 ]]; then
        local code
        code="$(_gs_http_code POST "security/roles/role/$role/user/$user")"
        howto_step "POST security/roles/role/$role/user/$user" "200" "$code" "idempotent"
        [[ "$code" == "200" ]] || { log_error "Zuordnung $role -> $user fehlgeschlagen (HTTP $code)"; return 1; }
      else
        howto_step "POST security/roles/role/$role/user/$user" "200" "-" "idempotent (geplant)"
      fi
    done
  done <<< "$SOL_TABLE"

  # Workspaces anlegen (Schritt 2, nach Benutzern/Rollen/Zuordnungen)
  install_workspaces || return 1

  # Workspace-Einstellungen + Dienst-Metadaten (nach Workspaces, vor Datastores)
  install_workspace_settings || return 1
  install_service_metadata || return 1

  # Datastores anlegen (Schritt 3)
  install_datastores || return 1

  # FeatureTypes anlegen (Schritt 4)
  install_featuretypes || return 1

  # Attribut-Mapping anlegen (Schritt 4a)
  install_attr_mapping || return 1

  # Layer-ACLs anlegen (Schritt 5)
  install_acls || return 1

  # Verifikation (im Dry-run übersprungen, K1)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  Verifikation wird im Dry-run übersprungen"
  else
    verify_install || return 1
    verify_workspaces || return 1
    verify_workspace_settings || return 1
    verify_service_metadata || return 1
    verify_datastores || return 1
    verify_featuretypes || return 1
    verify_attr_mapping || return 1
    verify_acls || return 1
  fi
  return 0
}

verify_install() {
  local line key _ user roles secret password code neg
  log "== Verifikation =="
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    password="$(_secret_get "$NAMESPACE" "$secret" "password")"
    [[ -n "$password" ]] || { log_error "Verifikation $key: kein Passwort im Secret"; return 1; }

    # Positivtest (authentifizierter GetCapabilities) — Credentials via curl -K - (stdin)
    code="$( _curl_user_cfg "$user" "$password" | curl -sS -K - "${GS_CURL_TMO[@]}" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || code="000"

    # Negativtest (falsches Passwort muss 401 liefern)
    neg="$( _curl_user_cfg "$user" "falsch_${password}" | curl -sS -K - "${GS_CURL_TMO[@]}" -o /dev/null -w '%{http_code}' "$GS_BASE/ows?service=WFS&version=2.0.0&request=GetCapabilities" 2>/dev/null )" || neg="000"

    if [[ "$code" != "200" ]]; then
      log_error "Verifikation $key: GetCapabilities HTTP $code (erwartet 200)"
      return 1
    fi
    if [[ "$neg" == "200" ]]; then
      log_warn "Verifikation $key: Negativtest lieferte 200 — Positivprüfung nicht aussagekräftig"
    elif [[ "$neg" != "401" ]]; then
      log_warn "Verifikation $key: Negativtest HTTP $neg (erwartet 401)"
    else
      log_ok "  $key: 200 (positiv), 401 (negativ) — Anmeldung wird ausgewertet"
    fi

    # Rollenliste je Benutzer (Soll ⊆ Ist)
    if ! _read_user_roles_into "$user"; then
      log_error "Verifikation $key: Rollen für $user nicht lesbar"
      return 1
    fi
    for role in ${roles//,/ }; do
      _has "$role" "${_USER_ROLES[@]}" || { log_error "Verifikation $key: Rolle $role fehlt bei $user"; return 1; }
    done
  done <<< "$SOL_TABLE"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Workspaces (Schritt 2): anlegen / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════



# ═══════════════════════════════════════════════════════════════════════════
# Datastores (Schritt 3): anlegen / aktualisieren / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════
# _ds_body <name> <schema> <host> <port> <db> <user> <ns> <password> <outfile>
# Baut den vollständigen PostGIS-Datastore-Body (20 Parameter). Das Passwort wird
# nur per --rawfile über Prozesssubstitution eingelesen (printf ist Builtin), damit
# es in keiner Argumentliste von jq auftaucht (C3).




# ═══════════════════════════════════════════════════════════════════════════
# FeatureTypes + Default-Styles (Schritt 4): anlegen / verifizieren / löschen
# ═══════════════════════════════════════════════════════════════════════════
# _ft_title <template> <ws> — ersetzt %ws% im Titelmuster durch den Workspace-Namen.

# _ft_body <name> <native> <ws> <title> <cache> <outfile> — FeatureType-Body (kein Passwort).

# _ft_cmp <body-file> <ws> <name> <native> <title> <cache> — 0 wenn alle nicht generierten
# Felder stimmen, sonst 1. Abweichungen werden als Info (log) gemeldet; erst ein fehlgeschlagener
# PUT ist ein Fehler (B5). Bounding-Box-Vergleich numerisch; metadata.entry als Objekt ODER Array.

# _ensure_default_style <ws> <name> <style> — setzt bei Abweichung den Layer-Default-Style.




# ═══════════════════════════════════════════════════════════════════════════
# Attribut-Mapping (Schritt 4a): veröffentlichtes Attribut liest eine Native-Spalte
# ═══════════════════════════════════════════════════════════════════════════
# _apply_attr_mapping <ws> <ds> <name> <native> <target> — 0 ok, 1 Fehler.
# Liest die generierte Attributliste, benennt <native> nach <target> um und setzt source=<native>.



# ═══════════════════════════════════════════════════════════════════════════
# Layer-ACLs (Schritt 5): explizite Lese-/Schreib-Regeln, keine Wildcards
# ═══════════════════════════════════════════════════════════════════════════
# _stage_role <key> — P2D2_WFST_<KEY> aus SOL_TABLE.

# _acl_roles_equal <a> <b> — 0 wenn gleiche Rollenmenge (Reihenfolge egal).

# _acl_get <outfile> — Layer-ACL-Map ({"<rule>":"<roles>"}) nach <outfile>; 0 ok, 1 Fehler.

# _protect_roles <comma-roles> — merkt sich Rollen, die beim Uninstall NICHT gelöscht werden.

# _acl_apply <ws> <layer> <mode> <roles> <mapfile> — 0 ok, 1 Konflikt/Fehler.




# ═══════════════════════════════════════════════════════════════════════════
# Uninstall (nur exakt benannte Objekte)
# ═══════════════════════════════════════════════════════════════════════════
do_uninstall() {
  local line key _ user roles secret code rc=0 role
  local -a existing_users existing_roles
  log "== Uninstall =="

  # Bestand aus _load_inventory (in main gelesen + plausibel geprüft, K8).
  existing_users=("${_INV_USERS[@]}")
  existing_roles=("${_INV_ROLES[@]}")

  # 0) FeatureTypes/Layer entfernen (Reihenfolge umgekehrt zum Install; vor Datastores)
  uninstall_featuretypes || rc=1

  # 0a) Layer-ACLs entfernen (nach Layern, vor Rollen; behält Regeln/Rollen bei verbliebenem Layer)
  uninstall_acls || rc=1

  # 0b) Datastores entfernen (vor Workspaces)
  uninstall_datastores || rc=1

  # 0b) Workspaces entfernen (vor Benutzern/Rollen/Secrets)
  uninstall_workspaces || rc=1

  # 1) Rollenzuordnungen lösen (nur vorhandene)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if ! _read_user_roles_into "$user"; then
      log_error "Rollen für $user nicht lesbar — Zuordnungen übersprungen"
      rc=1
      continue
    fi
    for role in ${roles//,/ }; do
      if ! _has "$role" "${_USER_ROLES[@]}"; then
        log "  Zuordnung $role/$user nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] Zuordnung $role/$user wuerde entfernt"
        howto_step "DELETE security/roles/role/$role/user/$user" "200" "-" "404 = schon weg"
        continue
      fi
      _gs_write_body DELETE "security/roles/role/$role/user/$user"
      code="$_GS_CODE"
      howto_step "DELETE security/roles/role/$role/user/$user" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Zuordnung $role/$user gelöst" ;;
        404)     log "  Zuordnung $role/$user schon weg" ;;
        *)       log_gs_error "Zuordnung $role/$user lösen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  # 2) Benutzer löschen (nur vorhandene)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    if ! _has "$user" "${existing_users[@]}"; then
      log "  Benutzer $user nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] Benutzer $user wuerde entfernt"
      howto_step "DELETE security/usergroup/user/$user" "200" "-" "404 = schon weg"
      continue
    fi
    _gs_write_body DELETE "security/usergroup/user/$user"
    code="$_GS_CODE"
    howto_step "DELETE security/usergroup/user/$user" "200" "$code" "404 = schon weg"
    case "$code" in
      200|201) log_ok "  Benutzer $user gelöscht" ;;
      404)     log "  Benutzer $user schon weg" ;;
      *)       log_gs_error "Benutzer $user löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$SOL_TABLE"

  # 3) Rollen löschen (nur vorhandene; von noch vorhandenen Layer-ACLs benötigte Rollen bleiben, B)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    for role in ${roles//,/ }; do
      if _has "$role" "${_KEEP_ROLES[@]}"; then
        log "  Rolle $role bleibt (von noch vorhandener Layer-ACL benötigt)"
        continue
      fi
      if ! _has "$role" "${existing_roles[@]}"; then
        log "  Rolle $role nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] Rolle $role wuerde entfernt"
        howto_step "DELETE security/roles/role/$role" "200" "-" "404 = schon weg"
        continue
      fi
      _gs_write_body DELETE "security/roles/role/$role"
      code="$_GS_CODE"
      howto_step "DELETE security/roles/role/$role" "200" "$code" "404 = schon weg"
      case "$code" in
        200|201) log_ok "  Rolle $role gelöscht" ;;
        404)     log "  Rolle $role schon weg" ;;
        *)       log_gs_error "Rolle $role löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done
  done <<< "$SOL_TABLE"

  # GeoServer-Teil fehlgeschlagen -> Secrets NICHT löschen (bleiben autoritativ)
  [[ "$rc" -eq 0 ]] || { log_error "GeoServer-Teil fehlgeschlagen — Secrets bleiben bestehen"; return 1; }

  # 4) Secrets löschen (exakte Namen)
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    howto "kubectl -n $NAMESPACE delete secret $secret --ignore-not-found"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] Secret $secret wuerde entfernt"
      continue
    fi
    kubectl -n "$NAMESPACE" delete secret "$secret" --ignore-not-found >/dev/null 2>&1 \
      || { log_error "Secret $secret löschen fehlgeschlagen"; rc=1; }
  done <<< "$SOL_TABLE"

  [[ "$rc" -eq 0 ]] || return 1

  # Verifikation (im Dry-run übersprungen, K2)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  Verifikation wird im Dry-run übersprungen"
    return 0
  fi

  local -a after_users after_roles
  local ftmp
  ftmp="$(mktemp)"; chmod 600 "$ftmp"
  if ! read_users > "$ftmp"; then
    rm -f "$ftmp"; log_error "Schlussverifikation: Benutzerliste nicht lesbar"; return 1
  fi
  mapfile -t after_users < "$ftmp"
  if ! read_roles > "$ftmp"; then
    rm -f "$ftmp"; log_error "Schlussverifikation: Rollenliste nicht lesbar"; return 1
  fi
  mapfile -t after_roles < "$ftmp"
  rm -f "$ftmp"
  _inventory_plausible after_users after_roles || { log_error "Schlussverifikation: Bestand unplausibel"; return 1; }
  while IFS='|' read -r key _ user roles secret; do
    [[ -n "$key" ]] || continue
    _has "$user" "${after_users[@]}" && { log_error "Benutzer $user noch vorhanden"; rc=1; }
    for role in ${roles//,/ }; do
      _has "$role" "${after_roles[@]}" && { log_error "Rolle $role noch vorhanden"; rc=1; }
    done
    kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1 && { log_error "Secret $secret noch vorhanden"; rc=1; }
  done <<< "$SOL_TABLE"

  # Workspaces: nicht mehr gelistet (Schritt 2)
  local -a after_ws
  local wtmp ws
  wtmp="$(mktemp)"; chmod 600 "$wtmp"
  if ! read_workspaces > "$wtmp"; then
    rm -f "$wtmp"; log_error "Schlussverifikation: Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t after_ws < "$wtmp"
  rm -f "$wtmp"
  while IFS='|' read -r ws _; do
    [[ -n "$ws" ]] || continue
    _has "$ws" "${after_ws[@]}" && { log_error "Workspace $ws noch vorhanden"; rc=1; }
  done <<< "$WS_TABLE"

  # Datastores: nicht mehr gelistet (Schritt 3)
  local -a after_ds
  local dtmp dkey dws dname
  dtmp="$(mktemp)"; chmod 600 "$dtmp"
  while IFS='|' read -r dkey dws dname _ _ _; do
    [[ -n "$dkey" ]] || continue
    if ! read_datastores "$dws" > "$dtmp"; then
      rm -f "$dtmp"; log_error "Schlussverifikation: Datastore-Liste für $dws nicht lesbar"; return 1
    fi
    mapfile -t after_ds < "$dtmp"
    _has "$dname" "${after_ds[@]}" && { log_error "Datastore $dname noch vorhanden"; rc=1; }
  done <<< "$DS_TABLE"
  rm -f "$dtmp"

  # FeatureTypes: nicht mehr gelistet (Schritt 4). Datastore, den der Uninstall
  # bereits gelöscht hat, wird übersprungen (B1); nur echte Lesefehler sind Fehler.
  local -a after_ft
  local ftmp fkey fws fds fname fdsp
  ftmp="$(mktemp)"; chmod 600 "$ftmp"
  while IFS='|' read -r fkey fws fds _ _ _; do
    [[ -n "$fkey" ]] || continue
    _ds_present "$fws" "$fds"; fdsp=$?
    if [[ "$fdsp" -eq 1 ]]; then
      continue
    fi
    if [[ "$fdsp" -eq 2 ]]; then
      rm -f "$ftmp"; log_error "Schlussverifikation: Datastore-Präsenz für $fws/$fds nicht lesbar"; return 1
    fi
    if ! read_featuretypes "$fws" "$fds" > "$ftmp"; then
      rm -f "$ftmp"; log_error "Schlussverifikation: FeatureType-Liste für $fws/$fds nicht lesbar"; return 1
    fi
    mapfile -t after_ft < "$ftmp"
    while IFS='|' read -r fname _ _ _ _; do
      [[ -n "$fname" ]] || continue
      _has "$fname" "${after_ft[@]}" && { log_error "FeatureType $fname noch vorhanden"; rc=1; }
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  rm -f "$ftmp"

  [[ "$rc" -eq 0 ]] && log_ok "Uninstall verifiziert (alle Soll-Objekte entfernt)"
  return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# Haupt
# ═══════════════════════════════════════════════════════════════════════════
main() {
  umask 077
  GS_TMPDIR="$(mktemp -d)" || exit 2
  export TMPDIR="$GS_TMPDIR"
  trap 'rm -rf -- "$GS_TMPDIR"' EXIT

  warn_legacy_vars
  preflight
  load_metadata || exit 2
  _load_inventory || exit 2

  # How-To-Datei vorbereiten (R3: Modus im Namen, damit Install/Uninstall nicht kollidieren)
  local howto_mode git_hash mode
  if [[ "$UNINSTALL" -eq 1 ]]; then
    [[ "$DRY_RUN" -eq 1 ]] && howto_mode="uninstall-dry-run" || howto_mode="uninstall"
  else
    [[ "$DRY_RUN" -eq 1 ]] && howto_mode="install-dry-run" || howto_mode="install"
  fi
  HOWTO_FILE="p2d2-geoserver-config_v1_${howto_mode}_$(date +%Y%m%d-%H%M%S).howto.md"
  exec 3> "$HOWTO_FILE"

  git_hash="$(git rev-parse --short HEAD 2>/dev/null || true)"
  [[ -n "$git_hash" ]] || git_hash="unbekannt"
  mode="$([[ "$DRY_RUN" -eq 1 ]] && echo 'dry-run (geplant)' || echo 'ausgeführt')"

  howto "# How-To: GeoServer-Konfiguration: Benutzer/Rollen/Secrets/Workspaces/Datastores/FeatureTypes (${SCRIPT_NAME})"
  howto "Git-Hash: ${git_hash}"
  howto "Zeitpunkt: $(date -Is)"
  howto "Modus: ${mode}"
  howto "GeoServer: ${GS_BASE}"
  howto "Namespace: ${NAMESPACE}"
  howto ""
  howto "## Konventionen"
  howto '- Authentifizierung: curl -K - mit `user = "<user>:<password>"` über stdin (Anführungszeichen und Backslash im Wert escapen).'
  howto '- Request-Bodies: mktemp-Datei (Mode 0600), `--data-binary @datei`.'
  howto '- Passwort: `openssl rand -hex 24`, mind. 16 Zeichen, Zeichensatz A-Za-z0-9._~@%+=:,/- .'
  howto '- Secret: Typ Opaque, Key `password`, Merge-Manifest per `kubectl apply`, Wert base64.'
  howto '- Admin-Zugang: Secret `geoserver-geoserver`, Keys `geoserver-user`/`geoserver-password`.'
  howto ""
  howto "## Lesende Schritte"
  howto 'GET security/roles.json             -> {"roles":["ADMIN",...]}'
  howto 'GET security/usergroup/users.json   -> {"users":[{"userName":...,"enabled":true},...]}'
  howto 'GET security/roles/user/<user>.json -> {"roles":[...]}  (404 = leer)'
  howto ""
  howto "## Secret-Schritte"
  howto "Lesen:   kubectl -n ${NAMESPACE} get secret <name> -o jsonpath='{.data.password}' (Wert nie ausgeben)"
  howto "Anlegen: kubectl apply -f <manifest> mit"
  howto '  {"apiVersion":"v1","kind":"Secret","metadata":{"name":"<name>","namespace":"<ns>"},"type":"Opaque","data":{"password":"<BASE64>"}}'
  howto "Löschen: kubectl -n ${NAMESPACE} delete secret <name> --ignore-not-found"
  howto ""
  howto "## Verifikation"
  howto "Positiv: GET ${GS_BASE}/ows?service=WFS&version=2.0.0&request=GetCapabilities (Basic <user>) -> 200"
  howto "Negativ: gleiches mit falschem Passwort -> 401"
  howto "Rollen:  GET security/roles/user/<user>.json; Soll-Rollen müssen enthalten sein."
  howto ""
  howto "## Entscheidungslogik"
  howto "- Secret: wiederverwenden, wenn ein gültiger Wert vorhanden ist, sonst neu erzeugen."
  howto "- Benutzer: anlegen (POST usergroup/users) oder Passwort setzen (POST usergroup/user/<name>)."
  howto "- Uninstall: nur Vorhandenes löschen; 404 gilt als 'schon weg'."
  howto "- Reihenfolge Install: Rollen -> je Benutzer Secret -> Benutzer -> Zuordnungen -> Workspaces -> Datastores -> FeatureTypes -> Default-Styles -> Verifikation."
  howto "- Reihenfolge Uninstall: Layer -> FeatureTypes -> Datastores -> Workspaces -> Zuordnungen -> Benutzer -> Rollen -> Secrets -> Verifikation."
  howto ""
  howto "## Workspaces"
  howto 'GET workspaces.json        -> {"workspaces":{"workspace":[{"name":...,"href":...}]}}'
  howto 'GET namespaces/<ws>.json  -> {"namespace":{"prefix":...,"uri":...}}'
  howto 'GET workspaces/<ws>.json  -> {"workspace":{"name":...}}'
  howto 'POST namespaces           -> {"namespace":{"prefix":"<ws>","uri":"<uri>"}} (Content-Type application/json); 200/201 = ok'
  howto 'DELETE workspaces/<ws>    -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- Anlegen: Workspace fehlt -> POST namespaces (legt Workspace und Namespace an).'
  howto '- Vorhanden: GET namespaces/<ws>.json; URI gleich -> ok, abweichend/fehlt -> Fehler, keine Änderung.'
  howto '- Verifikation: namespaces/<ws>.json URI, workspaces/<ws>.json name, WMS/WFS GetCapabilities.'
  howto ""
  howto "## Datastores"
  howto 'GET workspaces/<ws>/datastores.json            -> {"dataStores":{"dataStore":[{"name":...,"href":...}]}}  ("" = leer)'
  howto 'GET workspaces/<ws>/datastores/<ds>.json      -> {"dataStore":{"name":...,"connectionParameters":{"entry":[{"@key":...,"$":...}]}}}'
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes.json?list=available -> {"list":{"string":[...]}} (DB-Verbindungstest)'
  howto 'POST workspaces/<ws>/datastores               -> 201 (200/201 = ok); Body: 20 connectionParameters'
  howto 'PUT  workspaces/<ws>/datastores/<ds>          -> 200; Body: 20 connectionParameters (vollständig)'
  howto 'DELETE workspaces/<ws>/datastores/<ds>        -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- 20 Parameter: schema, user, namespace, passwd, host, port, database variabel; dbtype=postgis, Estimated extends=false, fetch size=1000, encode functions=false, Expose primary keys=true, validate connections=true, Support on the fly geometry simplification=false, Connection timeout=20, create database=false, preparedStatements=false, reWriteBatchedInserts=false, Loose bbox=false, Test while idle=false fest.'
  howto '- passwd: aus Secret <name> (Key DB_PASSWORD), nur lesend, nie in einer Argumentliste.'
  howto '- Wertequellen: host/port/database aus P2D2_BASE_DB_HOST/PORT/NAME, user aus P2D2_<KEY>_DB_USER, schema aus DS_TABLE, namespace aus WS_TABLE.'
  howto '- Anlegen (fehlt): POST; Vorhanden: PUT (vollständiger Body).'
  howto ""
  howto "## FeatureTypes/Layer"
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes.json            -> {"featureTypes":{"featureType":[{"name":...}]}}  ("" = leer)'
  howto 'GET workspaces/<ws>/datastores/<ds>/featuretypes/<name>.json    -> {"featureType":{"name":...,"nativeName":...}}'
  howto 'POST workspaces/<ws>/datastores/<ds>/featuretypes               -> 201 (200/201 = ok)'
  howto 'PUT  workspaces/<ws>/datastores/<ds>/featuretypes/<name>        -> 200 (nur bei Abweichung)'
  howto 'GET workspaces/<ws>/layers/<name>.json                          -> {"layer":{"defaultStyle":{"name":...}}}'
  howto 'PUT  workspaces/<ws>/layers/<name>                              -> 200 (defaultStyle setzen)'
  howto 'DELETE workspaces/<ws>/layers/<name>                            -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto 'DELETE workspaces/<ws>/datastores/<ds>/featuretypes/<name>      -> 200 = gelöscht, 404 = schon weg, ohne recurse'
  howto '- Body: name, nativeName, namespace, title, keywords, srs=EPSG:4326, projectionPolicy=FORCE_DECLARED, enabled/advertised=true, beide BoundingBoxes; cachingEnabled nur bei grabflure* = false.'
  howto '- Default-Styles: polygon/generic (eingebaute GeoServer-Stile).'
  howto '- Verifikation: FeatureType (enabled/advertised/nativeName/title/srs), Layer defaultStyle, DescribeFeatureType/GetFeature hits (kein ExceptionReport).'
  howto '- Wertequellen: FT_TABLE (Name/Native/Titel/Default-Style), Workspace aus DS_TABLE.'
  howto ''
  howto 'Body (POST/PUT, alle Werte per jq --arg; kein Passwort beteiligt):'
  howto '  {"featureType":{"name":"<name>","nativeName":"<native>","namespace":{"name":"<ws>"},"title":"<title>",'
  howto '    "keywords":{"string":["features","<native>"]},"srs":"EPSG:4326","projectionPolicy":"FORCE_DECLARED",'
  howto '    "enabled":true,"advertised":true,'
  howto '    "nativeBoundingBox":{"minx":-10,"maxx":40,"miny":35,"maxy":71,"crs":"EPSG:4326"},'
  howto '    "latLonBoundingBox":{"minx":-10,"maxx":40,"miny":35,"maxy":71,"crs":"EPSG:4326"}}};'
  howto '  nur grabflure/grabflure_versionen zusätzlich: "metadata":{"entry":{"@key":"cachingEnabled","$":"false"}}'
  howto ''
  howto 'FT_TABLE (Name | Native-Name | Titelmuster %ws% | cachingEnabled | Default-Style):'
  howto '  geo-containers|p2d2_containers|Geo-Containers (%ws%)|-|polygon'
  howto '  grabflure|v_grabflure_aktuell|grabflure_aktuell|false|polygon'
  howto '  grabflure_versionen|p2d2_grabflure_versionen|grabflure_versionen|false|polygon'
  howto '  graeber|v_graeber_aktuell|Gräber (%ws%)|-|generic'
  howto '  graeber_versionen|p2d2_graeber_versionen|Gräber Versionen (%ws%)|-|polygon'
  howto ''
  howto '- Hinweise (VM): POST featuretypes legt den Layer mit passendem Default-Style an.'
  howto '  featuretypes.json eines nicht vorhandenen Datastores -> HTTP 500; list=available eines nicht vorhandenen Workspaces -> HTTP 404; datastores.json eines nicht vorhandenen Workspaces -> HTTP 404.'
  howto ""

  howto "## Ausgeführte Schritte"

  if [[ "$UNINSTALL" -eq 1 ]]; then
    do_uninstall || { exec 3>&-; exit 1; }
  else
    do_install || { exec 3>&-; exit 1; }
  fi

  exec 3>&-
  log_ok "How-To geschrieben: ${HOWTO_FILE}"
  [[ "$DRY_RUN" -eq 1 ]] && log "Dry-run: keine Änderungen vorgenommen."
  exit 0
}

main "$@"

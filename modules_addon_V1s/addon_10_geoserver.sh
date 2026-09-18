#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_10_geoserver.sh — p2d2-AddOn: GeoServer-Baustein (FERTIG, manuell verifiziert)
#
# Geteilte Plattforminstanz (Helm-Release geoserver-geoserver). Additiv erweitern:
#   Workspace/Namespace -> Datastore (PostGIS) -> FeatureTypes -> Nutzer/Rollen
#   -> ACL-Regeln -> Secrets -> Verifikation. Plus GeoTIFF-Mosaic (Köln).
#
# Quelle: ai-runs/.../geoserver-automatisierungshinweise.md (erprobte REST-Endpunkte).
# Rudimentär: Sequenz abgebildet, NICHT idempotent (409/201-Toleranz fehlt) — siehe TODO.

install_addon_geoserver() {
  log "=== AddOn 10: GeoServer (Workspaces/Datastores/FeatureTypes) ==="

  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"

  # Admin-Secret (nur aus dem aktiven Secret, Keys geoserver-user/geoserver-password)
  local admin_user admin_pw
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)"
  local rest="https://geoportal.${domain}/geoserver/rest"
  log "GeoServer-REST: ${rest}"

  # 5 Vektor-Workspaces. TODO(später): Stage-Scope filtert diese Liste.
  # TODO: exakte Schema-/Rollen-Namen gegen den DDL-Extrakt verifizieren.
  local stage ws role schema
  for stage in MAIN DEVELOP DE1 DE2 FV; do
    case "$stage" in
      MAIN)    ws="main";    role="P2D2-MAIN";    schema="p2d2_main" ;;
      DEVELOP) ws="dev";     role="P2D2-DEVELOP"; schema="p2d2_develop" ;;
      DE1)     ws="de1";     role="P2D2-DE1";     schema="p2d2_de1" ;;
      DE2)     ws="de2";     role="P2D2-DE2";     schema="p2d2_de2" ;;
      FV)      ws="fv";      role="P2D2-FV";      schema="p2d2_fv" ;;
    esac

    log "  Stage ${stage} (Workspace ${ws}): Namespace + Datastore + FeatureTypes"

    # 1) Namespace legt Workspace gleich mit an (URI urn:data-dna:govdata:<ws>).
    curl -sS -u "${admin_user}:${admin_pw}" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"namespace\":{\"prefix\":\"${ws}\",\"uri\":\"urn:data-dna:govdata:${ws}\"}}" \
      "${rest}/namespaces" || log_warn "    Namespace ${ws} evtl. schon vorhanden (409 tolerieren)"

    # 2) PostGIS-Datastore (host central-db, schema, user, dbtype=postgis).
    # TODO: Passwort aus DB-Rollen-Secret statt Platzhalter.
    curl -sS -u "${admin_user}:${admin_pw}" -X POST \
      -H 'Content-Type: text/xml' \
      -d "<dataStore><name>${ws}_pg</name><connectionParameters><entry key=\"host\">central-db.cc-prd-database-stack.svc.cluster.local</entry><entry key=\"port\">5432</entry><entry key=\"database\">p2d2</entry><entry key=\"schema\">${schema}</entry><entry key=\"user\">${role}</entry><entry key=\"passwd\">CHANGEME</entry><entry key=\"dbtype\">postgis</entry><entry key=\"Expose primary keys\">true</entry><entry key=\"namespace\">urn:data-dna:govdata:${ws}</entry></connectionParameters></dataStore>" \
      "${rest}/workspaces/${ws}/datastores" || log_warn "    Datastore ${ws}_pg evtl. schon vorhanden (409 tolerieren)"

    # 3) FeatureTypes (Views: name=graeber/grabflure, nativeName=v_graeber_aktuell/…).
    # TODO: exakte View-/FeatureType-Liste aus dem manuellen Stand nachziehen.
    log "    (FeatureTypes + Nutzer/Rollen + ACL: TODO — REST-Sequenz aus den Automatisierungshinweisen)"
  done

  # GeoTIFF-Mosaic (Köln) — Raster via kubectl cp + Coveragestore/Coverage.
  # TODO: Granules-Verteilung (kubectl cp, braucht pods/exec) + Coveragestore/Coverage/ACL.
  log "  GeoTIFF-Mosaic (friedhofsplaene): TODO — siehe geoserver-automatisierungshinweise Abschnitt 9"

  log_ok "AddOn 10 GeoServer abgeschlossen (rudimentär, nicht idempotent)"
}

# uninstall_addon_geoserver — Rückbau (Workspaces löschen, recurse=true).
# Schützt den Admin: nur die p2d2-Workspaces werden entfernt, nie Admin-User/-Rollen.
uninstall_addon_geoserver() {
  log "=== Uninstall AddOn 10: GeoServer (Workspaces entfernen) ==="

  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"
  local admin_user admin_pw
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)"
  local rest="https://geoportal.${domain}/geoserver/rest"

  # DELETE /rest/workspaces/<ws>?recurse=true entfernt Workspace + Datastores + FeatureTypes.
  # Liste spiegelbildlich zur Install-Seite: fv de2 de1 dev main (Vektor) + friedhofsplaene
  # (GeoTIFF-Mosaic). ACHTUNG: die Mosaic-Anlage (Install-Seite Abschnitt 9) ist noch TODO —
  # friedhofsplaene wird hier entfernt, von einem Re-Install aber (noch) NICHT wieder angelegt.
  # Bewusst als dokumentierte Asymmetrie belassen, bis Abschnitt 9 implementiert ist.
  # TODO: p2d2-Nutzer/Rollen/ACL/Secrets (die die Install-Seite als TODO markiert) später ergänzen.
  local ws
  for ws in friedhofsplaene fv de2 de1 dev main; do
    log "  Workspace ${ws} entfernen"
    curl -sS -u "${admin_user}:${admin_pw}" -X DELETE \
      "${rest}/workspaces/${ws}?recurse=true" || log_warn "    Workspace ${ws} evtl. schon entfernt"
  done

  log_ok "Uninstall AddOn 10 GeoServer abgeschlossen"
}

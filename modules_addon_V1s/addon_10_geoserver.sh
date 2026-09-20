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

# Fail-Fast: ohne ADDON_NS/ADDON_DOMAIN sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_NS:-}" || -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_NS/ADDON_DOMAIN nicht gesetzt — addon_10_geoserver.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

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

  # 9) GeoTIFF-Mosaic (Köln) — NUR aus dem Supplement-Ordner (kein "magischer" Datenzugang).
  install_addon_geoserver_mosaic

  log_ok "AddOn 10 GeoServer abgeschlossen (rudimentär, nicht idempotent)"
}

# install_addon_geoserver_mosaic — GeoTIFF-Mosaic "friedhofsplaene" (Köln, ImageMosaic).
# Turn 65: Daten kommen NUR aus dem Supplement-Ordner (ADDON_GEOTIFF_DIR). GeoTIFFs
# vorhanden → kubectl cp + Namespace/Coveragestore/Coverage/Metadata/ACL anlegen;
# nicht vorhanden → sauber übersprungen (kein Fehler, keine unklare Datenherkunft).
install_addon_geoserver_mosaic() {
  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"

  # Supplement-Ordner für die GeoTIFFs (configurable; Default relativ zum Repo).
  local geotiff_dir="${ADDON_GEOTIFF_DIR:-}"
  [[ -n "${geotiff_dir}" ]] || geotiff_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supplement/geotiffs/koeln" 2>/dev/null && pwd || true)"

  # Kein "magischer" Datenzugang: nur wenn tatsächlich GeoTIFFs bereitliegen.
  if [[ -z "${geotiff_dir}" || ! -d "${geotiff_dir}" ]] \
     || [[ -z "$(find "${geotiff_dir}" -maxdepth 2 -type f \( -iname '*.tif' -o -iname '*.tiff' \) -print -quit 2>/dev/null)" ]]; then
    log_warn "GeoTIFF-Supplement fehlt/leer (${geotiff_dir:-<nicht gesetzt>}) — Mosaic 'friedhofsplaene' wird übersprungen"
    return 0
  fi

  log "  GeoTIFF-Mosaic 'friedhofsplaene' aus Supplement: ${geotiff_dir}"

  # GeoServer-Pod ermitteln (Helm-Release geoserver-geoserver → Pod geoserver-geoserver-*).
  local geoserver_pod
  geoserver_pod="$(kubectl -n "$ns" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)"
  if [[ -z "${geoserver_pod}" ]]; then
    log_warn "GeoServer-Pod nicht gefunden (${ns}) — Mosaic 'friedhofsplaene' wird übersprungen"
    return 0
  fi

  # 9.1) Raster-Granules ins Pod-Data-Dir (kubectl cp, am Ingress vorbei — große TIFFs).
  local pod_target="/opt/geoserver/data_dir/data/geotiffs/koeln"
  log "    kubectl cp ${geotiff_dir}/. → ${geoserver_pod}:${pod_target}/"
  kubectl -n "$ns" cp "${geotiff_dir}/." "${geoserver_pod}:${pod_target}/" \
    || { log_warn "kubectl cp der GeoTIFFs fehlgeschlagen — Mosaic wird übersprungen"; return 0; }

  # Admin-Secret + REST-Basis.
  local admin_user admin_pw rest
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)"
  rest="https://geoportal.${domain}/geoserver/rest"

  # 9.2) Workspace/Namespace (erzeugt den Workspace gleich mit).
  curl -sS -u "${admin_user}:${admin_pw}" -X POST \
    -H 'Content-Type: application/json' \
    -d '{"namespace":{"prefix":"friedhofsplaene","uri":"urn:data-dna:tiffdata"}}' \
    "${rest}/namespaces" || log_warn "    Namespace friedhofsplaene evtl. schon vorhanden (409 tolerieren)"

  # 9.3) Coveragestore (ImageMosaic; legt KEINE Coverage an).
  curl -sS -u "${admin_user}:${admin_pw}" -X POST \
    -H 'Content-Type: application/json' \
    -d '{"coverageStore":{"name":"friedhofsplaene_koeln_mosaic","type":"ImageMosaic","url":"file:data/geotiffs/koeln"}}' \
    "${rest}/workspaces/friedhofsplaene/coveragestores" || log_warn "    Coveragestore evtl. schon vorhanden (409 tolerieren)"

  # 9.4) Coverage (explizit; nativeCoverageName = Mosaic-TypeName 'koeln').
  curl -sS -u "${admin_user}:${admin_pw}" -X POST \
    -H 'Content-Type: application/json' \
    -d '{"coverage":{"name":"friedhoefe_koeln","nativeCoverageName":"koeln","title":"Kölner Friedhöfe","srs":"EPSG:25832","projectionPolicy":"REPROJECT_TO_DECLARED"}}' \
    "${rest}/workspaces/friedhofsplaene/coveragestores/friedhofsplaene_koeln_mosaic/coverages" || log_warn "    Coverage evtl. schon vorhanden (409 tolerieren)"

  # 9.5) ImageMosaic-Kernparameter (Feld heißt metadata, NICHT parameters).
  curl -sS -u "${admin_user}:${admin_pw}" -X PUT \
    -H 'Content-Type: application/json' \
    -d '{"coverageStore":{"metadata":{"MergeBehavior":"FLAT","SUGGESTED_TILE_SIZE":"512,512","FootprintBehavior":"Transparent","ExcessGranuleRemoval":"NONE","USE_JAI_IMAGEREAD":"true","RescalePixels":"true","AllowMultithreading":"false"}}}' \
    "${rest}/workspaces/friedhofsplaene/coveragestores/friedhofsplaene_koeln_mosaic" || log_warn "    Metadata-PUT fehlgeschlagen"

  # 9.6) ACL: offene Lese-Regel (keine Write-Regel für Raster).
  curl -sS -u "${admin_user}:${admin_pw}" -X POST \
    -H 'Content-Type: application/json' \
    -d '{"friedhofsplaene.friedhoefe_koeln.r":"ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN"}' \
    "${rest}/security/acl/layers" || log_warn "    ACL evtl. schon vorhanden (409 tolerieren)"

  log_ok "  Mosaic 'friedhofsplaene' angelegt"
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
  # (GeoTIFF-Mosaic). Install und Uninstall sind jetzt symmetrisch: Abschnitt 9
  # (install_addon_geoserver_mosaic) legt die Mosaic aus dem Supplement-Ordner an,
  # hier wird sie wieder entfernt.
  # TODO: p2d2-Nutzer/Rollen/ACL/Secrets (die die Install-Seite als TODO markiert) später ergänzen.
  local ws
  for ws in friedhofsplaene fv de2 de1 dev main; do
    log "  Workspace ${ws} entfernen"
    curl -sS -u "${admin_user}:${admin_pw}" -X DELETE \
      "${rest}/workspaces/${ws}?recurse=true" || log_warn "    Workspace ${ws} evtl. schon entfernt"
  done

  log_ok "Uninstall AddOn 10 GeoServer abgeschlossen"
}

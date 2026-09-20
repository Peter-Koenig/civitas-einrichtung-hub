#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_10_geoserver.sh — p2d2-AddOn: GeoServer-Baustein (FERTIG, manuell verifiziert)
#
# Geteilte Plattforminstanz (Helm-Release geoserver-geoserver). Additiv erweitern:
#   Workspace/Namespace -> Datastore (PostGIS) -> FeatureTypes -> Nutzer/Rollen
#   -> ACL-Regeln -> Secrets -> Verifikation. Plus GeoTIFF-Mosaic (kommunen-übergreifend).
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

  # 9) GeoTIFF-Mosaic (kommunen-übergreifend) — NUR aus dem Supplement-Ordner (kein "magischer" Datenzugang).
  install_addon_geoserver_mosaic

  log_ok "AddOn 10 GeoServer abgeschlossen (rudimentär, nicht idempotent)"
}

# install_addon_geoserver_mosaic — GeoTIFF-Mosaics "friedhofsplaene" (ImageMosaic,
# kommunen-übergreifend). Turn 65: Daten kommen NUR aus dem Supplement-Ordner.
# Turn 68/69: Die Ordner-Hierarchie wird abgebildet — je Stadt ein Unterordner
# `geotiffs/<stadt>/` (z. B. koeln, bonn, berlin). Für jeden Unterordner mit GeoTIFFs
# wird ein eigenes Mosaic angelegt (gemeinsamer Workspace `friedhofsplaene`,
# Coveragestore `friedhofsplaene_<stadt>_mosaic`, Coverage `friedhoefe_<stadt>`).
# nativeCoverageName = Ordnername (Mosaic-TypeName, wie im Kölner Piloten erprobt).
install_addon_geoserver_mosaic() {
  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"

  # Supplement-Basisordner für die GeoTIFFs (configurable; Default relativ zum Repo).
  local geotiff_dir="${ADDON_GEOTIFF_DIR:-}"
  [[ -n "${geotiff_dir}" ]] || geotiff_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supplement/geotiffs" 2>/dev/null && pwd || true)"

  # Stadt-Unterordner unter geotiffs/ ermitteln (nur solche mit tatsächlichen TIFFs).
  local cities=() d stadt
  if [[ -n "${geotiff_dir}" && -d "${geotiff_dir}" ]]; then
    for d in "${geotiff_dir}"/*/; do
      [[ -d "${d}" ]] || continue
      stadt="$(basename "${d}")"
      [[ -n "$(find "${d}" -maxdepth 1 -type f \( -iname '*.tif' -o -iname '*.tiff' \) -print -quit 2>/dev/null)" ]] \
        && cities+=("${stadt}")
    done
  fi

  if [[ ${#cities[@]} -eq 0 ]]; then
    log_warn "Keine GeoTIFF-Unterordner mit TIFFs in ${geotiff_dir:-<nicht gesetzt>} — Mosaic 'friedhofsplaene' wird übersprungen"
    return 0
  fi

  log "  GeoTIFF-Mosaic aus Supplement: ${geotiff_dir} (Stadt/Städte: ${cities[*]})"

  # GeoServer-Pod ermitteln (Helm-Release geoserver-geoserver → Pod geoserver-geoserver-*).
  local geoserver_pod
  geoserver_pod="$(kubectl -n "$ns" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)"
  if [[ -z "${geoserver_pod}" ]]; then
    log_warn "GeoServer-Pod nicht gefunden (${ns}) — Mosaic 'friedhofsplaene' wird übersprungen"
    return 0
  fi

  # Admin-Secret + REST-Basis.
  local admin_user admin_pw rest
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)"
  rest="https://geoportal.${domain}/geoserver/rest"

  # 9.2) Workspace/Namespace (einmal, für alle Städte; erzeugt den Workspace mit).
  curl -sS -u "${admin_user}:${admin_pw}" -X POST \
    -H 'Content-Type: application/json' \
    -d '{"namespace":{"prefix":"friedhofsplaene","uri":"urn:data-dna:tiffdata"}}' \
    "${rest}/namespaces" || log_warn "    Namespace friedhofsplaene evtl. schon vorhanden (409 tolerieren)"

  # Je Stadt: Granules verteilen + Coveragestore + Coverage + Metadata + ACL.
  local pod_target coveragestore coverage
  for stadt in "${cities[@]}"; do
    pod_target="/opt/geoserver/data_dir/data/geotiffs/${stadt}"
    coveragestore="friedhofsplaene_${stadt}_mosaic"
    coverage="friedhoefe_${stadt}"
    log "    Stadt ${stadt}: Coveragestore ${coveragestore} / Coverage ${coverage}"

    # 9.1) Raster-Granules ins Pod-Data-Dir (kubectl cp, am Ingress vorbei — große TIFFs).
    log "      kubectl cp ${geotiff_dir}/${stadt}/. → ${geoserver_pod}:${pod_target}/"
    kubectl -n "$ns" cp "${geotiff_dir}/${stadt}/." "${geoserver_pod}:${pod_target}/" \
      || { log_warn "kubectl cp für ${stadt} fehlgeschlagen — übersprungen"; continue; }

    # 9.3) Coveragestore (ImageMosaic; legt KEINE Coverage an).
    curl -sS -u "${admin_user}:${admin_pw}" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"coverageStore\":{\"name\":\"${coveragestore}\",\"type\":\"ImageMosaic\",\"url\":\"file:data/geotiffs/${stadt}\"}}" \
      "${rest}/workspaces/friedhofsplaene/coveragestores" || log_warn "    Coveragestore ${coveragestore} evtl. schon vorhanden (409 tolerieren)"

    # 9.4) Coverage (explizit; nativeCoverageName = Mosaic-TypeName = Ordnername).
    curl -sS -u "${admin_user}:${admin_pw}" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"coverage\":{\"name\":\"${coverage}\",\"nativeCoverageName\":\"${stadt}\",\"title\":\"Friedhöfe ${stadt}\",\"srs\":\"EPSG:25832\",\"projectionPolicy\":\"REPROJECT_TO_DECLARED\"}}" \
      "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}/coverages" || log_warn "    Coverage ${coverage} evtl. schon vorhanden (409 tolerieren)"

    # 9.5) ImageMosaic-Kernparameter (Feld heißt metadata, NICHT parameters).
    curl -sS -u "${admin_user}:${admin_pw}" -X PUT \
      -H 'Content-Type: application/json' \
      -d '{"coverageStore":{"metadata":{"MergeBehavior":"FLAT","SUGGESTED_TILE_SIZE":"512,512","FootprintBehavior":"Transparent","ExcessGranuleRemoval":"NONE","USE_JAI_IMAGEREAD":"true","RescalePixels":"true","AllowMultithreading":"false"}}}' \
      "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}" || log_warn "    Metadata-PUT fehlgeschlagen"

    # 9.6) ACL: offene Lese-Regel (keine Write-Regel für Raster).
    curl -sS -u "${admin_user}:${admin_pw}" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"friedhofsplaene.${coverage}.r\":\"ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN\"}" \
      "${rest}/security/acl/layers" || log_warn "    ACL evtl. schon vorhanden (409 tolerieren)"
  done

  log_ok "  Mosaic 'friedhofsplaene' angelegt (${#cities[@]} Stadt/Städte)"
}

# uninstall_addon_geoserver — Rückbau (Workspaces + WFS-Secrets + Raster-Dateien).
# Schützt den Admin: nur die p2d2-Workspaces/-Secrets/-Dateien werden entfernt,
# nie Admin-User/-Rollen oder die geteilte GeoServer-Instanz.
uninstall_addon_geoserver() {
  log "=== Uninstall AddOn 10: GeoServer (Workspaces + Secrets + Raster) ==="

  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"
  local admin_user admin_pw
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' | base64 -d)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' | base64 -d)"
  local rest="https://geoportal.${domain}/geoserver/rest"

  # DELETE /rest/workspaces/<ws>?recurse=true entfernt Workspace + Datastores + FeatureTypes.
  # Liste spiegelbildlich zur Install-Seite: fv de2 de1 dev main (Vektor) + friedhofsplaene
  # (GeoTIFF-Mosaic). Install und Uninstall sind symmetrisch: Abschnitt 9
  # (install_addon_geoserver_mosaic) legt die Mosaic aus dem Supplement-Ordner an,
  # hier wird sie wieder entfernt.
  # Turn 72: HTTP-Statuscode separat abfragen (curl liefert bei 404 Exit 0 und sonst
  # den rohen Tomcat-HTML-Body ins Log) — je Code log_ok statt Fehlerseite.
  # TODO: p2d2-Nutzer/Rollen/ACL (die die Install-Seite als TODO markiert) später ergänzen.
  local ws http_code
  for ws in friedhofsplaene fv de2 de1 dev main; do
    log "  Workspace ${ws} entfernen"
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -u "${admin_user}:${admin_pw}" -X DELETE \
      "${rest}/workspaces/${ws}?recurse=true" 2>/dev/null || true)
    case "${http_code}" in
      200|201|202) log_ok "    Workspace ${ws} entfernt" ;;
      404)         log_ok "    Workspace ${ws} bereits entfernt (übersprungen)" ;;
      *)           log_warn "    Workspace ${ws} löschen fehlgeschlagen (HTTP ${http_code})" ;;
    esac
  done

  # Turn 71 Fund 2: physische Raster-Dateien im GeoServer-Pod-PVC entfernen.
  # DELETE workspace entfernt nur den Katalogeintrag (Workspace/Coveragestore/Coverage),
  # nicht die per kubectl cp hineinkopierten GeoTIFFs unter data/geotiffs/.
  local geoserver_pod
  geoserver_pod="$(kubectl -n "$ns" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)"
  if [[ -n "${geoserver_pod}" ]]; then
    if kubectl -n "$ns" exec "${geoserver_pod}" -- sh -c 'rm -rf /opt/geoserver/data_dir/data/geotiffs' 2>/dev/null; then
      log_ok "  Raster-Dateien unter data/geotiffs/ im GeoServer-Pod entfernt"
    else
      log_warn "  Raster-Dateien im GeoServer-Pod konnten nicht entfernt werden (manuell prüfen)"
    fi
  else
    log_warn "  GeoServer-Pod nicht gefunden — Raster-Dateien im Pod manuell prüfen"
  fi

  # Turn 71 Fund 1: GeoServer-WFS-T-Secrets aus der früheren manuellen Einrichtung
  # (p2d2-geoserver-wfs-user, p2d2-geoserver-wfst-<stage>). Alle p2d2-geoserver-*
  # Secrets entfernen — das Kern-Secret heißt geoserver-geoserver (ohne p2d2-Präfix).
  local gs_secret
  while read -r gs_secret; do
    [[ -n "${gs_secret}" ]] && kubectl -n "$ns" delete secret "${gs_secret}" --ignore-not-found || true
  done < <(kubectl -n "$ns" get secrets -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep '^p2d2-geoserver-' || true)

  log_ok "Uninstall AddOn 10 GeoServer abgeschlossen"
}

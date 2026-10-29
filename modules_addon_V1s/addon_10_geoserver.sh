#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_10_geoserver.sh — p2d2-AddOn: GeoServer-Baustein (GeoTIFF-Mosaic).
#
# Geteilte Plattforminstanz (Helm-Release geoserver-geoserver). Dieses Modul
# betreut ausschließlich das kommunen-übergreifende GeoTIFF-Mosaic (Workspace
# friedhofsplaene). Die Vektor-Konfiguration (Workspaces, Datastores, FeatureTypes,
# Benutzer/Rollen/ACLs, Dienst-Metadaten) übernimmt addon_11_geoserver_config.sh.

# Fail-Fast: ohne ADDON_NS/ADDON_DOMAIN sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_NS:-}" || -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_NS/ADDON_DOMAIN nicht gesetzt — addon_10_geoserver.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

# _gs_curl_user_cfg <user> <pw> — liefert eine `curl -K -`-Configzeile `user = ...`
# auf stdout. Kein Credential in den Prozessargumenten; Escaping identisch zu
# `_curl_user_cfg` in addon_11_geoserver_config_core.sh (Backslash + Anführungszeichen).
_gs_curl_user_cfg() {
  local s="${1}:${2}"
  case "$s" in *$'\n'*|*$'\r'*) log_error "Zugangsdaten enthalten Zeilenumbruch"; return 1 ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf 'user = "%s"\n' "$s"
}

# _gs_rest <user> <pw> <method> <url> <json_body> <ok_codes space-getrennt>
# GeoServer-REST-Aufruf mit HTTP-Statuscode-Prüfung. Gibt 0 (ok) oder 1 (Fehler)
# zurück; bei Fehler wird der Response-Body in log_warn geschrieben (kein roher
# Body mehr auf stdout — Turn 74 Fund A).
_gs_rest() {
  local user="$1" pw="$2" method="$3" url="$4" body="$5" ok_codes="$6"
  local resp code resp_body ok=0 c
  resp=$( _gs_curl_user_cfg "${user}" "${pw}" | curl -sS -K - -w $'\n%{http_code}' -X "${method}" \
    -H 'Content-Type: application/json' -d "${body}" "${url}" 2>/dev/null || true)
  code=$(printf '%s' "${resp}" | tail -1)
  resp_body=$(printf '%s' "${resp}" | sed '$d')
  for c in ${ok_codes}; do
    [[ "${code}" == "${c}" ]] && ok=1
  done
  if [[ "${ok}" == "1" ]]; then
    return 0
  fi
  log_warn "      ${method} ${url} → HTTP ${code}: ${resp_body}"
  return 1
}

# _gs_style_sld_put <user> <pw> <rest> <style> <sld_file> — SLD hochladen
# (Content-Type application/vnd.ogc.sld+xml, --data-binary); 200 ok, sonst Warnung.
_gs_style_sld_put() {
  local user="$1" pw="$2" rest="$3" style="$4" sld="$5" code
  code=$( _gs_curl_user_cfg "${user}" "${pw}" | curl -sS -K - -o /dev/null -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/vnd.ogc.sld+xml' --data-binary @"${sld}" \
    "${rest}/workspaces/friedhofsplaene/styles/${style}" 2>/dev/null || true)
  if [[ "${code}" == "200" ]]; then
    return 0
  fi
  log_warn "      PUT SLD ${style} → HTTP ${code}"
  return 1
}

# install_addon_geoserver_mosaic_style <admin_user> <admin_pw> <rest> — legt den
# Raster-Style friedhofsplan_transparent einmal an (POST Style-Ressource + PUT SLD).
# Fehlende SLD-Datei -> klare Warnung statt Abbruch. Rückgabe 0 ok / 1 Fehler.
install_addon_geoserver_mosaic_style() {
  local user="$1" pw="$2" rest="$3" sld
  sld="${ADDON_SUPPLEMENT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../supplement" 2>/dev/null && pwd || true)}/styles/friedhofsplan_transparent.sld"

  if [[ ! -f "${sld}" ]]; then
    log_warn "    SLD-Datei fehlt: ${sld} — Style friedhofsplan_transparent wird NICHT angelegt"
    return 1
  fi

  _gs_rest "${user}" "${pw}" POST "${rest}/workspaces/friedhofsplaene/styles" \
    '{"style":{"name":"friedhofsplan_transparent","filename":"friedhofsplan_transparent.sld"}}' \
    "201 409 200" \
    || { log_warn "    Style-Ressource friedhofsplan_transparent nicht angelegt"; return 1; }

  _gs_style_sld_put "${user}" "${pw}" "${rest}" "friedhofsplan_transparent" "${sld}" \
    || { log_warn "    SLD-Inhalt für friedhofsplan_transparent nicht hochgeladen"; return 1; }

  log_ok "    Style friedhofsplan_transparent angelegt"
  return 0
}

install_addon_geoserver() {
  log "=== AddOn 10: GeoServer (GeoTIFF-Mosaic; Vektor-Konfiguration: addon_11) ==="
  install_addon_geoserver_mosaic
  log_ok "AddOn 10 GeoServer abgeschlossen"
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
  _gs_rest "${admin_user}" "${admin_pw}" POST "${rest}/namespaces" \
    '{"namespace":{"prefix":"friedhofsplaene","uri":"urn:data-dna:tiffdata"}}' \
    "201 409 200" \
    || log_warn "    Namespace friedhofsplaene nicht angelegt — Folge-Schritte werden fehlschlagen"

  # 9.2a) Raster-Style (einmal pro Install, nicht pro Stadt).
  install_addon_geoserver_mosaic_style "${admin_user}" "${admin_pw}" "${rest}" \
    || log_warn "    Style friedhofsplan_transparent nicht angelegt — Layer behalten Default-Style"

  # Je Stadt: Granules verteilen + Coveragestore + Coverage + Metadata + ACL.
  local pod_target coveragestore coverage body fail
  local ok_cities=0
  for stadt in "${cities[@]}"; do
    pod_target="/opt/geoserver/data_dir/data/geotiffs/${stadt}"
    coveragestore="friedhofsplaene_${stadt}_mosaic"
    coverage="friedhoefe_${stadt}"
    fail=0
    log "    Stadt ${stadt}: Coveragestore ${coveragestore} / Coverage ${coverage}"

    # 9.1) Raster-Granules ins Pod-Data-Dir (kubectl cp, am Ingress vorbei — große TIFFs).
    # kubectl cp nutzt intern tar und legt das Zielverzeichnis NICHT selbst an —
    # deshalb vorher mkdir -p (Turn 73).
    kubectl -n "$ns" exec "${geoserver_pod}" -- mkdir -p "${pod_target}" \
      || { log_warn "    mkdir ${pod_target} im Pod fehlgeschlagen — ${stadt} übersprungen"; continue; }
    log "      kubectl cp ${geotiff_dir}/${stadt}/. → ${geoserver_pod}:${pod_target}/"
    kubectl -n "$ns" cp "${geotiff_dir}/${stadt}/." "${geoserver_pod}:${pod_target}/" \
      || { log_warn "    kubectl cp für ${stadt} fehlgeschlagen — übersprungen"; continue; }

    # 9.3) Coveragestore (ImageMosaic; legt KEINE Coverage an). Turn 74: explizites
    #      workspace-Feld im Body nötig, sonst "Store must be part of a workspace".
    body=$(jq -nc --arg name "${coveragestore}" --arg ws "friedhofsplaene" --arg url "file:data/geotiffs/${stadt}" \
      '{coverageStore:{name:$name,type:"ImageMosaic",workspace:{name:$ws},url:$url,enabled:true}}')
    _gs_rest "${admin_user}" "${admin_pw}" POST "${rest}/workspaces/friedhofsplaene/coveragestores" "${body}" "201 409 200" \
      || fail=1

    # 9.4) Coverage (explizit; nativeCoverageName = Mosaic-TypeName = Ordnername).
    body=$(jq -nc --arg name "${coverage}" --arg native "${stadt}" --arg title "Friedhöfe ${stadt}" \
      '{coverage:{name:$name,nativeCoverageName:$native,title:$title,srs:"EPSG:25832",projectionPolicy:"REPROJECT_TO_DECLARED",metadata:{entry:[{"@key":"cachingEnabled","$":"false"}]}}}')
    _gs_rest "${admin_user}" "${admin_pw}" POST "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}/coverages" "${body}" "201 200" \
      || fail=1

    # 9.4a) defaultStyle je Stadt auf friedhofsplan_transparent setzen (idempotent).
    body=$(jq -nc '{layer:{defaultStyle:{name:"friedhofsplan_transparent",workspace:"friedhofsplaene"}}}')
    _gs_rest "${admin_user}" "${admin_pw}" PUT "${rest}/layers/friedhofsplaene:${coverage}" "${body}" "200 201" \
      || fail=1

    # 9.5) ImageMosaic-Kernparameter (Feld heißt metadata, NICHT parameters).
    _gs_rest "${admin_user}" "${admin_pw}" PUT "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}" \
      '{"coverageStore":{"enabled":true,"metadata":{"MergeBehavior":"FLAT","SUGGESTED_TILE_SIZE":"512,512","FootprintBehavior":"Transparent","ExcessGranuleRemoval":"NONE","USE_JAI_IMAGEREAD":"true","RescalePixels":"true","AllowMultithreading":"false"}}}' \
      "200 201" || fail=1

    # 9.6) ACL: offene Lese-Regel (keine Write-Regel für Raster).
    body=$(jq -nc --arg rule "friedhofsplaene.${coverage}.r" \
      '{($rule):"ROLE_ANONYMOUS,ROLE_AUTHENTICATED,ADMIN"}')
    _gs_rest "${admin_user}" "${admin_pw}" POST "${rest}/security/acl/layers" "${body}" "200 201 409" \
      || fail=1

    if [[ "${fail}" == "0" ]]; then
      log_ok "    Stadt ${stadt}: Mosaic-REST-Konfiguration abgeschlossen"
      ok_cities=$((ok_cities + 1))
    else
      log_warn "    Stadt ${stadt}: Mosaic-REST-Konfiguration unvollständig (siehe Fehler oben)"
    fi
  done

  if [[ "${ok_cities}" -eq "${#cities[@]}" ]]; then
    log_ok "  Mosaic 'friedhofsplaene' REST-Konfiguration abgeschlossen (${ok_cities}/${#cities[@]} Städte)"
  else
    log_warn "  Mosaic 'friedhofsplaene' REST-Konfiguration nur teilweise (${ok_cities}/${#cities[@]} Städte — siehe Fehler oben)"
  fi
}

# verify_addon_geoserver_mosaic — echte Verifikation (nicht-abbrechend wie
# verify_addon_geoserver_config): je Stadt Store/Coverage/Layer enabled (kein false),
# Layer in den anonymen WMS-Capabilities, und ein GetMap (ohne Style, BBox innerhalb
# der Coverage) liefert 200 image/png. Fehlerpfade mit explizitem return 1.
verify_addon_geoserver_mosaic() {
  log "=== AddOn 10: GeoServer-Mosaic verifizieren ==="

  local ns="${ADDON_NS}"
  local domain="${ADDON_DOMAIN}"
  local admin_user admin_pw rest wms_base
  admin_user="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-user}' 2>/dev/null | base64 -d || true)"
  admin_pw="$(kubectl -n "$ns" get secret geoserver-geoserver -o jsonpath='{.data.geoserver-password}' 2>/dev/null | base64 -d || true)"
  rest="https://geoportal.${domain}/geoserver/rest"
  wms_base="https://geoportal.${domain}/geoserver"

  local geotiff_dir="${ADDON_GEOTIFF_DIR:-}"
  [[ -n "${geotiff_dir}" ]] || geotiff_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../supplement/geotiffs" 2>/dev/null && pwd || true)"

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
    log_warn "Keine GeoTIFF-Unterordner mit TIFFs — Mosaic-Verifikation übersprungen"
    return 0
  fi

  local coveragestore coverage rc=0
  local code store_enabled cov_enabled layer_enabled cap
  local f_store f_cov f_layer map_meta map_code map_ct nbbox bbox
  for stadt in "${cities[@]}"; do
    coveragestore="friedhofsplaene_${stadt}_mosaic"
    coverage="friedhoefe_${stadt}"
    log "  Stadt ${stadt}: Verifikation ${coveragestore}/${coverage}"

    # 1) Coveragestore enabled (GET .json; enabled muss true sein).
    f_store="$(mktemp)"; chmod 600 "$f_store"
    code=$( _gs_curl_user_cfg "${admin_user}" "${admin_pw}" | curl -sS -K - -o "$f_store" -w '%{http_code}' \
      "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}.json" 2>/dev/null || true)
    store_enabled="$(jq -r '.coverageStore.enabled // "false"' "$f_store" 2>/dev/null || true)"
    rm -f "$f_store"
    if [[ "${code}" != "200" || "${store_enabled}" != "true" ]]; then
      log_error "  Stadt ${stadt}: Coveragestore nicht enabled (HTTP ${code}, enabled=${store_enabled:-<fehlt>})"
      rc=1
    else
      log_ok "  Stadt ${stadt}: Coveragestore enabled"
    fi

    # 2) Coverage enabled + nativeBoundingBox (für GetMap).
    f_cov="$(mktemp)"; chmod 600 "$f_cov"
    code=$( _gs_curl_user_cfg "${admin_user}" "${admin_pw}" | curl -sS -K - -o "$f_cov" -w '%{http_code}' \
      "${rest}/workspaces/friedhofsplaene/coveragestores/${coveragestore}/coverages/${coverage}.json" 2>/dev/null || true)
    cov_enabled="$(jq -r '.coverage.enabled // "false"' "$f_cov" 2>/dev/null || true)"
    if [[ "${code}" != "200" || "${cov_enabled}" != "true" ]]; then
      log_error "  Stadt ${stadt}: Coverage nicht enabled (HTTP ${code}, enabled=${cov_enabled:-<fehlt>})"
      rc=1
    else
      log_ok "  Stadt ${stadt}: Coverage enabled"
    fi

    # 3) Layer enabled (kein false; bei RASTER-Layern fehlt enabled und gilt als true).
    f_layer="$(mktemp)"; chmod 600 "$f_layer"
    code=$( _gs_curl_user_cfg "${admin_user}" "${admin_pw}" | curl -sS -K - -o "$f_layer" -w '%{http_code}' \
      "${rest}/layers/friedhofsplaene:${coverage}.json" 2>/dev/null || true)
    layer_enabled="$(jq -r '(.layer.enabled | if . == null then true else . end) | tostring' "$f_layer" 2>/dev/null || true)"
    rm -f "$f_layer"
    if [[ "${code}" != "200" || "${layer_enabled}" == "false" ]]; then
      log_error "  Stadt ${stadt}: Layer nicht enabled (HTTP ${code}, enabled=${layer_enabled:-<fehlt>})"
      rc=1
    else
      log_ok "  Stadt ${stadt}: Layer enabled"
    fi

    # 4) Layer in anonymen WMS-Capabilities.
    cap="$(curl -sS --max-time 30 "${wms_base}/wms?service=WMS&version=1.1.1&request=GetCapabilities" 2>/dev/null || true)"
    if grep -qF "${coverage}" <<< "${cap}"; then
      log_ok "  Stadt ${stadt}: Layer in anonymen WMS-Capabilities"
    else
      log_error "  Stadt ${stadt}: Layer fehlt in anonymen WMS-Capabilities"
      rc=1
    fi

    # 5) GetMap ohne Style, BBox = Mittelpunkt der nativeBoundingBox +/- 250 m.
    nbbox="$(jq -r '[.coverage.nativeBoundingBox.minx,.coverage.nativeBoundingBox.maxx,.coverage.nativeBoundingBox.miny,.coverage.nativeBoundingBox.maxy] | @tsv' "$f_cov" 2>/dev/null || true)"
    rm -f "$f_cov"
    if [[ -n "${nbbox}" ]]; then
      bbox="$(awk '{cx=($1+$2)/2; cy=($3+$4)/2; printf "%.2f,%.2f,%.2f,%.2f", cx-250, cy-250, cx+250, cy+250}' <<< "${nbbox}")"
    else
      log_error "  Stadt ${stadt}: nativeBoundingBox nicht lesbar — GetMap übersprungen"
      rc=1
      continue
    fi

    map_meta="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code} %{content_type}' \
      "${wms_base}/wms?service=WMS&version=1.1.1&request=GetMap&layers=friedhofsplaene:${coverage}&styles=&srs=EPSG:25832&bbox=${bbox}&width=256&height=256&format=image/png" 2>/dev/null || true)"
    map_code="${map_meta%% *}"
    map_ct="${map_meta#* }"
    if [[ "${map_code}" == "200" && "${map_ct}" == "image/png" ]]; then
      log_ok "  Stadt ${stadt}: GetMap 200 image/png (bbox ${bbox})"
    else
      log_error "  Stadt ${stadt}: GetMap fehlgeschlagen (HTTP ${map_code}, Content-Type ${map_ct:-<fehlt>})"
      rc=1
    fi
  done

  if [[ "${rc}" -eq 0 ]]; then
    log_ok "  Mosaic 'friedhofsplaene' angelegt (verifiziert: ${#cities[@]} Städte)"
  else
    log_error "  Mosaic 'friedhofsplaene' Verifikation fehlgeschlagen (Details oben)"
  fi
  return "${rc}"
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
  local ws http_code rc=0
  for ws in friedhofsplaene fv de2 de1 dev main; do
    log "  Workspace ${ws} entfernen"
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" -u "${admin_user}:${admin_pw}" -X DELETE \
      "${rest}/workspaces/${ws}?recurse=true" 2>/dev/null || true)
    case "${http_code}" in
      200|201|202) log_ok "    Workspace ${ws} entfernt" ;;
      404)         log_ok "    Workspace ${ws} bereits entfernt (übersprungen)" ;;
      *)           log_warn "    Workspace ${ws} löschen fehlgeschlagen (HTTP ${http_code})"; rc=1 ;;
    esac
  done

  # Turn 71 Fund 2: physische Raster-Dateien im GeoServer-Pod-PVC entfernen.
  # DELETE workspace entfernt nur den Katalogeintrag (Workspace/Coveragestore/Coverage),
  # nicht die per kubectl cp hineinkopierten GeoTIFFs unter data/geotiffs/.
  # Turn 73: NUR den Inhalt unterhalb von geotiffs/ entfernen — das Verzeichnis
  # geotiffs/ selbst gehört zum GeoServer und bleibt stehen (kein rm -rf auf den Ordner).
  local geoserver_pod
  geoserver_pod="$(kubectl -n "$ns" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | tr ' ' '\n' | grep '^geoserver-geoserver-' | head -1 || true)"
  if [[ -n "${geoserver_pod}" ]]; then
    if kubectl -n "$ns" exec "${geoserver_pod}" -- sh -c 'rm -rf /opt/geoserver/data_dir/data/geotiffs/*' 2>/dev/null; then
      log_ok "  Raster-Dateien unter data/geotiffs/ im GeoServer-Pod entfernt (Verzeichnis bleibt)"
    else
      log_warn "  Raster-Dateien im GeoServer-Pod konnten nicht entfernt werden (manuell prüfen)"
      rc=1
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

  if [[ "${rc}" -ne 0 ]]; then
    log_warn "Uninstall AddOn 10 GeoServer mit Resten/Fehlern beendet"
    return 1
  fi
  log_ok "Uninstall AddOn 10 GeoServer abgeschlossen"
}

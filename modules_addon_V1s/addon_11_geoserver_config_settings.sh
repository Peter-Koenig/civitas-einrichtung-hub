#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
# settings.sh - GeoServer-Metadaten (geoserver-metadata.md) und deren Anwendung:
# Workspace-Einstellungen, Dienst-Metadaten (WMS/WFS), Layer-Metadaten.
# Wird vom Einstieg genau einmal gesourct; kein eigenstaendig ausfuehrbares Programm.

# Kompaktes JSON der geparsten Metadaten (von load_metadata gesetzt).
_GS_METADATA=""
# --allow-incomplete-metadata (nur Dev): unvollständige Metadaten nur als WARN.
_GS_ALLOW_INCOMPLETE=0

# _metadata_extract — gibt den YAML-Block (ohne Fences) der Metadaten-Datei aus.
_metadata_extract() {
  awk '/^```yaml$/ {f=1; next} /^```$/ {f=0} f' "$GS_METADATA_FILE"
}

# _meta <jq-expr> — Wert aus den geparsten Metadaten (leer bei Fehler/fehlend).
_meta() {
  printf '%s' "$_GS_METADATA" | jq -r "$1" 2>/dev/null
}

# _xml_esc <wert> — XML-Escape fuer Capabilities-Vergleich (grep -qF).
_xml_esc() {
  local s="$1"
  s="${s//&/\&amp;}"; s="${s//</\&lt;}"; s="${s//>/\&gt;}"
  printf '%s' "$s"
}

# _resolve_tpl <wert> <ws> <stage_beschreibung> — Platzhalter per Bash-Ersetzung.
_resolve_tpl() {
  local v="$1" ws="$2" desc="$3"
  v="${v//\{stage_beschreibung\}/$desc}"
  v="${v//\{stage\}/$ws}"
  v="${v//%ws%/$ws}"
  printf '%s' "$v"
}

# load_metadata — parst und validiert die Metadaten-Datei (vor jeder Mutation).
# Rückgabe 0 ok; 2 bei fehlender Datei, Parsefehler oder unvollständigen Werten
# (ohne --allow-incomplete-metadata).
load_metadata() {
  local raw k v missing
  [[ -f "$GS_METADATA_FILE" ]] || { log_error "Metadaten-Datei fehlt: $GS_METADATA_FILE"; return 2; }
  raw="$(_metadata_extract)"
  [[ -n "$raw" ]] || { log_error "Metadaten-Datei enthält keinen YAML-Block (Fence)"; return 2; }

  _GS_METADATA="$(printf '%s' "$raw" | yq -o=json '.' 2>/dev/null)" \
    || { log_error "Metadaten-YAML nicht lesbar (yq -o=json fehlgeschlagen)"; return 2; }
  printf '%s' "$_GS_METADATA" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || { log_error "Metadaten-YAML erzeugt kein gültiges Objekt-JSON"; return 2; }

  missing=0
  for k in \
    '.workspace_settings.numDecimals' \
    '.workspace_settings.charset' \
    '.workspace_settings.contact.contactEmail' \
    '.service.onlineResource' \
    '.service.wms.title' \
    '.service.wfs.title' \
    '.layers["geo-containers"].title' \
    '.layers.grabflure.title' \
    '.layers.grabflure_versionen.title' \
    '.layers.graeber.title' \
    '.layers.graeber_versionen.title'; do
    v="$(_meta "$k // empty")"
    if [[ -z "$v" || "$v" == "null" ]]; then
      log_error "Metadaten: Pflichtschlüssel $k fehlt oder ist leer"
      missing=1
    fi
  done

  if printf '%s' "$_GS_METADATA" | grep -q 'TODO'; then
    log_error "Metadaten enthalten den Platzhalter TODO"
    missing=1
  fi

  if [[ "$missing" -eq 1 ]]; then
    if [[ "$_GS_ALLOW_INCOMPLETE" -eq 1 ]]; then
      log_warn "Metadaten unvollständig (TODO/leer) — Lauf wird wegen --allow-incomplete-metadata fortgesetzt"
      return 0
    fi
    return 2
  fi
  return 0
}

# _ws_settings_soll — Soll-Objekt der Workspace-Einstellungen (REST-Schlüssel).
_ws_settings_soll() {
  printf '%s' "$_GS_METADATA" | jq -c '{numDecimals:.workspace_settings.numDecimals,
    charset:.workspace_settings.charset, onlineResource:.workspace_settings.onlineResource,
    contact:.workspace_settings.contact}'
}

# _service_soll <svc> <ws> <stage_beschreibung> — inneres Soll-Objekt (REST-Schlüssel,
# inkl. GeoServer-Typo-Schlüssel "abstrct" und keywords als {"string":[...]}).
_service_soll() {
  local svc="$1" ws="$2" desc="$3" title abstract
  title="$(_resolve_tpl "$(_meta ".service.$svc.title // empty")" "$ws" "$desc")"
  abstract="$(_resolve_tpl "$(_meta ".service.$svc.abstract // empty")" "$ws" "$desc")"
  printf '%s' "$_GS_METADATA" | jq -c --arg svc "$svc" --arg title "$title" --arg abstract "$abstract" \
    '{name: ($svc | ascii_upcase), enabled: true,
      title:$title, abstrct:$abstract,
      maintainer:.service.maintainer, fees:.service.fees,
      accessConstraints:.service.accessConstraints, onlineResource:.service.onlineResource,
      keywords:{string:.service.keywords}}
     + (if $svc == "wfs" then {featureBounding:.service.wfs.featureBounding} else {} end)'
}

# _service_global <svc> — globales Dienstdokument (Inhalt unter .<svc>) auf stdout.
_service_global() {
  local svc="$1"
  _gs_get "services/${svc}/settings.json"
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_gs_error "globales Dienstdokument ${svc} nicht lesbar"; return 1; }
  jq -c --arg s "$svc" '.[$s]' "$_GS_BODY_FILE" 2>/dev/null
  rm -f "$_GS_BODY_FILE"
  return 0
}

install_workspace_settings() {
  local key ws soll code cur f rc=0 lost
  log "== Workspace-Einstellungen =="
  while IFS='|' read -r key ws _; do
    [[ -n "$key" ]] || continue
    if [[ "$DRY_RUN" -eq 1 ]] && ! _has "$ws" "${_EXISTING_WS[@]}"; then
      log "  [dry-run] $ws: Workspace-Einstellungen würden gesetzt (Workspace wird zuvor angelegt)"
      howto_step "PUT workspaces/$ws/settings" "200" "-" "geplant"
      continue
    fi
    _gs_get "workspaces/${ws}/settings.json"
    code="$_GS_CODE"
    if [[ "$code" != "200" ]]; then
      rm -f "$_GS_BODY_FILE"
      log_error "Workspace-Einstellungen $ws: GET -> $code (erwartet 200)"; rc=1; continue
    fi
    cur="$_GS_BODY_FILE"
    soll="$(_ws_settings_soll)"
    if jq -e --argjson soll "$soll" '.settings == (.settings * $soll)' "$cur" >/dev/null 2>&1; then
      rm -f "$cur"
      log "  $ws: Workspace-Einstellungen unverändert"
      continue
    fi
    log "  $ws: Workspace-Einstellungen weichen ab — werden gesetzt"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      rm -f "$cur"
      log "  [dry-run] $ws: Workspace-Einstellungen würden gesetzt"
      howto_step "PUT workspaces/$ws/settings" "200" "-" "numDecimals/charset/contact $ws"
      continue
    fi
    f="$(mktemp)"; chmod 600 "$f"
    jq --argjson soll "$soll" '.settings = (.settings * $soll)' "$cur" > "$f"
    _gs_write_body PUT "workspaces/${ws}/settings" "$f" 'application/json'
    code="$_GS_CODE"; rm -f "$f"
    howto_step "PUT workspaces/$ws/settings" "200" "$code" "Einstellungen $ws"
    if [[ "$code" != "200" ]]; then
      rm -f "$cur"; log_gs_error "Workspace-Einstellungen $ws setzen fehlgeschlagen (HTTP $code)"; rc=1; continue
    fi
    # Erneut lesen: kein Schlüssel verloren, alle Soll-Werte gesetzt.
    _gs_get "workspaces/${ws}/settings.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      lost="$(jq -n --slurpfile pre "$cur" --slurpfile post "$_GS_BODY_FILE" \
        '($pre[0].settings | keys) - ($post[0].settings | keys) | .[0] // empty' 2>/dev/null)"
      if [[ -n "$lost" ]]; then
        log_error "Workspace-Einstellungen $ws: Schlüssel $lost ging beim PUT verloren"; rc=1
      elif jq -e --argjson soll "$soll" '.settings == (.settings * $soll)' "$_GS_BODY_FILE" >/dev/null 2>&1; then
        log_ok "  $ws: Workspace-Einstellungen gesetzt"
      else
        log_error "Workspace-Einstellungen $ws: Soll-Werte nach PUT nicht vollständig"; rc=1
      fi
      rm -f "$_GS_BODY_FILE"
    else
      log_error "Workspace-Einstellungen $ws: erneutes GET -> $code"; rc=1
    fi
    rm -f "$cur"
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_workspace_settings() {
  local key ws soll code rc=0
  log "== Verifikation Workspace-Einstellungen =="
  while IFS='|' read -r key ws _; do
    [[ -n "$key" ]] || continue
    _gs_get "workspaces/${ws}/settings.json"
    code="$_GS_CODE"
    if [[ "$code" != "200" ]]; then
      rm -f "$_GS_BODY_FILE"
      log_error "Verifikation Einstellungen $ws: GET -> $code"; rc=1; continue
    fi
    soll="$(_ws_settings_soll)"
    if jq -e --argjson soll "$soll" '.settings == (.settings * $soll)' "$_GS_BODY_FILE" >/dev/null 2>&1; then
      log_ok "  $ws: Einstellungen ok (numDecimals $(jq -r '.settings.numDecimals' "$_GS_BODY_FILE"))"
    else
      log_error "Verifikation Einstellungen $ws: Soll-Werte weichen ab"; rc=1
    fi
    rm -f "$_GS_BODY_FILE"
  done <<< "$DS_TABLE"
  return "$rc"
}

install_service_metadata() {
  local key ws svc code soll cur f rc=0 desc base
  log "== Dienst-Metadaten (WMS/WFS) =="
  while IFS='|' read -r key ws _; do
    [[ -n "$key" ]] || continue
    desc="$(_meta ".stages.$ws // empty")"
    if [[ "$DRY_RUN" -eq 1 ]] && ! _has "$ws" "${_EXISTING_WS[@]}"; then
      for svc in wms wfs; do
        log "  [dry-run] $ws/$svc: Dienst-Metadaten würden angelegt (Workspace wird zuvor angelegt)"
        howto_step "PUT services/$svc/workspaces/$ws/settings" "200" "-" "geplant"
      done
      continue
    fi
    for svc in wms wfs; do
      soll="$(_service_soll "$svc" "$ws" "$desc")"
      _gs_get "services/${svc}/workspaces/${ws}/settings.json"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]]; then
        cur="$_GS_BODY_FILE"
        if jq -e --argjson soll "$soll" --arg svc "$svc" '.[$svc] == (.[$svc] * $soll)' "$cur" >/dev/null 2>&1; then
          rm -f "$cur"
          log "  $ws/$svc: Dienst-Metadaten unverändert"
          continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
          rm -f "$cur"
          log "  [dry-run] $ws/$svc: Dienst-Metadaten würden gesetzt"
          howto_step "PUT services/$svc/workspaces/$ws/settings" "200" "-" "Dienst-Metadaten $ws/$svc"
          continue
        fi
        f="$(mktemp)"; chmod 600 "$f"
        jq --argjson soll "$soll" --arg svc "$svc" '{($svc): (.[$svc] * $soll)}' "$cur" > "$f"
        _gs_write_body PUT "services/${svc}/workspaces/${ws}/settings" "$f" 'application/json'
        code="$_GS_CODE"; rm -f "$f" "$cur"
        howto_step "PUT services/$svc/workspaces/$ws/settings" "200" "$code" "Dienst-Metadaten $ws/$svc"
        if [[ "$code" == "200" ]]; then
          log_ok "  $ws/$svc: Dienst-Metadaten aktualisiert"
        else
          log_gs_error "Dienst-Metadaten $ws/$svc setzen fehlgeschlagen (HTTP $code)"; rc=1
        fi
      elif [[ "$code" == "404" ]]; then
        rm -f "$_GS_BODY_FILE"
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "  [dry-run] $ws/$svc: Dienst-Metadaten würden angelegt"
          howto_step "PUT services/$svc/workspaces/$ws/settings" "200" "-" "anlegen $ws/$svc (404 -> PUT)"
          continue
        fi
        base="$(_service_global "$svc")" || { rc=1; continue; }
        f="$(mktemp)"; chmod 600 "$f"
        jq -nc --arg s "$svc" --argjson base "$base" --argjson soll "$soll" '{($s): ($base | del(.id) | . * $soll)}' > "$f"
        _gs_write_body PUT "services/${svc}/workspaces/${ws}/settings" "$f" 'application/json'
        code="$_GS_CODE"; rm -f "$f"
        howto_step "PUT services/$svc/workspaces/$ws/settings" "200" "$code" "anlegen $ws/$svc (404 -> PUT)"
        if [[ "$code" == "200" ]]; then
          log_ok "  $ws/$svc: Dienst-Metadaten angelegt"
        else
          log_gs_error "Dienst-Metadaten $ws/$svc anlegen fehlgeschlagen (HTTP $code)"; rc=1
        fi
      else
        rm -f "$_GS_BODY_FILE"
        log_error "Dienst-Metadaten $ws/$svc: GET -> $code (erwartet 200/404)"; rc=1
      fi
    done
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_service_metadata() {
  local key ws svc title email code rc=0 maxdec or cap_ok name abstract
  log "== Verifikation Dienst-Metadaten =="

  # HEAD auf service.onlineResource: einmal, ohne Credentials, mit Timeouts (C5).
  or="$(_meta '.service.onlineResource // empty')"
  code="$(curl -sS -I --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$or" 2>/dev/null)" || code="000"
  if [[ "$code" == "200" ]]; then
    log_ok "Online-Resource erreichbar ($or)"
  else
    log_warn "Online-Resource $or -> $code (nicht 200)"
  fi

  while IFS='|' read -r key ws _; do
    [[ -n "$key" ]] || continue
    local desc; desc="$(_meta ".stages.$ws // empty")"
    email="$(_meta '.workspace_settings.contact.contactEmail // empty')"
    for svc in wms wfs; do
      title="$(_resolve_tpl "$(_meta ".service.$svc.title // empty")" "$ws" "$desc")"
      _gs_get_url "$GS_BASE/$ws/$svc?service=${svc^^}&version=2.0.0&request=GetCapabilities"
      code="$_GS_CODE"
      cap_ok=1
      if [[ "$code" != "200" ]]; then
        cap_ok=0
        log_error "Verifikation $ws/$svc: ${svc^^} GetCapabilities -> $code (erwartet 200)"; rc=1
      else
        if ! grep -qE '<(wms:)?WMS_Capabilities|<(wfs:)?WFS_Capabilities' "$_GS_BODY_FILE" 2>/dev/null; then
          cap_ok=0
          log_error "Verifikation $ws/$svc: Capabilities-Wurzel fehlt"; rc=1
        fi
        if grep -qE 'ExceptionReport|ServiceException' "$_GS_BODY_FILE" 2>/dev/null; then
          cap_ok=0
          log_error "Verifikation $ws/$svc: Capabilities enthält ExceptionReport"; rc=1
        fi
        title="$(_xml_esc "$title")"; email="$(_xml_esc "$email")"
        if ! grep -qF "$title" "$_GS_BODY_FILE" 2>/dev/null || ! grep -qF "$email" "$_GS_BODY_FILE" 2>/dev/null; then
          cap_ok=0
          log_error "Verifikation $ws/$svc: Capabilities unvollständig (Titel/Kontakt)"; rc=1
        fi
        while IFS='|' read -r name _; do
          [[ -n "$name" ]] || continue
          abstract="$(_xml_esc "$(_meta ".layers[\"$name\"].abstract // empty")")"
          [[ -n "$abstract" ]] || continue
          if ! grep -qF "$abstract" "$_GS_BODY_FILE" 2>/dev/null; then
            cap_ok=0
            log_error "Verifikation $ws/$svc: Abstract für Layer $name fehlt"; rc=1
          fi
        done <<< "$FT_TABLE"
      fi
      rm -f "$_GS_BODY_FILE"
      [[ "$cap_ok" -eq 1 ]] && log_ok "  $ws/$svc: ${svc^^} GetCapabilities 200 (Titel + Kontakt + Layer)"
    done

    # Wirksame Genauigkeit: GetFeature auf geo-containers (JSON), nur Koordinaten (C4).
    _gs_get_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=${ws}:geo-containers&outputFormat=application/json&count=3"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      maxdec="$(jq -r '[.features[]?.geometry.coordinates | flatten | .[] | tostring | select(contains(".")) | split(".")[1] | length] | max // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      if [[ -z "$maxdec" || "$maxdec" == "null" ]]; then
        log_warn "  $ws: keine Features, Genauigkeit nicht prüfbar"
      elif [[ "$maxdec" =~ ^[0-9]+$ ]] && [[ "$maxdec" -ge 7 ]]; then
        log_ok "  $ws: GetFeature geo-containers mit $maxdec Nachkommastellen"
      else
        log_error "Verifikation $ws: Koordinaten auf $maxdec Stellen gerundet (erwartet mindestens 7)"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      log_error "Verifikation $ws: GetFeature geo-containers -> $code"; rc=1
    fi
  done <<< "$DS_TABLE"
  return "$rc"
}

# _ensure_layer_attribution <ws> <name> — setzt Layer-Attribution (nur geo-containers)
# nur bei Abweichung (Teil-PUT, mergt).
_ensure_layer_attribution() {
  local ws="$1" name="$2" attr f code cur
  attr="$(_meta ".layers[\"$name\"].attribution // empty")"
  [[ -n "$attr" && "$attr" != "null" ]] || return 0
  _gs_get "workspaces/${ws}/layers/${name}.json"
  code="$_GS_CODE"
  if [[ "$code" != "200" ]]; then
    rm -f "$_GS_BODY_FILE"
    log "  $ws/$name: Layer nicht vorhanden (Attribution entfällt)"
    return 0
  fi
  cur="$_GS_BODY_FILE"
  if jq -e --argjson attr "$attr" '.layer.attribution.title == $attr.title and .layer.attribution.href == $attr.href' "$cur" >/dev/null 2>&1; then
    rm -f "$cur"
    log "  $ws/$name: Attribution ok"
    return 0
  fi
  rm -f "$cur"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] $ws/$name: Attribution würde gesetzt"
    howto_step "PUT workspaces/$ws/layers/$name" "200" "-" "Attribution $ws/$name"
    return 0
  fi
  f="$(mktemp)"; chmod 600 "$f"
  jq -nc --argjson attr "$attr" '{layer:{attribution:$attr}}' > "$f"
  _gs_write_body PUT "workspaces/${ws}/layers/${name}" "$f" 'application/json'
  code="$_GS_CODE"; rm -f "$f"
  howto_step "PUT workspaces/$ws/layers/$name" "200" "$code" "Attribution $ws/$name"
  [[ "$code" == "200" ]] || { log_gs_error "$ws/$name Attribution setzen fehlgeschlagen (HTTP $code)"; return 1; }
  log_ok "  $ws/$name: Attribution gesetzt"
  return 0
}

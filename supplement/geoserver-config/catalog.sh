#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
# catalog.sh - Workspaces, Datastores, FeatureTypes (anlegen/verifizieren/loeschen).
# Wird vom Einstieg genau einmal gesourct.

install_workspaces() {
  local -a existing
  local ws uri cur code rc=0 f
  local tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_workspaces > "$tmp"; then
    rm -f "$tmp"; log_error "Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t existing < "$tmp"
  rm -f "$tmp"

  log "== Workspaces =="
  while IFS='|' read -r ws uri; do
    [[ -n "$ws" ]] || continue
    if ! _has "$ws" "${existing[@]}"; then
      log "  Workspace $ws anlegen"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "POST namespaces" "201" "-" "JSON {\"namespace\":{\"prefix\":\"$ws\",\"uri\":\"$uri\"}}"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      jq -nc --arg p "$ws" --arg u "$uri" '{namespace:{prefix:$p,uri:$u}}' > "$f"
      _gs_write_body POST 'namespaces' "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "POST namespaces" "201" "$code" "JSON {\"namespace\":{\"prefix\":\"$ws\",\"uri\":\"$uri\"}}"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_ok "  Workspace $ws angelegt"
      else
        log_gs_error "Workspace $ws anlegen fehlgeschlagen (HTTP $code)"; rc=1
      fi
    else
      if ! cur="$(read_namespace_uri "$ws")"; then
        log_error "Workspace $ws: Namespace nicht lesbar"; rc=1
        continue
      fi
      if [[ -z "$cur" ]]; then
        log_error "Workspace $ws vorhanden, aber Namespace fehlt"; rc=1
      elif [[ "$cur" != "$uri" ]]; then
        log_error "Workspace $ws: Namespace-URI weicht ab (erwartet $uri, vorhanden $cur)"; rc=1
      else
        log "  Workspace $ws vorhanden, URI stimmt"
      fi
    fi
  done <<< "$WS_TABLE"
  return "$rc"
}

verify_workspaces() {
  local ws uri cur code rc=0 name
  log "== Verifikation Workspaces =="
  while IFS='|' read -r ws uri; do
    [[ -n "$ws" ]] || continue
    # Namespace-URI
    _gs_get "namespaces/${ws}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      cur="$(jq -r '.namespace.uri // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET namespaces/$ws.json" "200" "200" "URI prüfen"
      if [[ "$cur" == "$uri" ]]; then
        log_ok "  $ws: Namespace-URI ok"
      else
        log_error "Verifikation $ws: Namespace-URI weicht ab (erwartet $uri, vorhanden $cur)"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET namespaces/$ws.json" "200" "$code" "URI prüfen"
      log_error "Verifikation $ws: GET namespaces/$ws.json -> $code (erwartet 200)"; rc=1
    fi
    # Workspace vorhanden und name stimmt
    _gs_get "workspaces/${ws}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      name="$(jq -r '.workspace.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws.json" "200" "200" "name prüfen"
      if [[ "$name" == "$ws" ]]; then
        log_ok "  $ws: Workspace-name ok"
      else
        log_error "Verifikation $ws: workspaces/$ws.json name weicht ab (erwartet $ws, erhalten $name)"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws.json" "200" "$code" "name prüfen"
      log_error "Verifikation $ws: GET workspaces/$ws.json -> $code (erwartet 200)"; rc=1
    fi
    # Virtuelle Dienste (hart, R7)
    code="$(_http_code_url "$GS_BASE/$ws/wms?service=WMS&version=1.3.0&request=GetCapabilities")"
    howto_step "GET $ws/wms GetCapabilities" "200" "$code" "Dienstprüfung"
    if [[ "$code" == "200" ]]; then log_ok "  $ws: WMS GetCapabilities 200"; else log_error "Verifikation $ws: WMS GetCapabilities -> $code (erwartet 200)"; rc=1; fi
    if [[ "$ws" != "friedhofsplaene" ]]; then
      code="$(_http_code_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetCapabilities")"
      howto_step "GET $ws/wfs GetCapabilities" "200" "$code" "Dienstprüfung"
      if [[ "$code" == "200" ]]; then log_ok "  $ws: WFS GetCapabilities 200"; else log_error "Verifikation $ws: WFS GetCapabilities -> $code (erwartet 200)"; rc=1; fi
    fi
  done <<< "$WS_TABLE"
  return "$rc"
}

uninstall_workspaces() {
  local -a existing
  local ws code rc=0
  local tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! read_workspaces > "$tmp"; then
    rm -f "$tmp"; log_error "Workspace-Liste nicht lesbar"; return 1
  fi
  mapfile -t existing < "$tmp"
  rm -f "$tmp"

  log "== Workspaces entfernen =="
  while IFS='|' read -r ws _; do
    [[ -n "$ws" ]] || continue
    if ! _has "$ws" "${existing[@]}"; then
      log "  Workspace $ws nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      howto_step "DELETE workspaces/$ws" "200" "-" "404 = schon weg, ohne recurse"
      continue
    fi
    _gs_write_body DELETE "workspaces/${ws}"
    code="$_GS_CODE"
    howto_step "DELETE workspaces/$ws" "200" "$code" "404 = schon weg, ohne recurse"
    case "$code" in
      200|201) log_ok "  Workspace $ws gelöscht" ;;
      404)     log "  Workspace $ws schon weg" ;;
      *)       log_gs_error "Workspace $ws löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$WS_TABLE"
  return "$rc"
}

_ds_body() {
  local name="$1" schema="$2" host="$3" port="$4" db="$5" user="$6" ns="$7" pw="$8" out="$9"
  jq -n \
    --rawfile pw <(printf '%s' "$pw") \
    --arg name "$name" --arg schema "$schema" --arg host "$host" --arg port "$port" \
    --arg db "$db" --arg user "$user" --arg ns "$ns" \
    '{dataStore:{name:$name,type:"PostGIS",enabled:true,disableOnConnFailure:false,
      connectionParameters:{entry:[
        {"@key":"schema","$":$schema},
        {"@key":"Estimated extends","$":"false"},
        {"@key":"fetch size","$":"1000"},
        {"@key":"encode functions","$":"false"},
        {"@key":"Expose primary keys","$":"true"},
        {"@key":"validate connections","$":"true"},
        {"@key":"Support on the fly geometry simplification","$":"false"},
        {"@key":"Connection timeout","$":"20"},
        {"@key":"create database","$":"false"},
        {"@key":"preparedStatements","$":"false"},
        {"@key":"database","$":$db},
        {"@key":"reWriteBatchedInserts","$":"false"},
        {"@key":"port","$":$port},
        {"@key":"passwd","$":$pw},
        {"@key":"dbtype","$":"postgis"},
        {"@key":"host","$":$host},
        {"@key":"namespace","$":$ns},
        {"@key":"Loose bbox","$":"false"},
        {"@key":"Test while idle","$":"false"},
        {"@key":"user","$":$user}
      ]}}}' > "$out"
}

install_datastores() {
  local -a existing
  local key ws ds schema uservar secret uri user password code rc=0 f tmp
  log "== Datastores =="
  log "  Basis: host=${_DB_HOST} port=${_DB_PORT} db=${_DB_NAME}"
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    uri="$(_ws_uri "$ws")"
    user="$(_env_resolve "$uservar")"
    password="$(_secret_get "$NAMESPACE" "$secret" "DB_PASSWORD")"
    if ! _pw_is_valid "$password"; then
      log_error "Datastore $ds: kein gültiges DB_PASSWORD im Secret $secret"
      rc=1
      continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_datastores "$ws" > "$tmp"; then
      rm -f "$tmp"; log_error "Datastore-Liste für $ws nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"
    rm -f "$tmp"
    if ! _has "$ds" "${existing[@]}"; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] $ds würde angelegt (schema=$schema, user=$user)"
        howto_step "POST workspaces/$ws/datastores" "201" "-" "JSON (20 Parameter, passwd=<PASSWORD>); schema=$schema user=$user host=${_DB_HOST} port=${_DB_PORT} db=${_DB_NAME}"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      _ds_body "$ds" "$schema" "$_DB_HOST" "$_DB_PORT" "$_DB_NAME" "$user" "$uri" "$password" "$f"
      _gs_write_body POST "workspaces/${ws}/datastores" "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "POST workspaces/$ws/datastores" "201" "$code" "JSON (20 Parameter, passwd=<PASSWORD>)"
      if [[ "$code" == "200" || "$code" == "201" ]]; then
        log_ok "  Datastore $ds angelegt"
      else
        log_gs_error "Datastore $ds anlegen fehlgeschlagen (HTTP $code)"; rc=1
      fi
    else
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] $ds würde aktualisiert (schema=$schema, user=$user)"
        howto_step "PUT workspaces/$ws/datastores/$ds" "200" "-" "JSON (20 Parameter, passwd=<PASSWORD>)"
        continue
      fi
      f="$(mktemp)"; chmod 600 "$f"
      _ds_body "$ds" "$schema" "$_DB_HOST" "$_DB_PORT" "$_DB_NAME" "$user" "$uri" "$password" "$f"
      _gs_write_body PUT "workspaces/${ws}/datastores/${ds}" "$f" 'application/json'
      code="$_GS_CODE"
      rm -f "$f"
      howto_step "PUT workspaces/$ws/datastores/$ds" "200" "$code" "JSON (20 Parameter, passwd=<PASSWORD>)"
      if [[ "$code" == "200" ]]; then
        log_ok "  Datastore $ds aktualisiert"
      else
        log_gs_error "Datastore $ds aktualisieren fehlgeschlagen (HTTP $code)"; rc=1
      fi
    fi
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_datastores() {
  local key ws ds schema uservar secret uri user code rc=0 cnt diag
  local en get_schema get_user get_db get_host get_ns
  log "== Verifikation Datastores =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    uri="$(_ws_uri "$ws")"
    user="$(_env_resolve "$uservar")"
    _gs_get "workspaces/${ws}/datastores/${ds}.json"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      en="$(jq -r '.dataStore.enabled // empty' "$_GS_BODY_FILE" 2>/dev/null)"
      get_schema="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="schema") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_user="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="user") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_db="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="database") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_host="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="host") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      get_ns="$(jq -r '.dataStore.connectionParameters.entry[]? | select(."@key"=="namespace") | ."$"' "$_GS_BODY_FILE" 2>/dev/null)"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds.json" "200" "200" "Parameter prüfen"
      if [[ "$en" == "true" && "$get_schema" == "$schema" && "$get_user" == "$user" && "$get_db" == "$_DB_NAME" && "$get_host" == "$_DB_HOST" && "$get_ns" == "$uri" ]]; then
        log_ok "  $ds: Parameter ok"
      else
        diag=""
        [[ "$en" == "true" ]] || diag+=" enabled(erwartet true, vorhanden $en)"
        [[ "$get_schema" == "$schema" ]] || diag+=" schema(erwartet $schema, vorhanden $get_schema)"
        [[ "$get_user" == "$user" ]] || diag+=" user(erwartet $user, vorhanden $get_user)"
        [[ "$get_db" == "$_DB_NAME" ]] || diag+=" database(erwartet $_DB_NAME, vorhanden $get_db)"
        [[ "$get_host" == "$_DB_HOST" ]] || diag+=" host(erwartet $_DB_HOST, vorhanden $get_host)"
        [[ "$get_ns" == "$uri" ]] || diag+=" namespace(erwartet $uri, vorhanden $get_ns)"
        log_error "Verifikation $ds: Parameter weichen ab:$diag"; rc=1
      fi
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds.json" "200" "$code" "Parameter prüfen"
      log_error "Verifikation $ds: GET workspaces/$ws/datastores/$ds.json -> $code (erwartet 200)"; rc=1
    fi
    # Verbindungstest: list=available erzwingt DB-Verbindung (Statuscode hart, Form tolerant).
    _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes.json?list=available"
    code="$_GS_CODE"
    if [[ "$code" == "200" ]]; then
      cnt="$(jq -r '.list.string[]? // empty' "$_GS_BODY_FILE" 2>/dev/null | awk 'END{print NR}')"
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds/featuretypes.json?list=available" "200" "200" "DB-Verbindungstest"
      log_ok "  $ds: list=available 200 ($cnt Namen)"
    else
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds/featuretypes.json?list=available" "200" "$code" "DB-Verbindungstest"
      log_error "Verifikation $ds: list=available -> $code (erwartet 200)"; rc=1
    fi
  done <<< "$DS_TABLE"
  return "$rc"
}

uninstall_datastores() {
  local -a existing
  local key ws ds schema uservar secret code rc=0 tmp
  log "== Datastores entfernen =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_datastores "$ws" > "$tmp"; then
      rm -f "$tmp"; log_error "Datastore-Liste für $ws nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"
    rm -f "$tmp"
    if ! _has "$ds" "${existing[@]}"; then
      log "  Datastore $ds nicht vorhanden — übersprungen"
      continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      howto_step "DELETE workspaces/$ws/datastores/$ds" "200" "-" "404 = schon weg, ohne recurse"
      continue
    fi
    _gs_write_body DELETE "workspaces/${ws}/datastores/${ds}"
    code="$_GS_CODE"
    howto_step "DELETE workspaces/$ws/datastores/$ds" "200" "$code" "404 = schon weg, ohne recurse"
    case "$code" in
      200|201) log_ok "  Datastore $ds gelöscht" ;;
      404)     log "  Datastore $ds schon weg" ;;
      *)       log_gs_error "Datastore $ds löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
    esac
  done <<< "$DS_TABLE"
  return "$rc"
}

_ft_title() {
  local t="$1" ws="$2"
  printf '%s' "${t//%ws%/$ws}"
}

_ft_body() {
  local name="$1" native="$2" ws="$3" title="$4" abstract="$5" kw="$6" cache="$7" out="$8"
  if [[ "$cache" == "false" ]]; then
    jq -n --arg ws "$ws" --arg name "$name" --arg native "$native" --arg title "$title" --arg abstract "$abstract" --argjson kw "$kw" \
      '{featureType:{name:$name,nativeName:$native,namespace:{name:$ws},title:$title,abstract:$abstract,
        keywords:{string:$kw},srs:"EPSG:4326",projectionPolicy:"FORCE_DECLARED",
        enabled:true,advertised:true,
        nativeBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        latLonBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        metadata:{entry:{"@key":"cachingEnabled","$":"false"}}}}' > "$out"
  else
    jq -n --arg ws "$ws" --arg name "$name" --arg native "$native" --arg title "$title" --arg abstract "$abstract" --argjson kw "$kw" \
      '{featureType:{name:$name,nativeName:$native,namespace:{name:$ws},title:$title,abstract:$abstract,
        keywords:{string:$kw},srs:"EPSG:4326",projectionPolicy:"FORCE_DECLARED",
        enabled:true,advertised:true,
        nativeBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"},
        latLonBoundingBox:{minx:-10,maxx:40,miny:35,maxy:71,crs:"EPSG:4326"}}}' > "$out"
  fi
}

_ft_cmp() {
  local f="$1" ws="$2" name="$3" native="$4" title="$5" abstract="$6" kw="$7" cache="$8" dev=0 v
  v="$(jq -r '.featureType.nativeName // empty' "$f" 2>/dev/null)"
  [[ "$v" == "$native" ]] || { log "  FeatureType $ws/$name: nativeName weicht ab (erwartet $native, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.title // empty' "$f" 2>/dev/null)"
  [[ "$v" == "$title" ]] || { log "  FeatureType $ws/$name: title weicht ab (erwartet $title, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.abstract // empty' "$f" 2>/dev/null)"
  [[ "$v" == "$abstract" ]] || { log "  FeatureType $ws/$name: abstract weicht ab — wird per PUT angepasst"; dev=1; }
  jq -e --argjson kw "$kw" '(.featureType.keywords.string // []) == $kw' "$f" >/dev/null 2>&1 \
    || { log "  FeatureType $ws/$name: keywords weicht ab — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.srs // empty' "$f" 2>/dev/null)"
  [[ "$v" == "EPSG:4326" ]] || { log "  FeatureType $ws/$name: srs weicht ab (erwartet EPSG:4326, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.projectionPolicy // empty' "$f" 2>/dev/null)"
  [[ "$v" == "FORCE_DECLARED" ]] || { log "  FeatureType $ws/$name: projectionPolicy weicht ab (erwartet FORCE_DECLARED, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.enabled // empty' "$f" 2>/dev/null)"
  [[ "$v" == "true" ]] || { log "  FeatureType $ws/$name: enabled weicht ab (erwartet true, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  v="$(jq -r '.featureType.advertised // empty' "$f" 2>/dev/null)"
  [[ "$v" == "true" ]] || { log "  FeatureType $ws/$name: advertised weicht ab (erwartet true, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  jq -e '.featureType.nativeBoundingBox | (.minx==-10 and .maxx==40 and .miny==35 and .maxy==71)' "$f" >/dev/null 2>&1 \
    || { log "  FeatureType $ws/$name: nativeBoundingBox weicht ab — wird per PUT angepasst"; dev=1; }
  jq -e '.featureType.latLonBoundingBox | (.minx==-10 and .maxx==40 and .miny==35 and .maxy==71)' "$f" >/dev/null 2>&1 \
    || { log "  FeatureType $ws/$name: latLonBoundingBox weicht ab — wird per PUT angepasst"; dev=1; }
  if [[ "$cache" == "false" ]]; then
    v="$(jq -r '[.featureType.metadata.entry] | flatten | map(select(."@key"=="cachingEnabled")) | .[0]."$" // empty' "$f" 2>/dev/null)"
    [[ "$v" == "false" ]] || { log "  FeatureType $ws/$name: cachingEnabled weicht ab (erwartet false, vorhanden $v) — wird per PUT angepasst"; dev=1; }
  fi
  return "$dev"
}

_ensure_default_style() {
  local ws="$1" name="$2" style="$3" code cur f
  _gs_get "workspaces/${ws}/layers/${name}.json"
  code="$_GS_CODE"
  if [[ "$code" == "200" ]]; then
    cur="$(jq -r '.layer.defaultStyle.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
    rm -f "$_GS_BODY_FILE"
    howto_step "GET workspaces/$ws/layers/$name.json" "200" "200" "defaultStyle prüfen $ws/$name"
    if [[ "$cur" == "$style" ]]; then
      log "  $ws/$name: Default-Style ok ($style)"
      return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  [dry-run] $ws/$name: Default-Style $style würde gesetzt (vorhanden $cur)"
      howto_step "PUT workspaces/$ws/layers/$name" "200" "-" "defaultStyle $ws/$name=$style"
      return 0
    fi
    f="$(mktemp)"; chmod 600 "$f"
    jq -nc --arg s "$style" '{layer:{defaultStyle:{name:$s}}}' > "$f"
    _gs_write_body PUT "workspaces/${ws}/layers/${name}" "$f" 'application/json'
    code="$_GS_CODE"; rm -f "$f"
    howto_step "PUT workspaces/$ws/layers/$name" "200" "$code" "defaultStyle $ws/$name=$style"
    [[ "$code" == "200" ]] || { log_gs_error "$ws/$name Default-Style setzen fehlgeschlagen (HTTP $code)"; return 1; }
    log_ok "  $ws/$name: Default-Style $style gesetzt"
  elif [[ "$code" == "404" ]]; then
    rm -f "$_GS_BODY_FILE"
    howto_step "GET workspaces/$ws/layers/$name.json" "200" "404" "defaultStyle prüfen $ws/$name"
    log "  $ws/$name nicht vorhanden (wird mit dem FeatureType angelegt)"
  else
    rm -f "$_GS_BODY_FILE"
    log_error "$ws/$name lesen fehlgeschlagen (HTTP $code)"; return 1
  fi
  return 0
}

install_featuretypes() {
  local -a existing avail
  local key ws ds schema uservar secret name native tpl cache style title abstract kw code rc=0 f tmp dsp
  log "== FeatureTypes =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    _ds_present "$ws" "$ds"; dsp=$?
    if [[ "$dsp" -eq 2 ]]; then
      log_error "FeatureTypes $ws/$ds: Datastore-Präsenz nicht lesbar"; rc=1; continue
    fi
    if [[ "$dsp" -eq 1 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        while IFS='|' read -r name native tpl cache style; do
          [[ -n "$name" ]] || continue
          title="$(_ft_title "$tpl" "$ws")"
          log "  [dry-run] $ws/$name würde angelegt (Datastore wird zuvor angelegt; native=$native erst danach prüfbar)"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "-" "FeatureType $ws/$name (native=$native)"
          log "  [dry-run] $ws/$name: Default-Style $style würde gesetzt"
          howto_step "PUT workspaces/$ws/layers/$name" "200" "-" "defaultStyle $ws/$name=$style"
        done <<< "$FT_TABLE"
      else
        log_error "FeatureTypes $ws/$ds: Datastore nicht vorhanden"; rc=1
      fi
      continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_available_natives "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "list=available für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t avail < "$tmp"; rm -f "$tmp"
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_featuretypes "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "FeatureType-Liste für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"; rm -f "$tmp"
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      title="$(_resolve_tpl "$(_meta ".layers[\"$name\"].title // empty")" "$ws" "")"
      abstract="$(_meta ".layers[\"$name\"].abstract // empty")"
      kw="$(printf '%s' "$_GS_METADATA" | jq -c ".layers[\"$name\"].keywords // []" 2>/dev/null)"
      if ! _has "$native" "${avail[@]}" && ! _has "$name" "${existing[@]}"; then
        log_error "FeatureType $ws/$name: Native-Name $native nicht in list=available"
        rc=1
        continue
      fi
      if ! _has "$name" "${existing[@]}"; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          log "  [dry-run] $ws/$name würde angelegt (title=$title)"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "-" "FeatureType $ws/$name (native=$native)"
        else
          f="$(mktemp)"; chmod 600 "$f"
          _ft_body "$name" "$native" "$ws" "$title" "$abstract" "$kw" "$cache" "$f"
          _gs_write_body POST "workspaces/${ws}/datastores/${ds}/featuretypes" "$f" 'application/json'
          code="$_GS_CODE"; rm -f "$f"
          howto_step "POST workspaces/$ws/datastores/$ds/featuretypes" "201" "$code" "FeatureType $ws/$name"
          if [[ "$code" == "200" || "$code" == "201" ]]; then
            log_ok "  $ws/$name angelegt"
          else
            log_gs_error "FeatureType $ws/$name anlegen fehlgeschlagen (HTTP $code)"; rc=1
          fi
        fi
      else
        if [[ "$DRY_RUN" -eq 1 ]]; then
          howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "-" "Vergleich $ws/$name"
        else
          _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
          if [[ "$_GS_CODE" == "200" ]]; then
            if _ft_cmp "$_GS_BODY_FILE" "$ws" "$name" "$native" "$title" "$abstract" "$kw" "$cache"; then
              rm -f "$_GS_BODY_FILE"
              log "  $ws/$name vorhanden, unverändert"
            else
              rm -f "$_GS_BODY_FILE"
              f="$(mktemp)"; chmod 600 "$f"
              _ft_body "$name" "$native" "$ws" "$title" "$abstract" "$kw" "$cache" "$f"
              _gs_write_body PUT "workspaces/${ws}/datastores/${ds}/featuretypes/${name}" "$f" 'application/json'
              code="$_GS_CODE"; rm -f "$f"
              howto_step "PUT workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "$code" "FeatureType $ws/$name"
              [[ "$code" == "200" ]] || { log_gs_error "FeatureType $ws/$name aktualisieren fehlgeschlagen (HTTP $code)"; rc=1; }
            fi
          else
            rm -f "$_GS_BODY_FILE"
            log_error "FeatureType $ws/$name: GET -> $_GS_CODE (erwartet 200)"; rc=1
          fi
        fi
      fi
      _ensure_default_style "$ws" "$name" "$style" || rc=1
      _ensure_layer_attribution "$ws" "$name" || rc=1
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

verify_featuretypes() {
  local key ws ds schema uservar secret name native tpl cache style title abstract kw code rc=0
  log "== Verifikation FeatureTypes =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      title="$(_resolve_tpl "$(_meta ".layers[\"$name\"].title // empty")" "$ws" "")"
      abstract="$(_meta ".layers[\"$name\"].abstract // empty")"
      kw="$(printf '%s' "$_GS_METADATA" | jq -c ".layers[\"$name\"].keywords // []" 2>/dev/null)"
      _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]]; then
        local en adv nn tt ss ab
        en="$(jq -r '.featureType.enabled // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        adv="$(jq -r '.featureType.advertised // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        nn="$(jq -r '.featureType.nativeName // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        tt="$(jq -r '.featureType.title // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        ss="$(jq -r '.featureType.srs // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        ab="$(jq -r '.featureType.abstract // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        kw_ok="no"; jq -e --argjson kw "$kw" '(.featureType.keywords.string // []) == $kw' "$_GS_BODY_FILE" >/dev/null 2>&1 && kw_ok="yes"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "200" "verifizieren $ws/$name"
        if [[ "$en" == "true" && "$adv" == "true" && "$nn" == "$native" && "$tt" == "$title" && "$ss" == "EPSG:4326" && "$ab" == "$abstract" && "$kw_ok" == "yes" ]]; then
          log_ok "  $ws/$name: FeatureType ok"
        else
          log_error "Verifikation $ws/$name: FeatureType weicht ab"; rc=1
        fi
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "$code" "verifizieren $ws/$name"
        log_error "Verifikation $ws/$name: FeatureType GET -> $code (erwartet 200)"; rc=1
      fi
      _gs_get "workspaces/${ws}/layers/${name}.json"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]]; then
        local dstyle
        dstyle="$(jq -r '.layer.defaultStyle.name // empty' "$_GS_BODY_FILE" 2>/dev/null)"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/layers/$name.json" "200" "200" "defaultStyle verifizieren $ws/$name"
        if [[ "$dstyle" == "$style" ]]; then
          log_ok "  $ws/$name: defaultStyle $style ok"
        else
          log_error "Verifikation $ws/$name: defaultStyle weicht ab (erwartet $style, vorhanden $dstyle)"; rc=1
        fi
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET workspaces/$ws/layers/$name.json" "200" "$code" "defaultStyle verifizieren $ws/$name"
        log_error "Verifikation $ws/$name: Layer GET -> $code (erwartet 200)"; rc=1
      fi
      _gs_get_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=DescribeFeatureType&typeNames=${ws}:${name}"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]] && ! grep -q 'ExceptionReport' "$_GS_BODY_FILE" 2>/dev/null; then
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs DescribeFeatureType" "200" "200" "kein ExceptionReport $ws/$name"
        log_ok "  $ws/$name: DescribeFeatureType ok"
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs DescribeFeatureType" "200" "$code" "kein ExceptionReport $ws/$name"
        log_error "Verifikation $ws/$name: DescribeFeatureType -> $code (erwartet 200, kein ExceptionReport)"; rc=1
      fi
      _gs_get_url "$GS_BASE/$ws/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=${ws}:${name}&resultType=hits"
      code="$_GS_CODE"
      if [[ "$code" == "200" ]] && ! grep -q 'ExceptionReport' "$_GS_BODY_FILE" 2>/dev/null; then
        local nm
        nm="$(grep -o 'numberMatched="[0-9]*"' "$_GS_BODY_FILE" 2>/dev/null | head -1)"
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs GetFeature hits" "200" "200" "kein ExceptionReport $ws/$name"
        log_ok "  $ws/$name: GetFeature hits ok${nm:+ ($nm)}"
      else
        rm -f "$_GS_BODY_FILE"
        howto_step "GET $ws/wfs GetFeature hits" "200" "$code" "kein ExceptionReport $ws/$name"
        log_error "Verifikation $ws/$name: GetFeature hits -> $code (erwartet 200, kein ExceptionReport)"; rc=1
      fi
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

uninstall_featuretypes() {
  local -a existing
  local key ws ds schema uservar secret name native tpl cache style code rc=0 tmp dsp
  log "== FeatureTypes entfernen =="
  while IFS='|' read -r key ws ds schema uservar secret; do
    [[ -n "$key" ]] || continue
    _ds_present "$ws" "$ds"; dsp=$?
    if [[ "$dsp" -eq 1 ]]; then
      log "  FeatureTypes von $ws/$ds nicht prüfbar (Datastore nicht vorhanden) — übersprungen"
      continue
    fi
    if [[ "$dsp" -eq 2 ]]; then
      log_error "FeatureTypes $ws/$ds: Datastore-Präsenz nicht lesbar"; rc=1; continue
    fi
    tmp="$(mktemp)"; chmod 600 "$tmp"
    if ! read_featuretypes "$ws" "$ds" > "$tmp"; then
      rm -f "$tmp"; log_error "FeatureType-Liste für $ws/$ds nicht lesbar"; rc=1; continue
    fi
    mapfile -t existing < "$tmp"; rm -f "$tmp"
    while IFS='|' read -r name native tpl cache style; do
      [[ -n "$name" ]] || continue
      if ! _has "$name" "${existing[@]}"; then
        log "  $ws/$name nicht vorhanden — übersprungen"
        continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        howto_step "DELETE workspaces/$ws/layers/$name" "200" "-" "404 = schon weg, ohne recurse ($ws/$name)"
        howto_step "DELETE workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "-" "404 = schon weg, ohne recurse ($ws/$name)"
        continue
      fi
      _gs_write_body DELETE "workspaces/${ws}/layers/${name}"
      code="$_GS_CODE"
      howto_step "DELETE workspaces/$ws/layers/$name" "200" "$code" "404 = schon weg, ohne recurse ($ws/$name)"
      case "$code" in
        200|201) log_ok "  $ws/$name: Layer gelöscht" ;;
        404)     log "  $ws/$name: Layer schon weg" ;;
        *)       log_gs_error "Layer $ws/$name löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
      _gs_write_body DELETE "workspaces/${ws}/datastores/${ds}/featuretypes/${name}"
      code="$_GS_CODE"
      howto_step "DELETE workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "$code" "404 = schon weg, ohne recurse ($ws/$name)"
      case "$code" in
        200|201) log_ok "  $ws/$name: FeatureType gelöscht" ;;
        404)     log "  $ws/$name: FeatureType schon weg" ;;
        *)       log_gs_error "FeatureType $ws/$name löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
      esac
    done <<< "$FT_TABLE"
  done <<< "$DS_TABLE"
  return "$rc"
}

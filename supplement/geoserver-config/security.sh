#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
# security.sh - Attribut-Mapping und Layer-ACLs.
# Wird vom Einstieg genau einmal gesourct.

_apply_attr_mapping() {
  local ws="$1" ds="$2" name="$3" native="$4" target="$5" code has_t has_n src new put_body
  _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
  code="$_GS_CODE"
  if [[ "$code" != "200" ]]; then
    rm -f "$_GS_BODY_FILE"
    if [[ "$DRY_RUN" -eq 1 && "$code" == "404" ]]; then
      log "  [dry-run] $ws/$name: Attribut-Mapping $target←$native würde gesetzt (FeatureType wird zuvor angelegt)"
      howto_step "PUT workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "-" "Attribut-Mapping $target←$native"
      return 0
    fi
    log_error "FeatureType $ws/$name lesen fehlgeschlagen (HTTP $_GS_CODE)"; return 1
  fi

  has_t="$(jq -r --arg t "$target" '[.featureType.attributes.attribute[]?.name] | index($t) != null' "$_GS_BODY_FILE" 2>/dev/null)"
  has_n="$(jq -r --arg n "$native"  '[.featureType.attributes.attribute[]?.name] | index($n) != null' "$_GS_BODY_FILE" 2>/dev/null)"
  src="$(jq -r --arg t "$target" '.featureType.attributes.attribute[]? | select(.name==$t) | .source // empty' "$_GS_BODY_FILE" 2>/dev/null | head -1)"

  if [[ "$has_t" == "true" ]]; then
    if [[ "$has_n" == "true" ]]; then
      rm -f "$_GS_BODY_FILE"
      log_error "FeatureType $ws/$name: doppeltes Attribut ($target und $native veröffentlicht)"
      return 1
    fi
    if [[ "$src" == "$native" ]]; then
      rm -f "$_GS_BODY_FILE"
      howto_step "GET workspaces/$ws/datastores/$ds/featuretypes/$name.json" "200" "200" "Attribut-Mapping $target←$native prüfen"
      log "  $ws/$name: Attribut-Mapping ok ($target ← $native)"
      return 0
    fi
    rm -f "$_GS_BODY_FILE"
    log_error "FeatureType $ws/$name: Attribut $target mit abweichender/fehlender Quelle (erwartet $native, vorhanden ${src:-leer})"
    return 1
  fi

  if [[ "$has_n" != "true" ]]; then
    rm -f "$_GS_BODY_FILE"
    log_error "FeatureType $ws/$name: weder $target noch $native veröffentlicht (Quelle fehlt)"
    return 1
  fi

  new="$(mktemp)"; chmod 600 "$new"
  if ! jq -c --arg n "$native" --arg t "$target" \
      '[.featureType.attributes.attribute[] | if .name == $n then (.name = $t | .source = $n) else . end]' \
      "$_GS_BODY_FILE" > "$new" 2>/dev/null; then
    rm -f "$_GS_BODY_FILE" "$new"; log_error "FeatureType $ws/$name: Attributliste nicht transformierbar"; return 1
  fi
  rm -f "$_GS_BODY_FILE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] $ws/$name: Attribut $native → $target (source=$native) würde gesetzt"
    howto_step "PUT workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "-" "Attribut-Mapping $target←$native"
    rm -f "$new"
    return 0
  fi

  put_body="$(mktemp)"; chmod 600 "$put_body"
  jq -n --slurpfile a "$new" '{featureType:{attributes:{attribute:$a[0]}}}' > "$put_body" 2>/dev/null
  rm -f "$new"
  _gs_write_body PUT "workspaces/${ws}/datastores/${ds}/featuretypes/${name}" "$put_body" 'application/json'
  code="$_GS_CODE"; rm -f "$put_body"
  howto_step "PUT workspaces/$ws/datastores/$ds/featuretypes/$name" "200" "$code" "Attribut-Mapping $target←$native"
  [[ "$code" == "200" ]] || { log_gs_error "FeatureType $ws/$name: Attribut-Mapping setzen fehlgeschlagen (HTTP $code)"; return 1; }
  log_ok "  $ws/$name: Attribut-Mapping $target ← $native gesetzt"
  return 0
}

install_attr_mapping() {
  local key ws ds schema uservar secret name native target rc=0
  log "== Attribut-Mapping =="
  while IFS='|' read -r name native target; do
    [[ -n "$name" ]] || continue
    while IFS='|' read -r key ws ds _ _ _; do
      [[ -n "$key" ]] || continue
      _apply_attr_mapping "$ws" "$ds" "$name" "$native" "$target" || rc=1
    done <<< "$DS_TABLE"
  done <<< "$ATTR_MAP_TABLE"
  return "$rc"
}

verify_attr_mapping() {
  local key ws ds schema uservar secret name native target code rc=0 has_t has_n src
  log "== Verifikation Attribut-Mapping =="
  while IFS='|' read -r name native target; do
    [[ -n "$name" ]] || continue
    while IFS='|' read -r key ws ds _ _ _; do
      [[ -n "$key" ]] || continue
      _gs_get "workspaces/${ws}/datastores/${ds}/featuretypes/${name}.json"
      code="$_GS_CODE"
      if [[ "$code" != "200" ]]; then
        rm -f "$_GS_BODY_FILE"
        log_error "Verifikation $ws/$name: GET -> $code (erwartet 200)"; rc=1; continue
      fi
      has_t="$(jq -r --arg t "$target" '[.featureType.attributes.attribute[]?.name] | index($t) != null' "$_GS_BODY_FILE" 2>/dev/null)"
      has_n="$(jq -r --arg n "$native"  '[.featureType.attributes.attribute[]?.name] | index($n) != null' "$_GS_BODY_FILE" 2>/dev/null)"
      src="$(jq -r --arg t "$target" '.featureType.attributes.attribute[]? | select(.name==$t) | .source // empty' "$_GS_BODY_FILE" 2>/dev/null | head -1)"
      rm -f "$_GS_BODY_FILE"
      if [[ "$has_t" == "true" && "$src" == "$native" && "$has_n" == "false" ]]; then
        log_ok "  $ws/$name: Attribut-Mapping $target ← $native ok"
      else
        log_error "Verifikation $ws/$name: Attribut-Mapping fehlerhaft (target=$has_t, source=${src:-leer}, native-extra=$has_n)"; rc=1
      fi
    done <<< "$DS_TABLE"
  done <<< "$ATTR_MAP_TABLE"
  return "$rc"
}

_stage_role() {
  local want="$1" key _ user roles _ r
  while IFS='|' read -r key _ user roles _; do
    [[ -n "$key" ]] || continue
    [[ "$key" == "$want" ]] || continue
    for r in ${roles//,/ }; do
      [[ "$r" == "P2D2_WFST_"* ]] && { printf '%s' "$r"; return 0; }
    done
  done <<< "$SOL_TABLE"
  return 1
}

_acl_roles_equal() {
  local a="$1" b="$2" sa sb
  sa="$(printf '%s' "$a" | tr ',' '\n' | sort | tr '\n' ',')"
  sb="$(printf '%s' "$b" | tr ',' '\n' | sort | tr '\n' ',')"
  [[ "$sa" == "$sb" ]]
}

_acl_get() {
  local out="$1"
  _gs_get "security/acl/layers"
  [[ "$_GS_CODE" == "200" ]] || { rm -f "$_GS_BODY_FILE"; log_error "Lesen security/acl/layers fehlgeschlagen (HTTP $_GS_CODE)"; return 1; }
  cp "$_GS_BODY_FILE" "$out" 2>/dev/null || { rm -f "$_GS_BODY_FILE"; return 1; }
  rm -f "$_GS_BODY_FILE"
  return 0
}

_protect_roles() {
  local r
  for r in ${1//,/ }; do
    [[ -n "$r" ]] || continue
    _has "$r" "${_KEEP_ROLES[@]}" || _KEEP_ROLES+=("$r")
  done
}

_acl_apply() {
  local ws="$1" layer="$2" mode="$3" roles="$4" map="$5" rule cur code body
  rule="${ws}.${layer}.${mode}"
  cur="$(jq -r --arg r "$rule" '.[$r] // empty' "$map" 2>/dev/null)"
  if [[ -n "$cur" ]]; then
    if _acl_roles_equal "$cur" "$roles"; then
      log "  ACL $rule vorhanden, unverändert"
      return 0
    fi
    log_error "ACL $rule Konflikt: vorhanden '$cur', erwartet '$roles' — keine Änderung"
    return 1
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  [dry-run] ACL $rule würde gesetzt ($roles)"
    howto_step "POST security/acl/layers" "200/201/409" "-" "$rule=$roles"
    return 0
  fi
  body="$(mktemp)"; chmod 600 "$body"
  jq -nc --arg rule "$rule" --arg roles "$roles" '{($rule):$roles}' > "$body"
  _gs_write_body POST "security/acl/layers" "$body" 'application/json'
  code="$_GS_CODE"; rm -f "$body"
  howto_step "POST security/acl/layers" "200/201/409" "$code" "$rule=$roles"
  case "$code" in
    200|201|409) log_ok "  ACL $rule gesetzt ($roles)" ;;
    *)           log_gs_error "ACL $rule setzen fehlgeschlagen (HTTP $code)"; return 1 ;;
  esac
  return 0
}

install_acls() {
  local key ws ds _ _ _ layer rroles wroles stage_rule rc=0 tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! _acl_get "$tmp"; then rm -f "$tmp"; return 1; fi
  log "== Layer-ACLs =="
  while IFS='|' read -r key ws ds _ _ _; do
    [[ -n "$key" ]] || continue
    while IFS='|' read -r layer rroles wroles; do
      [[ -n "$layer" ]] || continue
      stage_rule="$(_stage_role "$key")"
      wroles="${wroles//%stage%/$stage_rule}"
      _acl_apply "$ws" "$layer" "r" "$rroles" "$tmp" || rc=1
      _acl_apply "$ws" "$layer" "w" "$wroles" "$tmp" || rc=1
    done <<< "$ACL_LAYER_TABLE"
  done <<< "$DS_TABLE"
  rm -f "$tmp"
  return "$rc"
}

verify_acls() {
  local key ws ds _ _ _ layer rroles wroles stage_rule rule roles cur rc=0 tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! _acl_get "$tmp"; then rm -f "$tmp"; return 1; fi
  log "== Verifikation Layer-ACLs =="
  while IFS='|' read -r key ws ds _ _ _; do
    [[ -n "$key" ]] || continue
    while IFS='|' read -r layer rroles wroles; do
      [[ -n "$layer" ]] || continue
      stage_rule="$(_stage_role "$key")"
      wroles="${wroles//%stage%/$stage_rule}"
      for mode in r w; do
        roles="$rroles"; [[ "$mode" == "w" ]] && roles="$wroles"
        rule="${ws}.${layer}.${mode}"
        cur="$(jq -r --arg r "$rule" '.[$r] // empty' "$tmp" 2>/dev/null)"
        if [[ -n "$cur" ]] && _acl_roles_equal "$cur" "$roles"; then
          log_ok "  $rule ok"
        else
          log_error "Verifikation $rule: fehlt oder weicht ab"; rc=1
        fi
      done
    done <<< "$ACL_LAYER_TABLE"
  done <<< "$DS_TABLE"
  rm -f "$tmp"
  return "$rc"
}

uninstall_acls() {
  local key ws ds _ _ _ layer rroles wroles stage_rule rule roles cur code rc=0 tmp
  tmp="$(mktemp)"; chmod 600 "$tmp"
  if ! _acl_get "$tmp"; then rm -f "$tmp"; return 1; fi
  log "== Layer-ACLs entfernen =="
  while IFS='|' read -r key ws ds _ _ _; do
    [[ -n "$key" ]] || continue
    while IFS='|' read -r layer rroles wroles; do
      [[ -n "$layer" ]] || continue
      stage_rule="$(_stage_role "$key")"
      wroles="${wroles//%stage%/$stage_rule}"
      for mode in r w; do
        roles="$rroles"; [[ "$mode" == "w" ]] && roles="$wroles"
        rule="${ws}.${layer}.${mode}"
        cur="$(jq -r --arg r "$rule" '.[$r] // empty' "$tmp" 2>/dev/null)"
        [[ -n "$cur" ]] || { log "  ACL $rule nicht vorhanden — übersprungen"; continue; }
        _gs_get "workspaces/${ws}/layers/${layer}.json"
        code="$_GS_CODE"
        if [[ "$code" == "200" ]]; then
          rm -f "$_GS_BODY_FILE"
          log_warn "  ACL $rule behalten (Layer $ws/$layer besteht weiter)"
          _protect_roles "$roles"
          continue
        fi
        rm -f "$_GS_BODY_FILE"
        if ! _acl_roles_equal "$cur" "$roles"; then
          log_error "ACL $rule abweichend ('$cur') — nicht gelöscht"; rc=1
          _protect_roles "$cur"
          continue
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
          howto_step "DELETE security/acl/layers/$rule" "200" "-" "404 = schon weg"
          continue
        fi
        _gs_write_body DELETE "security/acl/layers/$rule"
        code="$_GS_CODE"
        howto_step "DELETE security/acl/layers/$rule" "200" "$code" "404 = schon weg"
        case "$code" in
          200|201) log_ok "  ACL $rule gelöscht" ;;
          404)     log "  ACL $rule schon weg" ;;
          *)       log_gs_error "ACL $rule löschen fehlgeschlagen (HTTP $code)"; rc=1 ;;
        esac
      done
    done <<< "$ACL_LAYER_TABLE"
  done <<< "$DS_TABLE"
  rm -f "$tmp"
  return "$rc"
}

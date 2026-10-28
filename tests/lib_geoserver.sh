#!/usr/bin/env bash
# tests/lib_geoserver.sh - gemeinsame Teile der GeoServer-Suite-33 (Stubs, Zustand, Helfer).
# Wird von jeder Gruppe gesourct; kein eigenstaendig ausfuehrbares Programm.
# 'Snapshot-Install Exit 0' ist seit Turn 3 eine Setup-Invariante (ensure_snap_installed) und keine Assertion mehr.

gs_init_group_env() {
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${GEOSERVER_CONFIG_SCRIPT:-$REPO/supplement/p2d2-geoserver-config_v1.sh}"

GS_GROUP_ID="$(basename "${BASH_SOURCE[1]:-}" 2>/dev/null | sed -E 's/^33_geoserver_config_([0-9]+)\.sh$/\1/' || true)"
GS_GROUP_T0="${EPOCHREALTIME:-0}"
GS_SNAP_BUILD_S=0
GS_SCENARIO_COUNT=0

T="$(mktemp -d)" || exit 1
case "$T" in
  /tmp/tmp.*) ;;
  *) echo "unsicheres T: abgebrochen" >&2; exit 1 ;;
esac
trap gs_group_end EXIT
WORK="$T/work"
mkdir -p "$WORK"

# ── Zustand + Logs ─────────────────────────────────────────────────────────────
export GS_STATE_DIR="$T/gs"
export KUBE_STATE_DIR="$T/kube"
export CURL_LOG="$T/curl.log"
export CURL_BODY_LOG="$T/curl-body.log"
export CURL_STDIN_LOG="$T/curl-stdin.log"
export KUBECTL_LOG="$T/kubectl.log"
export JQ_LOG="$T/jq.log"
export SLEEP_LOG="$T/sleep.log"

# Stub-Verzeichnis voranstellen (überschreibt die globalen tests/stubs/*).
STUBS="$T/stubs"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

# Datastore-Konfiguration für alle Läufe (C2) + DB-Testpasswort (nicht-sensibel).
export P2D2_BASE_DB_HOST="central-db.test.svc.cluster.local"
export P2D2_BASE_DB_PORT="5432"
export P2D2_BASE_DB_NAME="p2d2"
export P2D2_MAIN_DB_USER="P2D2-MAIN"
export P2D2_DEVELOP_DB_USER="P2D2-DEVELOP"
export P2D2_DE1_DB_USER="P2D2-DE1"
export P2D2_DE2_DB_USER="P2D2-DE2"
export P2D2_FV_DB_USER="P2D2-FV"
DB_PW="dbpassword1234567890"
DB_PW_B64="ZGJwYXNzd29yZDEyMzQ1Njc4OTA="

# ── curl-Stub (GeoServer-REST, zustandsbehaftet) ──────────────────────────────
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${CURL_LOG:?}"

url=""; method="GET"; has_w=0; body_file=""; out_file=""; prev=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    -X) prev="X" ;;
    -w) has_w=1 ;;
    -o) prev="o" ;;
    --data-binary) prev="data" ;;
    *)
      case "$prev" in
        X) method="$a"; prev="" ;;
        o) out_file="$a"; prev="" ;;
        data) body_file="${a#@}"; prev="" ;;
      esac ;;
  esac
done

stdin_data="$(cat 2>/dev/null || true)"
printf 'STDIN=%s\n' "$stdin_data" >> "${CURL_STDIN_LOG:?}"

if [ -n "$body_file" ] && [ -f "$body_file" ]; then
  { printf 'URL=%s METHOD=%s\n' "$url" "$method"; cat "$body_file"; printf '\n---\n'; } >> "${CURL_BODY_LOG:?}"
fi

S="${GS_STATE_DIR:?}"
has_role() { grep -qx "$1" "$S/roles.list" 2>/dev/null; }
has_user() { grep -qx "$1" "$S/users.list" 2>/dev/null; }
has_ws()   { grep -qx "$1" "$S/workspaces.list" 2>/dev/null; }
has_ds()   { grep -qx "$2" "$S/ds/$1.list" 2>/dev/null; }
xml_esc()  { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

roles_json() {
  printf '{"roles":['
  local first=1 r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [ "$first" = "1" ] || printf ','
    printf '"%s"' "$r"; first=0
  done < "$S/roles.list"
  printf ']}'
}
users_json() {
  printf '{"users":['
  local first=1 u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [ "$first" = "1" ] || printf ','
    printf '{"userName":"%s","password":null,"enabled":true}' "$u"; first=0
  done < "$S/users.list"
  printf ']}'
}
userroles_json() {
  printf '{"roles":['
  local first=1 r
  if [ -f "$S/userroles/$1.list" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      [ "$first" = "1" ] || printf ','
      printf '"%s"' "$r"; first=0
    done < "$S/userroles/$1.list"
  fi
  printf ']}'
}
workspaces_json() {
  if [ "${GS_WS_EMPTY_FORM:-}" = "str" ]; then printf '{"workspaces":{"workspace":""}}'; return; fi
  if [ "${GS_WS_EMPTY_FORM:-}" = "arr" ]; then printf '{"workspaces":{"workspace":[]}}'; return; fi
  printf '{"workspaces":{"workspace":['
  local first=1 w
  if [ -f "$S/workspaces.list" ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      [ "$first" = "1" ] || printf ','
      printf '{"name":"%s","href":""}' "$w"; first=0
    done < "$S/workspaces.list"
  fi
  printf ']}}'
}
datastores_json() {
  if [ -f "$S/ds/$1.list" ]; then
    printf '{"dataStores":{"dataStore":['
    local first=1 d
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      [ "$first" = "1" ] || printf ','
      printf '{"name":"%s","href":""}' "$d"; first=0
    done < "$S/ds/$1.list"
    printf ']}}'
  else
    printf '{"dataStores":""}'
  fi
}
featuretypes_json() {
  if [ -f "$S/ft/$1/$2.list" ]; then
    printf '{"featureTypes":{"featureType":['
    local first=1 n
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ "$first" = "1" ] || printf ','
      printf '{"name":"%s","href":""}' "$n"; first=0
    done < "$S/ft/$1/$2.list"
    printf ']}}'
  else
    printf '{"featureTypes":""}'
  fi
}

# ── ACL-Zustand ({"<rule>":"<roles>"}) ───────────────────────────────────────
acl_map_json() { cat "$S/acl.map" 2>/dev/null || printf '{}'; }
acl_set() {
  jq --arg rule "$1" --arg roles "$2" '.[$rule] = $roles' "$S/acl.map" > "$S/acl.map.tmp" 2>/dev/null
  mv "$S/acl.map.tmp" "$S/acl.map"
}
acl_del() {
  jq --arg rule "$1" 'del(.[$rule])' "$S/acl.map" > "$S/acl.map.tmp" 2>/dev/null
  mv "$S/acl.map.tmp" "$S/acl.map"
}
acl_has() { jq -e --arg rule "$1" 'has($rule)' "$S/acl.map" >/dev/null 2>&1; }

code="200"; body=""
case "$url" in
  *"/ows"*)
    if [ "${GS_NEG200:-0}" = "1" ]; then code=200
    else case "$stdin_data" in *falsch_*) code=401 ;; *) code=200 ;; esac
    fi ;;
  *"/security/roles.json")
    [ "${GS_PREFLIGHT_FAIL:-0}" = "1" ] && code=500
    if [ -n "${GS_NOT_READY_FIRST:-}" ] && [ "$method" = "GET" ]; then
      c=0; [ -f "$S/roles_not_ready_count" ] && c="$(cat "$S/roles_not_ready_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/roles_not_ready_count"
      [ "$c" -le "$GS_NOT_READY_FIRST" ] && code=503
    fi
    empty_roles=0
    if [ -n "${GS_ROLES_EMPTY_ON:-}" ]; then
      c=0; [ -f "$S/roles_empty_count" ] && c="$(cat "$S/roles_empty_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/roles_empty_count"
      [ "$c" -ge "$GS_ROLES_EMPTY_ON" ] && empty_roles=1
    fi
    if [ "$empty_roles" = "1" ]; then body='{"roles":[]}'; else body="$(roles_json)"; fi ;;
  *"/security/usergroup/users.json")
    if [ -n "${GS_USERS_FAIL_ON:-}" ]; then
      c=0; [ -f "$S/users_get_count" ] && c="$(cat "$S/users_get_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/users_get_count"
      [ "$c" -ge "$GS_USERS_FAIL_ON" ] && code=500
    fi
    [ "${GS_USERS_500:-0}" = "1" ] && code=500
    empty_users=0
    [ "${GS_USERS_EMPTY:-0}" = "1" ] && empty_users=1
    if [ -n "${GS_USERS_EMPTY_ON:-}" ]; then
      c=0; [ -f "$S/users_empty_count" ] && c="$(cat "$S/users_empty_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/users_empty_count"
      [ "$c" -ge "$GS_USERS_EMPTY_ON" ] && empty_users=1
    fi
    if [ "$empty_users" = "1" ]; then body='{"users":[]}'; else body="$(users_json)"; fi ;;
  *"/security/roles/user/"*".json")
    u="${url##*/security/roles/user/}"; u="${u%.json}"
    body="$(userroles_json "$u")" ;;
  *"/security/roles/role/"*"/user/"*)
    rest="${url#*/security/roles/role/}"
    role="${rest%%/user/*}"; user="${rest#*/user/}"
    case "$method" in
      POST)
        if has_role "$role" && has_user "$user"; then
          grep -qx "$role" "$S/userroles/$user.list" 2>/dev/null || printf '%s\n' "$role" >> "$S/userroles/$user.list"
          code=200
        else code=500; fi ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then code=500
        elif [ -f "$S/userroles/$user.list" ] && grep -qx "$role" "$S/userroles/$user.list"; then
          grep -vx "$role" "$S/userroles/$user.list" > "$S/userroles/$user.list.tmp" 2>/dev/null || true
          mv "$S/userroles/$user.list.tmp" "$S/userroles/$user.list"
          code=200
        else code=404; fi ;;
    esac ;;
  *"/security/roles/role/"*)
    role="${url##*/security/roles/role/}"
    case "$method" in
      POST)
        if has_role "$role"; then code=200
        else printf '%s\n' "$role" >> "$S/roles.list"; code=201; fi ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then code=500
        elif has_role "$role"; then
          grep -vx "$role" "$S/roles.list" > "$S/roles.list.tmp" 2>/dev/null || true
          mv "$S/roles.list.tmp" "$S/roles.list"
          code=200
        else code=404; fi ;;
    esac ;;
  *"/security/usergroup/users")
    case "$method" in
      POST)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          u="$(sed -n 's/.*<userName>\([^<]*\)<\/userName>.*/\1/p' "$body_file")"
          if [ -n "$u" ] && ! has_user "$u"; then
            printf '%s\n' "$u" >> "$S/users.list"
            : > "$S/userroles/$u.list"
            code=201
          else code=200; fi
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/security/usergroup/user/"*)
    user="${url##*/security/usergroup/user/}"
    case "$method" in
      POST) has_user "$user" && code=200 || code=500 ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then code=500
        elif has_user "$user"; then
          grep -vx "$user" "$S/users.list" > "$S/users.list.tmp" 2>/dev/null || true
          mv "$S/users.list.tmp" "$S/users.list"
          rm -f "$S/userroles/$user.list"
          code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/security/acl/layers/"*)
    rule="${url##*/security/acl/layers/}"
    case "$method" in
      DELETE)
        if [ "${GS_ACL_DELETE_FAIL:-0}" = "1" ]; then code=500
        elif acl_has "$rule"; then acl_del "$rule"; code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/security/acl/layers")
    case "$method" in
      GET)
        if [ "${GS_ACL_GET_FAIL:-0}" = "1" ]; then code=500
        else body="$(acl_map_json)"; code=200; fi ;;
      POST)
        if [ "${GS_ACL_POST_FAIL:-0}" = "1" ]; then code=500
        elif [ -n "$body_file" ] && [ -f "$body_file" ]; then
          rule="$(jq -r 'keys[0] // empty' "$body_file" 2>/dev/null)"
          roles="$(jq -r '.[keys[0]] // empty' "$body_file" 2>/dev/null)"
          if [ -n "$rule" ]; then
            if acl_has "$rule"; then acl_set "$rule" "$roles"; code=200
            else acl_set "$rule" "$roles"; code=201; fi
          else code=500; fi
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces.json")
    body="$(workspaces_json)" ;;
  *"/rest/workspaces/"*"/datastores.json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    if has_ws "$ws"; then body="$(datastores_json "$ws")"; else code=404; fi ;;
  *"list=available"*)
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    if ! has_ws "$ws"; then code=404
    elif [ "${GS_LIST_AVAILABLE_FAIL:-0}" = "1" ]; then code=500
    elif [ -n "${GS_LIST_AVAILABLE_FAIL_ON:-}" ]; then
      c=0; [ -f "$S/list_avail_count" ] && c="$(cat "$S/list_avail_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/list_avail_count"
      if [ "$c" -ge "$GS_LIST_AVAILABLE_FAIL_ON" ]; then code=500
      else body='{"list":{"string":["p2d2_containers","v_grabflure_aktuell","p2d2_grabflure_versionen","v_graeber_aktuell","p2d2_graeber_versionen"]}}'; code=200; fi
    elif [ "${GS_LIST_AVAILABLE_MISSING_NATIVE:-0}" = "1" ]; then body='{"list":{"string":["p2d2_containers","v_grabflure_aktuell","p2d2_grabflure_versionen","p2d2_graeber_versionen"]}}'; code=200
    else body='{"list":{"string":["p2d2_containers","v_grabflure_aktuell","p2d2_grabflure_versionen","v_graeber_aktuell","p2d2_graeber_versionen"]}}'; code=200; fi ;;
  *"/rest/workspaces/"*"/datastores/"*"/featuretypes.json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url#*/datastores/}"; ds="${ds%%/*}"
    if [ "${GS_FT_LIST_FAIL:-0}" = "1" ]; then code=500
    elif [ -f "$S/ds/$ws/$ds.json" ]; then body="$(featuretypes_json "$ws" "$ds")"
    else code=500; fi ;;
  *"/rest/workspaces/"*"/datastores/"*"/featuretypes/"*".json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url#*/datastores/}"; ds="${ds%%/*}"
    name="${url##*/featuretypes/}"; name="${name%.json}"
    if [ -f "$S/ft/$ws/$ds/$name.json" ]; then body="$(cat "$S/ft/$ws/$ds/$name.json")"; code=200
    else code=404; fi ;;
  *"/rest/workspaces/"*"/datastores/"*"/featuretypes")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url#*/datastores/}"; ds="${ds%%/*}"
    case "$method" in
      POST)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          name="$(jq -r '.featureType.name // empty' "$body_file" 2>/dev/null)"
          if [ -n "$name" ]; then
            mkdir -p "$S/ft/$ws/$ds" "$S/layers/$ws"
            if [ "$name" = "geo-containers" ]; then
              # Simuliere GeoServer: generiert Attribute aus nativen Spalten (osm_name, kein name).
              jq '.featureType.attributes = {"attribute":[{"name":"id","minOccurs":1,"maxOccurs":1,"nillable":false,"binding":"java.lang.Integer"},{"name":"category","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"},{"name":"osm_name","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"},{"name":"geometry","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"org.locationtech.jts.geom.MultiPolygon"}]}' "$body_file" > "$S/ft/$ws/$ds/$name.json"
            else
              cp "$body_file" "$S/ft/$ws/$ds/$name.json"
            fi
            grep -qx "$name" "$S/ft/$ws/$ds.list" 2>/dev/null || printf '%s\n' "$name" >> "$S/ft/$ws/$ds.list"
            # Realistischer Default-Style (graeber=generic, sonst polygon); Override erzwingt Reparatur-PUT.
            if [ -n "${GS_DEFAULT_STYLE:-}" ]; then
              printf '%s' "${GS_DEFAULT_STYLE}" > "$S/layers/$ws/$name.style"
            elif [ "$name" = "graeber" ]; then
              printf 'generic' > "$S/layers/$ws/$name.style"
            else
              printf 'polygon' > "$S/layers/$ws/$name.style"
            fi
            code=201
          else code=500; fi
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*"/datastores/"*"/featuretypes/"*)
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url#*/datastores/}"; ds="${ds%%/*}"
    name="${url##*/featuretypes/}"
    case "$method" in
      PUT)
        if [ -n "$body_file" ] && [ -f "$body_file" ] && [ -f "$S/ft/$ws/$ds/$name.json" ]; then
          # Merge statt Replace: ein Mapping-PUT trägt nur attributes, kein vollständiges FeatureType.
          jq -s '.[0] * .[1]' "$S/ft/$ws/$ds/$name.json" "$body_file" > "$S/ft/$ws/$ds/$name.tmp" 2>/dev/null
          mv "$S/ft/$ws/$ds/$name.tmp" "$S/ft/$ws/$ds/$name.json"
          code=200
        else code=404; fi ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then
          [ -n "${GS_403_BODY:-}" ] && body="$GS_403_BODY"
          code=500
        elif [ -f "$S/ft/$ws/$ds/$name.json" ]; then
          rm -f "$S/ft/$ws/$ds/$name.json"
          grep -vx "$name" "$S/ft/$ws/$ds.list" > "$S/ft/$ws/$ds.list.tmp" 2>/dev/null || true
          mv "$S/ft/$ws/$ds.list.tmp" "$S/ft/$ws/$ds.list"
          # Bei verbleibendem Layer (nur Layer-DELETE scheiterte) den Layer-Style NICHT entfernen.
          if [ "${GS_LAYER_DELETE_FAIL:-0}" != "1" ]; then
            rm -f "$S/layers/$ws/$name.style"
          fi
          code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*"/layers/"*".json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    name="${url##*/layers/}"; name="${name%.json}"
    if [ -f "$S/layers/$ws/$name.style" ]; then
      s="$(cat "$S/layers/$ws/$name.style")"
      attr="null"
      [ -f "$S/layers/$ws/$name.attr.json" ] && attr="$(cat "$S/layers/$ws/$name.attr.json")"
      body="$(jq -nc --arg n "$name" --arg s "$s" --argjson attr "$attr" '{layer:{name:$n,defaultStyle:{name:$s},attribution:$attr}}' 2>/dev/null)"
      code=200
    else code=404; fi ;;
  *"/rest/workspaces/"*"/layers/"*)
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    name="${url##*/layers/}"
    case "$method" in
      PUT)
        if [ -n "$body_file" ] && [ -f "$body_file" ] && [ -f "$S/layers/$ws/$name.style" ]; then
          s="$(jq -r '.layer.defaultStyle.name // empty' "$body_file" 2>/dev/null)"
          [ -n "$s" ] && printf '%s' "$s" > "$S/layers/$ws/$name.style"
          if jq -e '.layer.attribution != null' "$body_file" >/dev/null 2>&1; then
            jq -c '.layer.attribution' "$body_file" > "$S/layers/$ws/$name.attr.json"
          fi
          code=200
        else code=404; fi ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ] || [ "${GS_LAYER_DELETE_FAIL:-0}" = "1" ]; then
          [ -n "${GS_403_BODY:-}" ] && body="$GS_403_BODY"
          code=500
        elif [ -f "$S/layers/$ws/$name.style" ]; then
          rm -f "$S/layers/$ws/$name.style"
          code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*"/datastores/"*".json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url#*/datastores/}"; ds="${ds%.json}"
    if [ -f "$S/ds/$ws/$ds.json" ]; then
      body="$(cat "$S/ds/$ws/$ds.json")"
      if [ "${GS_DS_BAD_PARAM:-0}" = "1" ]; then
        body="$(printf '%s' "$body" | jq -c '.dataStore.connectionParameters.entry |= map(if ."@key"=="user" then {"@key":"user","$":"WRONG"} else . end)' 2>/dev/null)"
      fi
      code=200
    else code=404; fi ;;
  *"/rest/workspaces/"*"/datastores")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    case "$method" in
      POST)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          ds="$(jq -r '.dataStore.name // empty' "$body_file" 2>/dev/null)"
          if [ -n "$ds" ]; then
            mkdir -p "$S/ds/$ws"
            cp "$body_file" "$S/ds/$ws/$ds.json"
            grep -qx "$ds" "$S/ds/$ws.list" 2>/dev/null || printf '%s\n' "$ds" >> "$S/ds/$ws.list"
            code=201
          else code=500; fi
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*"/datastores/"*)
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    ds="${url##*/datastores/}"
    case "$method" in
      PUT)
        if [ -n "$body_file" ] && [ -f "$body_file" ] && [ -f "$S/ds/$ws/$ds.json" ]; then
          cp "$body_file" "$S/ds/$ws/$ds.json"
          code=200
        else code=404; fi ;;
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then
          [ -n "${GS_403_BODY:-}" ] && body="$GS_403_BODY"
          code=500
        elif [ "${GS_DS_NONEMPTY:-0}" = "1" ] && [ -f "$S/ds/$ws/$ds.json" ]; then
          [ -n "${GS_403_BODY:-}" ] && body="$GS_403_BODY"
          code=403
        elif [ -f "$S/ds/$ws/$ds.json" ]; then
          rm -f "$S/ds/$ws/$ds.json"
          grep -vx "$ds" "$S/ds/$ws.list" > "$S/ds/$ws.list.tmp" 2>/dev/null || true
          mv "$S/ds/$ws.list.tmp" "$S/ds/$ws.list"
          code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/namespaces/"*".json")
    ws="${url##*/rest/namespaces/}"; ws="${ws%.json}"
    if [ -f "$S/namespaces/$ws.uri" ]; then
      u="$(cat "$S/namespaces/$ws.uri")"
      [ "${GS_WS_VERIFY_BAD:-0}" = "1" ] && u="${u}BAD"
      body="$(jq -nc --arg p "$ws" --arg u "$u" '{namespace:{prefix:$p,uri:$u}}')"
    else code=404; fi ;;
  *"/rest/workspaces/"*"/settings.json")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    if ! has_ws "$ws"; then code=404
    elif [ -f "$S/settings/$ws.json" ]; then body="$(cat "$S/settings/$ws.json")"; code=200
    else body='{"settings":{"contact":{"id":"contact"},"charset":"UTF-8","numDecimals":4,"verbose":false,"verboseExceptions":false,"localWorkspaceIncludesPrefix":false,"showCreatedTimeColumnsInAdminList":false,"showModifiedTimeColumnsInAdminList":false}}'; code=200; fi ;;
  *"/rest/workspaces/"*"/settings")
    ws="${url#*/rest/workspaces/}"; ws="${ws%%/*}"
    case "$method" in
      PUT)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          mkdir -p "$S/settings"
          if [ -n "${GS_SETTINGS_PUT_DROPS_KEY:-}" ]; then
            jq --arg k "$GS_SETTINGS_PUT_DROPS_KEY" '.settings |= del(.[$k])' "$body_file" > "$S/settings/$ws.json" 2>/dev/null
          else
            cp "$body_file" "$S/settings/$ws.json"
          fi
          code=200
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/services/"*"/workspaces/"*"/settings.json")
    svc="${url#*/rest/services/}"; svc="${svc%%/*}"
    ws="${url#*/workspaces/}"; ws="${ws%%/*}"
    if [ -f "$S/service/$ws/$svc.json" ]; then body="$(cat "$S/service/$ws/$svc.json")"; code=200
    else code=404; fi ;;
  *"/rest/services/"*"/settings.json")
    svc="${url#*/rest/services/}"; svc="${svc%%/*}"
    SVC="$(printf '%s' "$svc" | tr 'a-z' 'A-Z')"
    body="$(jq -nc --arg s "$svc" --arg n "$SVC" '{($s):{name:$n,enabled:true,id:null,title:null}}')"
    code=200 ;;
  *"/rest/services/"*"/workspaces/"*"/settings")
    svc="${url#*/rest/services/}"; svc="${svc%%/*}"
    ws="${url#*/workspaces/}"; ws="${ws%%/*}"
    case "$method" in
      PUT)
        if [ -n "${GS_SERVICE_CREATE_FAIL:-}" ] && [ ! -f "$S/service/$ws/$svc.json" ]; then
          body='Anlegen abgelehnt (Stub)'; code="$GS_SERVICE_CREATE_FAIL"   # nichts speichern
        else
          # Stub ist strenger als der echte GeoServer (L4): ohne name wird NICHTS gespeichert.
          nm="$(jq -r --arg s "$svc" '.[$s].name // empty' "$body_file" 2>/dev/null)"
          if [ -z "$nm" ]; then
            body='Cannot invoke String.equals(Object) because name is null'; code=500
          else
            mkdir -p "$S/service/$ws"
            jq --arg s "$svc" '.[$s].enabled //= false' "$body_file" > "$S/service/$ws/$svc.json" 2>/dev/null
            code=200
          fi
        fi ;;
      POST)
        code=405 ;;
      DELETE)
        if [ -f "$S/service/$ws/$svc.json" ]; then rm -f "$S/service/$ws/$svc.json"; code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*".json")
    ws="${url##*/rest/workspaces/}"; ws="${ws%.json}"
    has_ws "$ws" && body="{\"workspace\":{\"name\":\"$ws\"}}" || code=404 ;;
  *"/rest/namespaces")
    case "$method" in
      POST)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          p="$(jq -r '.namespace.prefix // empty' "$body_file" 2>/dev/null)"
          u="$(jq -r '.namespace.uri // empty' "$body_file" 2>/dev/null)"
          if [ -n "$p" ]; then
            mkdir -p "$S/namespaces"
            printf '%s\n' "$p" >> "$S/workspaces.list"
            printf '%s' "$u" > "$S/namespaces/$p.uri"
            code=201
          else code=500; fi
        else code=500; fi ;;
      *) code=500 ;;
    esac ;;
  *"/rest/workspaces/"*)
    ws="${url##*/rest/workspaces/}"
    case "$method" in
      DELETE)
        if [ "${GS_DELETE_FAIL:-0}" = "1" ]; then code=500
        elif [ "${GS_WS_DELETE_404:-0}" = "1" ]; then
          grep -vx "$ws" "$S/workspaces.list" > "$S/workspaces.list.tmp" 2>/dev/null || true
          mv "$S/workspaces.list.tmp" "$S/workspaces.list"
          rm -f "$S/namespaces/$ws.uri"
          code=404
        elif [ "${GS_WS_NONEMPTY:-0}" = "1" ] && has_ws "$ws"; then
          [ -n "${GS_403_BODY:-}" ] && body="$GS_403_BODY"
          code=403
        elif has_ws "$ws"; then
          grep -vx "$ws" "$S/workspaces.list" > "$S/workspaces.list.tmp" 2>/dev/null || true
          mv "$S/workspaces.list.tmp" "$S/workspaces.list"
          rm -f "$S/namespaces/$ws.uri"
          code=200
        else code=404; fi ;;
      *) code=500 ;;
    esac ;;
  *"/styles/polygon.json")
    [ "${GS_STYLE_POLYGON_MISSING:-0}" = "1" ] && code=404 || code=200 ;;
  *"/styles/generic.json")
    [ "${GS_STYLE_GENERIC_MISSING:-0}" = "1" ] && code=404 || code=200 ;;
  *"GetFeature"*"outputFormat=application/json"*)
    if [ "${GS_GEOJSON_EMPTY:-0}" = "1" ]; then
      body='{"type":"FeatureCollection","features":[]}'; code=200
    else
      u="${url#*/geoserver/}"; ws="${u%%/*}"
      dec=4
      [ -f "$S/settings/$ws.json" ] && dec="$(jq -r '.settings.numDecimals // 4' "$S/settings/$ws.json" 2>/dev/null)"
      case "$dec" in ''|null) dec=4 ;; esac
      ftdec="$(find "$S/ft/$ws" -name 'geo-containers.json' -exec jq -r '.featureType.numDecimals // 0' {} \; 2>/dev/null | head -1)"
      if [ -n "$ftdec" ] && [ "$ftdec" -gt 0 ] 2>/dev/null; then dec="$ftdec"; fi
      if [ "${GS_IGNORE_SETTINGS:-0}" = "1" ]; then dec=4; fi
      x="$(LC_NUMERIC=C printf '%.*f' "$dec" 6.98874485)"
      y="$(LC_NUMERIC=C printf '%.*f' "$dec" 50.92184755)"
      if [ "${GS_GEOJSON_PROP_DECIMALS:-0}" = "1" ]; then
        body="{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[$x,$y]},\"properties\":{\"area\":1234.56789012}}]}"
      else
        body="{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[$x,$y]},\"properties\":{}}]}"
      fi
      code=200
    fi ;;
  *"GetCapabilities"*)
    if [ "${GS_WMS_FAIL:-0}" = "1" ]; then
      code=503
    else
      u="${url#*/geoserver/}"; ws="${u%%/*}"
      svc="${u#*/}"; svc="${svc%%\?*}"
      title=""
      [ -f "$S/service/$ws/$svc.json" ] && title="$(xml_esc "$(jq -r ".$svc.title // empty" "$S/service/$ws/$svc.json" 2>/dev/null)")"
      email=""
      [ -f "$S/settings/$ws.json" ] && email="$(jq -r '.settings.contact.contactEmail // empty' "$S/settings/$ws.json" 2>/dev/null)"
      if [ "${GS_CAPS_NO_TITLE:-0}" = "1" ]; then title=""; fi

      nm=""; en="true"
      if [ -f "$S/service/$ws/$svc.json" ]; then
        nm="$(jq -r ".$svc.name // empty" "$S/service/$ws/$svc.json" 2>/dev/null)"
        en="$(jq -r ".$svc.enabled // empty" "$S/service/$ws/$svc.json" 2>/dev/null)"
      fi
      if [ "${GS_CAPS_EXCEPTION:-0}" = "1" ] || { [ -f "$S/service/$ws/$svc.json" ] && { [ -z "$nm" ] || [ "$en" != "true" ]; }; }; then
        body='<ows:ExceptionReport xmlns:ows="http://www.opengis.net/ows"><ows:Exception><ows:ExceptionText>java.lang.NullPointerException: ServiceInfo.getName() is null</ows:ExceptionText></ows:Exception></ows:ExceptionReport>'
        code=200
      else
        root='WMS_Capabilities'; close='WMS_Capabilities'
        [ "$svc" = "wfs" ] && { root='wfs:WFS_Capabilities'; close='wfs:WFS_Capabilities'; }
        layers=""
        for ft in "$S"/ft/"$ws"/*/*.json; do
          [ -f "$ft" ] || continue
          name="$(basename "$ft" .json)"
          ft_title="$(xml_esc "$(jq -r '.featureType.title // empty' "$ft" 2>/dev/null)")"
          abstract="$(xml_esc "$(jq -r '.featureType.abstract // empty' "$ft" 2>/dev/null)")"
          [ "${GS_CAPS_NO_ABSTRACT:-0}" = "1" ] && abstract=""
          layers="${layers}<Layer><Name>${ws}:${name}</Name><Title>${ft_title}</Title><Abstract>${abstract}</Abstract></Layer>"
        done
        body="<${root}><Service><Title>${title}</Title><ContactInformation><ElectronicMailAddress>${email}</ElectronicMailAddress></ContactInformation></Service>${layers}</${close}>"
        code=200
      fi
    fi ;;
  *"DescribeFeatureType"*)
    if [ "${GS_WFS_EXCEPTION:-0}" = "1" ]; then body='<ExceptionReport><Exception>error</Exception></ExceptionReport>'
    else body='<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema"/>'; fi
    code=200 ;;
  *"GetFeature"*)
    if [ "${GS_WFS_EXCEPTION:-0}" = "1" ]; then body='<ExceptionReport><Exception>error</Exception></ExceptionReport>'
    else body='<wfs:FeatureCollection numberMatched="1"/>'; fi
    code=200 ;;
  *"/wms"*|*"/wfs"*)
    ws="${url#*/geoserver/}"; ws="${ws%%/*}"
    if [ "${GS_WMS_FAIL:-0}" = "1" ]; then code=503
    else has_ws "$ws" && code=200 || code=404; fi ;;
  *) code=500 ;;
esac

# Ausgabe je nach -o/-w: Body in die -o-Datei (falls nicht /dev/null), Code bei -w.
if [ -n "$out_file" ] && [ "$out_file" != "/dev/null" ]; then
  printf '%s' "$body" > "$out_file"
fi
if [ "$has_w" = "1" ]; then printf '%s' "$code"; else printf '%s' "$body"; fi
exit 0
STUB
chmod +x "$STUBS/curl"

# ── kubectl-Stub (zustandsbehafteter Secret-Store) ─────────────────────────────
cat > "$STUBS/kubectl" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${KUBECTL_LOG:?}"

S="${KUBE_STATE_DIR:?}"
mkdir -p "$S/secrets"

args=("$@")
name=""
o_val=""
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    secret) name="${args[$((i+1))]}" ;;
    -o) o_val="${args[$((i+1))]}" ;;
  esac
  i=$((i+1))
done

# get namespace
case "$*" in
  *"get namespace"*) [ "${KUBECTL_NO_NS:-0}" = "1" ] && exit 1; exit 0 ;;
esac

# Admin-Secret geoserver-geoserver
if [ "$name" = "geoserver-geoserver" ]; then
  case "$o_val" in
    jsonpath=*.data.geoserver-user*) printf '%s' "${GS_ADMIN_B64_USER:-YWRtaW4=}" ;;
    jsonpath=*.data.geoserver-password*) printf '%s' "${GS_ADMIN_B64_PW:-YWRtaW5wdw==}" ;;
  esac
  exit 0
fi

# _secret_get: get secret <name> -o jsonpath={.data.password}
case "$o_val" in
  jsonpath=*.data.password*)
    if [ -f "$S/secrets/$name.b64" ]; then cat "$S/secrets/$name.b64"; exit 0; fi
    exit 1 ;;
  jsonpath=*.data.DB_PASSWORD*)
    if [ -f "$S/secrets/$name.dbpw" ]; then cat "$S/secrets/$name.dbpw"; exit 0; fi
    exit 1 ;;
esac

# _secret_apply Existenz-Check: get secret <name> -o json
if [ "$o_val" = "json" ]; then
  if [ -f "$S/secrets/$name.b64" ]; then
    b64="$(cat "$S/secrets/$name.b64")"
    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"cc-prd-geodata-stack"},"type":"Opaque","data":{"password":"%s"}}\n' "$name" "$b64"
    exit 0
  fi
  exit 1
fi

# get secret <name> (plain) — Uninstall-Verifikation
case "$*" in
  *"get secret"*)
    [ -f "$S/secrets/$name.b64" ] && exit 0 || exit 1 ;;
esac

# apply -f <manifest> — Secret speichern
case "$*" in
  *"apply"*)
    if [ "${KUBECTL_APPLY_FAIL:-0}" = "1" ]; then
      echo "Error from server (Forbidden)" >&2
      exit 1
    fi
    manifest=""
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
      if [ "${args[$i]}" = "-f" ]; then manifest="${args[$((i+1))]}"; break; fi
      i=$((i+1))
    done
    if [ -n "$manifest" ] && [ -f "$manifest" ]; then
      nm="$(jq -r '.metadata.name // empty' "$manifest" 2>/dev/null)"
      b64="$(jq -r '.data.password // empty' "$manifest" 2>/dev/null)"
      [ -n "$nm" ] && [ -n "$b64" ] && printf '%s' "$b64" > "$S/secrets/$nm.b64"
    fi
    exit 0 ;;
esac

# delete secret <name>
case "$*" in
  *"delete secret"*)
    rm -f "$S/secrets/$name.b64"
    exit 0 ;;
esac

exit 0
STUB
chmod +x "$STUBS/kubectl"

# ── jq-Wrapper (zeichnet Argumente auf, delegiert an das echte jq) ─────────────────
# Nur bei JQ_LOG_ARGS=1 aktiv (Szenario 51 prüft den Argumentverlauf).
cat > "$STUBS/jq" <<'STUB'
#!/usr/bin/env bash
if [ "${JQ_LOG_ARGS:-0}" = "1" ]; then
  printf '%s\n' "$*" >> "${JQ_LOG:?}"
fi
exec /usr/bin/jq "$@"
STUB
chmod +x "$STUBS/jq"

# ── yq-Stub: emuliert mikefarah `yq -o=json <filter>` (Ausgabe ist JSON) ───────
# -o=json ist hier ein No-op; der Filter wird an das echte yq (kislyuk/PyYAML)
# delegiert, das YAML von stdin nach JSON wandelt.
cat > "$STUBS/yq" <<'STUB'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  case "$a" in
    --version|-V)
      printf '%s\n' "${YQ_VERSION_OUT:-yq (https://github.com/mikefarah/yq) version v4.44.3}"
      exit 0 ;;
  esac
done
args=()
for a in "$@"; do
  case "$a" in
    -o=json|-ojson|--output-format=json) continue ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/yq "${args[@]:-.}"
STUB
chmod +x "$STUBS/yq"

# ── sleep-Stub: No-op, schreibt Aufrufe in SLEEP_LOG (Tests warten nicht) ─────
cat > "$STUBS/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SLEEP_LOG:?}"
exit 0
STUB
chmod +x "$STUBS/sleep"

# ── Helfer ─────────────────────────────────────────────────────────────────────
}

gs_group_end() {
  local rc=$?
  if [ "${_GS_ENDED:-0}" != "1" ]; then
    _GS_ENDED=1
    local wall
    wall="$(LC_ALL=C awk -v a="${GS_GROUP_T0:-0}" -v b="${EPOCHREALTIME:-0}" 'BEGIN{printf "%.3f", b-a}')"
    printf '%s\t%s\t%s\t%s\n' "${GS_GROUP_ID:-?}" "$wall" "${GS_SNAP_BUILD_S:-0}" "${GS_SCENARIO_COUNT:-0}" >> "${GS_GROUP_LOG:-/dev/null}"
  fi
  [ -n "${T:-}" ] && [ -d "$T" ] && rm -rf -- "$T"
  return "$rc"
}

clear_logs() { : > "$CURL_LOG"; : > "$CURL_BODY_LOG"; : > "$CURL_STDIN_LOG"; : > "$KUBECTL_LOG"; : > "$JQ_LOG"; }

# Stub-Schalter zurücksetzen (reset_state und restore_state).
unset_stub_switches() {
  unset GS_OFF GS_NEG200 GS_PREFLIGHT_FAIL GS_DELETE_FAIL GS_LAYER_DELETE_FAIL GS_USERS_500 GS_USERS_EMPTY GS_USERS_FAIL_ON GS_USERS_EMPTY_ON GS_ROLES_EMPTY_ON GS_WS_NONEMPTY GS_WS_DELETE_404 GS_WS_EMPTY_FORM GS_WS_VERIFY_BAD GS_DS_NONEMPTY GS_DS_BAD_PARAM GS_403_BODY GS_LIST_AVAILABLE_FAIL GS_LIST_AVAILABLE_FAIL_ON GS_LIST_AVAILABLE_MISSING_NATIVE GS_FT_LIST_FAIL GS_STYLE_POLYGON_MISSING GS_STYLE_GENERIC_MISSING GS_WFS_EXCEPTION GS_WMS_FAIL GS_DEFAULT_STYLE GS_ACL_GET_FAIL GS_ACL_POST_FAIL GS_ACL_DELETE_FAIL GS_SETTINGS_PUT_DROPS_KEY GS_SERVICE_CREATE_FAIL GS_CAPS_NO_TITLE GS_CAPS_EXCEPTION GS_CAPS_NO_ABSTRACT GS_GEOJSON_EMPTY GS_GEOJSON_PROP_DECIMALS GS_NOT_READY_FIRST GS_IGNORE_SETTINGS YQ_VERSION_OUT KUBECTL_NO_NS KUBECTL_APPLY_FAIL JQ_LOG_ARGS 2>/dev/null || true
}

reset_state() {
  rm -rf "$GS_STATE_DIR" "$KUBE_STATE_DIR"
  mkdir -p "$GS_STATE_DIR/userroles" "$GS_STATE_DIR/namespaces" "$GS_STATE_DIR/ds" "$GS_STATE_DIR/ft" "$GS_STATE_DIR/layers" "$KUBE_STATE_DIR/secrets"
  printf '%s\n' admin > "$GS_STATE_DIR/users.list"
  printf '%s\n' ADMIN > "$GS_STATE_DIR/roles.list"
  : > "$GS_STATE_DIR/workspaces.list"
  printf '{}' > "$GS_STATE_DIR/acl.map"
  for n in p2d2-main-secret p2d2-dev-secret p2d2-f-de1-secret p2d2-f-de2-secret p2d2-f-fv-secret; do
    seed_db_secret "$n" "$DB_PW_B64"
  done
  clear_logs
  unset_stub_switches
}

run_script() { run_script_in "$WORK" "$@"; }

run_script_in() {
  local dir="$1"; shift
  local t0 t1 rc dur
  t0="${EPOCHREALTIME:-0}"
  ( cd "$dir" && bash "$SCRIPT" "$@" >"$T/out.log" 2>"$T/err.log" )
  rc="$?"
  t1="${EPOCHREALTIME:-0}"
  dur="$(LC_ALL=C awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  printf '%s\t%s\t%s\n' "$dur" "${_GS_SCENARIO:-}" "$*" >> "${TIMING_LOG:-/dev/null}"
  printf '%s' "$rc"
}

count_lines()  { awk 'END{print NR}' "$1" 2>/dev/null || printf '0'; }
count_secrets(){ find "$KUBE_STATE_DIR/secrets" -maxdepth 1 -name '*.b64' -type f 2>/dev/null | awk 'END{print NR}'; }
latest_howto() { ls -t "$WORK"/p2d2-geoserver-config_v1_*.howto.md 2>/dev/null | head -1; }

seed_secret() { # <name> <b64>
  mkdir -p "$KUBE_STATE_DIR/secrets"
  printf '%s' "$2" > "$KUBE_STATE_DIR/secrets/$1.b64"
}

seed_db_secret() { # <name> <b64>  (Key DB_PASSWORD)
  mkdir -p "$KUBE_STATE_DIR/secrets"
  printf '%s' "$2" > "$KUBE_STATE_DIR/secrets/$1.dbpw"
}

seed_workspace() { # <ws> [uri]
  mkdir -p "$GS_STATE_DIR/namespaces"
  printf '%s\n' "$1" >> "$GS_STATE_DIR/workspaces.list"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$GS_STATE_DIR/namespaces/$1.uri"
}

# ── Schnellpfad-Helfer (GEOSERVER_ONLY/GEOSERVER_SCENARIOS) ─────────────────
want() { [ -z "${GEOSERVER_SCENARIOS:-}" ] || [[ " ${GEOSERVER_SCENARIOS} " == *" $1 "* ]]; }
_GS_SCENARIO=""
scenario() { _GS_SCENARIO="$1"; GS_SCENARIO_COUNT=$(( ${GS_SCENARIO_COUNT:-0} + 1 )); }
snapshot_state() { rm -rf "$T/snap"; mkdir -p "$T/snap"; cp -a "$GS_STATE_DIR" "$T/snap/gs"; cp -a "$KUBE_STATE_DIR" "$T/snap/kube"; }
restore_state()  { rm -rf "$GS_STATE_DIR" "$KUBE_STATE_DIR"; cp -a "$T/snap/gs" "$GS_STATE_DIR"; cp -a "$T/snap/kube" "$KUBE_STATE_DIR"; clear_logs; unset_stub_switches; [ "${GS_VERIFY_SNAP:-0}" = "1" ] && gs_verify_snapshot_equivalence; }
ensure_snap_installed() {
  [ -d "$T/snap" ] && return 0
  local t0 t1 d rc
  t0="${EPOCHREALTIME:-0}"
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  if [ "$rc" != "0" ]; then
    printf 'SETUP-FEHLER: Snapshot-Install fehlgeschlagen (Gruppe %s, Exit %s)\n' "${GS_GROUP_ID:-?}" "$rc" >&2
    [ -s "$T/err.log" ] && tail -n 20 "$T/err.log" >&2
    exit 1
  fi
  snapshot_state
  t1="${EPOCHREALTIME:-0}"
  d="$(LC_ALL=C awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  GS_SNAP_BUILD_S="$(LC_ALL=C awk -v a="${GS_SNAP_BUILD_S:-0}" -v b="$d" 'BEGIN{printf "%.3f", a+b}')"
}

# ── Snapshot-Äquivalenz (GS_VERIFY_SNAP=1, Aufgabe A) ─────────────────────
# normalize_state <GS_STATE_DIR> <KUBE_STATE_DIR> — deterministische Ausgabe.
# Secret-/Passwortwerte werden maskiert (Länge + Klasse), Listen sortiert, JSON kanonisiert.
normalize_state() {
  normalize_dir "$1" "gs"
  normalize_dir "$2" "kube"
}

normalize_dir() {
  local d="$1" label="$2" f
  [ -d "$d" ] || return 0
  ( cd "$d" && find . -type f -print 2>/dev/null | LC_ALL=C sort ) | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '== %s/%s ==\n' "$label" "$f"
    normalize_file "$d/$f"
    printf '\n'
  done
}

normalize_file() {
  local f="$1" n
  case "$f" in
    *.b64|*.dbpw)
      n="$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')"
      printf '<MASK len=%s class=base64>\n' "${n:-0}"
      ;;
    *.list)
      LC_ALL=C sort "$f" 2>/dev/null
      ;;
    *.json|*/acl.map)
      jq -S . "$f" 2>/dev/null || cat "$f" 2>/dev/null
      ;;
    *)
      cat "$f" 2>/dev/null
      ;;
  esac
}

gs_verify_snapshot_equivalence() {
  local vdir="$T/verify"
  local vgs="$vdir/gs" vkube="$vdir/kube" vwork="$vdir/work"
  local s_gs="$GS_STATE_DIR" s_kube="$KUBE_STATE_DIR"
  local s_curl="$CURL_LOG" s_curlb="$CURL_BODY_LOG" s_stdin="$CURL_STDIN_LOG" s_kctl="$KUBECTL_LOG" s_jq="$JQ_LOG"
  local rc a b
  rm -rf "$vdir"; mkdir -p "$vgs" "$vkube" "$vwork"

  # Stubs auf isolierte Verify-State-Dirs und -Logs umlenken.
  export GS_STATE_DIR="$vgs" KUBE_STATE_DIR="$vkube"
  export CURL_LOG="$vdir/curl.log" CURL_BODY_LOG="$vdir/curl-body.log" CURL_STDIN_LOG="$vdir/curl-stdin.log" KUBECTL_LOG="$vdir/kubectl.log" JQ_LOG="$vdir/jq.log"

  reset_state
  ( cd "$vwork" && bash "$SCRIPT" --url "$URL" --ns "$NS" > "$vdir/out.log" 2> "$vdir/err.log" )
  rc="$?"

  export GS_STATE_DIR="$s_gs" KUBE_STATE_DIR="$s_kube"
  export CURL_LOG="$s_curl" CURL_BODY_LOG="$s_curlb" CURL_STDIN_LOG="$s_stdin" KUBECTL_LOG="$s_kctl" JQ_LOG="$s_jq"

  [ "$rc" = "0" ] || { echo "VERIFY-FEHLER: Snapshot-Äquivalenz-Install Exit $rc" >&2; return 1; }

  a="$vdir/fresh.norm"; b="$vdir/restored.norm"
  normalize_state "$vgs" "$vkube" > "$a"
  normalize_state "$s_gs" "$s_kube" > "$b"
  if ! diff -u "$b" "$a" > "$vdir/equiv.diff"; then
    echo "SNAPSHOT-ABWEICHUNG (diff: $vdir/equiv.diff)" >&2
    return 1
  fi
  return 0
}
# Bundle-Kopie (Einstieg + geoserver-config/ + Metadaten) für Mutationstests (z. B. TODO).
bundle_copy() { local d="$1"; mkdir -p "$d"; cp "$REPO/supplement/p2d2-geoserver-config_v1.sh" "$d/"; cp -r "$REPO/supplement/geoserver-config" "$d/"; cp "$REPO/supplement/geoserver-metadata.md" "$d/"; }
run_bundle() { local d="$1"; shift; ( cd "$WORK" && bash "$d/p2d2-geoserver-config_v1.sh" "$@" >"$T/out.log" 2>"$T/err.log" ); printf '%s' "$?"; }


NS="cc-prd-geodata-stack"
URL="https://geo.example/geoserver"
PASS_VALID="abcdefghijklmnop123456"
PASS_VALID_B64="YWJjZGVmZ2hpamtsbW5vcDEyMzQ1Ng=="
PASS_INVALID_B64="a3Vyeg=="   # base64("kurz")

# ═══════════════════════════════════════════════════════════════════════════
# Alte Szenarien 1–84 (Bestand). Nur eingehüllt, Inhalt unverändert.
# ═══════════════════════════════════════════════════════════════════════════

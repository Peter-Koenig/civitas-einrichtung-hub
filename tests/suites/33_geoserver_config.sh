#!/usr/bin/env bash
# Suite 33: GeoServer-Konfiguration Schritt 1 (WFS-T-/WFS-Benutzer, Rollen, Secrets).
# Testet p2d2-geoserver-config_v1.sh gegen stateful curl-/kubectl-Stubs.
# Nur Stubs, kein Cluster/Netz, keine echten Secrets.
#
# Optionale Überschreibung für Regression-Nachweise (Wegwerf-Worktree):
#   GEOSERVER_CONFIG_SCRIPT=<pfad> ./tests/run.sh

begin_suite "geoserver_config"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${GEOSERVER_CONFIG_SCRIPT:-$REPO/supplement/p2d2-geoserver-config_v1.sh}"

T="$(mktemp -d)"
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
    if [ -f "$S/settings/$ws.json" ]; then body="$(cat "$S/settings/$ws.json")"
    else body='{"settings":{"contact":{"id":"contact"},"charset":"UTF-8","numDecimals":4,"verbose":false,"verboseExceptions":false,"localWorkspaceIncludesPrefix":false,"showCreatedTimeColumnsInAdminList":false,"showModifiedTimeColumnsInAdminList":false}}'; fi
    code=200 ;;
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
  *"/rest/services/"*"/workspaces/"*"/settings")
    svc="${url#*/rest/services/}"; svc="${svc%%/*}"
    ws="${url#*/workspaces/}"; ws="${ws%%/*}"
    case "$method" in
      PUT)
        if [ "${GS_SERVICE_PUT_405:-0}" = "1" ] && [ ! -f "$S/service/$ws/$svc.json" ]; then code=405
        elif [ -n "$body_file" ] && [ -f "$body_file" ]; then
          mkdir -p "$S/service/$ws"; cp "$body_file" "$S/service/$ws/$svc.json"; code=200
        else code=500; fi ;;
      POST)
        if [ -n "$body_file" ] && [ -f "$body_file" ]; then
          mkdir -p "$S/service/$ws"; cp "$body_file" "$S/service/$ws/$svc.json"; code=201
        else code=500; fi ;;
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
    u="${url#*/geoserver/}"; ws="${u%%/*}"
    dec=4
    [ -f "$S/settings/$ws.json" ] && dec="$(jq -r '.settings.numDecimals // 4' "$S/settings/$ws.json" 2>/dev/null)"
    case "$dec" in ''|null) dec=4 ;; esac
    ftdec="$(find "$S/ft/$ws" -name 'geo-containers.json' -exec jq -r '.featureType.numDecimals // 0' {} \; 2>/dev/null | head -1)"
    if [ -n "$ftdec" ] && [ "$ftdec" -gt 0 ] 2>/dev/null; then dec="$ftdec"; fi
    if [ "${GS_IGNORE_SETTINGS:-0}" = "1" ]; then dec=4; fi
    x="$(LC_NUMERIC=C printf '%.*f' "$dec" 6.98874485)"
    y="$(LC_NUMERIC=C printf '%.*f' "$dec" 50.92184755)"
    body="{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[$x,$y]},\"properties\":{}}]}"
    code=200 ;;
  *"GetCapabilities"*)
    if [ "${GS_WMS_FAIL:-0}" = "1" ]; then
      code=503
    else
      u="${url#*/geoserver/}"; ws="${u%%/*}"
      svc="${u#*/}"; svc="${svc%%\?*}"
      title=""
      [ -f "$S/service/$ws/$svc.json" ] && title="$(jq -r ".$svc.title // empty" "$S/service/$ws/$svc.json" 2>/dev/null)"
      email=""
      [ -f "$S/settings/$ws.json" ] && email="$(jq -r '.settings.contact.contactEmail // empty' "$S/settings/$ws.json" 2>/dev/null)"
      if [ "${GS_CAPS_NO_TITLE:-0}" = "1" ]; then title=""; fi
      body="<Capabilities><Service><Title>${title}</Title><ContactInformation><ElectronicMailAddress>${email}</ElectronicMailAddress></ContactInformation></Service></Capabilities>"
      code=200
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

# ── Helfer ─────────────────────────────────────────────────────────────────────
clear_logs() { : > "$CURL_LOG"; : > "$CURL_BODY_LOG"; : > "$CURL_STDIN_LOG"; : > "$KUBECTL_LOG"; : > "$JQ_LOG"; }

# Stub-Schalter zurücksetzen (reset_state und restore_state).
unset_stub_switches() {
  unset GS_OFF GS_NEG200 GS_PREFLIGHT_FAIL GS_DELETE_FAIL GS_LAYER_DELETE_FAIL GS_USERS_500 GS_USERS_EMPTY GS_USERS_FAIL_ON GS_USERS_EMPTY_ON GS_ROLES_EMPTY_ON GS_WS_NONEMPTY GS_WS_DELETE_404 GS_WS_EMPTY_FORM GS_WS_VERIFY_BAD GS_DS_NONEMPTY GS_DS_BAD_PARAM GS_403_BODY GS_LIST_AVAILABLE_FAIL GS_LIST_AVAILABLE_FAIL_ON GS_LIST_AVAILABLE_MISSING_NATIVE GS_FT_LIST_FAIL GS_STYLE_POLYGON_MISSING GS_STYLE_GENERIC_MISSING GS_WFS_EXCEPTION GS_WMS_FAIL GS_DEFAULT_STYLE GS_ACL_GET_FAIL GS_ACL_POST_FAIL GS_ACL_DELETE_FAIL GS_SETTINGS_PUT_DROPS_KEY GS_SERVICE_PUT_405 GS_CAPS_NO_TITLE GS_IGNORE_SETTINGS KUBECTL_NO_NS KUBECTL_APPLY_FAIL JQ_LOG_ARGS 2>/dev/null || true
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
  printf '%s\t%s\n' "$dur" "$*" >> "${TIMING_LOG:-/dev/null}"
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
snapshot_state() { rm -rf "$T/snap"; mkdir -p "$T/snap"; cp -a "$GS_STATE_DIR" "$T/snap/gs"; cp -a "$KUBE_STATE_DIR" "$T/snap/kube"; }
restore_state()  { rm -rf "$GS_STATE_DIR" "$KUBE_STATE_DIR"; cp -a "$T/snap/gs" "$GS_STATE_DIR"; cp -a "$T/snap/kube" "$KUBE_STATE_DIR"; clear_logs; unset_stub_switches; }
ensure_snap_installed() { [ -d "$T/snap" ] || { reset_state; rc="$(run_script --url "$URL" --ns "$NS")"; check "Snapshot-Install Exit 0" "0" "$rc"; snapshot_state; }; }
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
scenarios_legacy() {

# ═══════════════════════════════════════════════════════════════════════════
# (1) Erstlauf legt sechs Secrets + sechs Benutzer an
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "Erstlauf Exit 0"          "0" "$rc"
check "Erstlauf 6 Secrets"       "6" "$(count_secrets)"
check "Erstlauf 7 Benutzer (admin + 6)" "7" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Erstlauf 8 Rollen (ADMIN + 7)"   "8" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Erstlauf 6 Secret-Applys" "6" "$(grep -c 'apply' "$KUBECTL_LOG")"

# ═══════════════════════════════════════════════════════════════════════════════
# (2) Zweiter Lauf idempotent (kein neues Secret, kein Apply, nichts doppelt)
# ═══════════════════════════════════════════════════════════════════════════════
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "Zweitlauf Exit 0"            "0" "$rc"
check "Zweitlauf weiterhin 6 Secrets" "6" "$(count_secrets)"
check "Zweitlauf weiterhin 7 Benutzer" "7" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Zweitlauf weiterhin 8 Rollen"   "8" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Zweitlauf kein Secret-Apply" "0" "$(grep -c 'apply' "$KUBECTL_LOG")"

# ═══════════════════════════════════════════════════════════════════════════════
# (3) Vorhandener gültiger Secret-Wert wird wiederverwendet; kein Passwort in Args
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
for n in p2d2-geoserver-wfst-main p2d2-geoserver-wfst-develop p2d2-geoserver-wfst-de1 \
         p2d2-geoserver-wfst-de2 p2d2-geoserver-wfst-fv p2d2-geoserver-wfs-user; do
  seed_secret "$n" "$PASS_VALID_B64"
done
rc="$(run_script --url "$URL" --ns "$NS")"
check "Reuse Exit 0"            "0" "$rc"
check "Reuse kein Apply"        "0" "$(grep -c 'apply' "$KUBECTL_LOG")"
check "Reuse MAIN-Wert bleibt"  "$PASS_VALID_B64" "$(cat "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64")"
check "Reuse kein Passwort in curl-Args"   "0" "$(grep -c "$PASS_VALID" "$CURL_LOG")"
check "Reuse kein base64 in curl-Args"     "0" "$(grep -c "$PASS_VALID_B64" "$CURL_LOG")"
check "Reuse kein Passwort in kubectl-Args" "0" "$(grep -c "$PASS_VALID" "$KUBECTL_LOG")"
check "Reuse kein base64 in kubectl-Args"   "0" "$(grep -c "$PASS_VALID_B64" "$KUBECTL_LOG")"

# ═══════════════════════════════════════════════════════════════════════════════
# (4) Ungültiger Secret-Wert wird ersetzt
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
seed_secret "p2d2-geoserver-wfst-main" "$PASS_INVALID_B64"
rc="$(run_script --url "$URL" --ns "$NS")"
check "Invalid-Ersetzen Exit 0" "0" "$rc"
check "Invalid ersetzt (nicht a3Vyeg==)" "0" "$(grep -c '^a3Vyeg==$' "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64" 2>/dev/null || true)"
newlen="$(base64 -d < "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-main.b64" 2>/dev/null | awk '{print length}')"
check "Invalid neuer Wert >= 16 Zeichen" "0" "$( [ "$newlen" -ge 16 ] 2>/dev/null && echo 0 || echo 1 )"

# ═══════════════════════════════════════════════════════════════════════════════
# (5) Legacy-Variablen: nur Namen melden, nie Werte
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
export P2D2_MAIN_WFST_PASSWORD="secretvalue-a"
export WFST_PW_FOO="secretvalue-b"
export WFS_RO_PW="secretvalue-c"
export WFS_PW="secretvalue-d"
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "Legacy WARN P2D2_MAIN_WFST_PASSWORD" "yes" "$(grep -q 'P2D2_MAIN_WFST_PASSWORD' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFST_PW_FOO"            "yes" "$(grep -q 'WFST_PW_FOO' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFS_RO_PW"              "yes" "$(grep -q 'WFS_RO_PW' "$T/err.log" && echo yes || echo no)"
check "Legacy WARN WFS_PW"                 "yes" "$(grep -q 'WFS_PW ' "$T/err.log" && echo yes || echo no)"
check "Legacy kein Wert secretvalue-a"     "0" "$(grep -c 'secretvalue-a' "$T/err.log")"
check "Legacy kein Wert secretvalue-b"     "0" "$(grep -c 'secretvalue-b' "$T/err.log")"
check "Legacy kein Wert secretvalue-c"     "0" "$(grep -c 'secretvalue-c' "$T/err.log")"
check "Legacy kein Wert secretvalue-d"     "0" "$(grep -c 'secretvalue-d' "$T/err.log")"
unset P2D2_MAIN_WFST_PASSWORD WFST_PW_FOO WFS_RO_PW WFS_PW

# ═══════════════════════════════════════════════════════════════════════════════
# (6) --dry-run: kein POST/PUT/DELETE und kein kubectl apply
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "Dry-Run Exit 0"          "0" "$rc"
check "Dry-Run kein POST"       "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
check "Dry-Run kein DELETE"     "0" "$(grep -c '\-X DELETE' "$CURL_LOG" || true)"
check "Dry-Run kein kubectl apply" "0" "$(grep -c 'apply' "$KUBECTL_LOG" || true)"
check "Dry-Run keine Secrets angelegt" "0" "$(count_secrets)"

# ═══════════════════════════════════════════════════════════════════════════════
# (7) --uninstall entfernt nur exakt benannte Objekte
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
# Fremde Objekte hinzufügen (nie anzufassen). admin/ADMIN sind bereits als Baseline gesetzt.
printf '%s\n' ROLE_X >> "$GS_STATE_DIR/roles.list"
seed_secret "unrelated-secret" "YWJjZA=="
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Uninstall Exit 0"              "0" "$rc"
check "Uninstall nur admin übrig"     "admin" "$(cat "$GS_STATE_DIR/users.list")"
check "Uninstall ADMIN bleibt"         "yes" "$(grep -q '^ADMIN$' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "Uninstall ROLE_X bleibt"        "yes" "$(grep -q '^ROLE_X$' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "Uninstall 2 Rollen übrig"       "2" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Uninstall Fremd-Secret bleibt" "1" "$(count_secrets)"

# ═══════════════════════════════════════════════════════════════════════════════
# (8) GeoServer-Teilfehler beim Uninstall lässt Secrets stehen
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_DELETE_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Uninstall Teilfehler Exit 1"       "1" "$rc"
check "Uninstall Teilfehler Secrets bleiben" "6" "$(count_secrets)"
unset GS_DELETE_FAIL

# ═══════════════════════════════════════════════════════════════════════════════
# (9) Unbekanntes Argument -> Exit 2; --url gewinnt über ADDON_DOMAIN
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --bogus)"
check "Unbekanntes Argument Exit 2" "2" "$rc"

reset_state
export ADDON_DOMAIN="udp.wrong.example"
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "--url gewinnt Exit 0" "0" "$rc"
check "--url gewinnt (kein udp.wrong)" "0" "$(grep -c 'udp.wrong.example' "$T/out.log" || true)"
unset ADDON_DOMAIN

# ═══════════════════════════════════════════════════════════════════════════════
# (10) Negativtest liefert 200 -> WARN
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
export GS_NEG200=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "Negativtest-200 Exit 0"  "0" "$rc"
check "Negativtest-200 WARN"    "yes" "$(grep -q 'Negativtest' "$T/err.log" && echo yes || echo no)"
unset GS_NEG200

# ═══════════════════════════════════════════════════════════════════════════════
# (11) Dry-Run Install/Uninstall: Exit 0, keine Verifikationsfehler (K1/K2)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "K1 Dry-Run-Install Exit 0"   "0" "$rc"
check "K1 Verifikation übersprungen" "0" "$(grep -c 'kein Passwort' "$T/err.log" || true)"

# K2: erst real anlegen, dann Dry-Run-Uninstall (Objekte bleiben, Verifikation übersprungen).
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --dry-run --uninstall --url "$URL" --ns "$NS")"
check "K2 Dry-Run-Uninstall Exit 0" "0" "$rc"
check "K2 Verifikation übersprungen" "0" "$(grep -c 'noch vorhanden' "$T/err.log" || true)"

# ═══════════════════════════════════════════════════════════════════════════════
# (12) Zweiter --uninstall auf leerem GeoServer -> Exit 0, kein DELETE (K3)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K3 leerer Uninstall Exit 0" "0" "$rc"
check "K3 leerer Uninstall kein DELETE" "0" "$(grep -c '\-X DELETE' "$CURL_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════════
# (13) Teilzustand (ein Benutzer fehlt, ein Secret fehlt) sauber aufgeräumt
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
grep -vx 'p2d2_wfst_de2' "$GS_STATE_DIR/users.list" > "$GS_STATE_DIR/users.list.tmp" 2>/dev/null || true
mv "$GS_STATE_DIR/users.list.tmp" "$GS_STATE_DIR/users.list"
rm -f "$KUBE_STATE_DIR/secrets/p2d2-geoserver-wfst-de2.b64"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "Teilzustand Uninstall Exit 0" "0" "$rc"
check "Teilzustand nur admin übrig" "1" "$(count_lines "$GS_STATE_DIR/users.list")"
check "Teilzustand nur ADMIN übrig"  "1" "$(count_lines "$GS_STATE_DIR/roles.list")"
check "Teilzustand keine Secrets übrig"  "0" "$(count_secrets)"

# ═══════════════════════════════════════════════════════════════════════════════
# (14) GS_BASE leer -> Exit 2 mit Hinweis (K4)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --ns "$NS")"
check "K4 GS_BASE leer Exit 2" "2" "$rc"
check "K4 GS_BASE leer Hinweis" "yes" "$(grep -q 'GS_BASE leer' "$T/err.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════════
# (15) .env.p2d2-addon zwei Ebenen höher wird gefunden (K4)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
ENV_TREE="$T/envtree/p2d2-addon/supplement"
mkdir -p "$ENV_TREE"
printf 'ADDON_DOMAIN=udp.envtest.example\n' > "$T/envtree/.env.p2d2-addon"
rc="$(run_script_in "$ENV_TREE" --dry-run --ns "$NS")"
check "K4 env 2 Ebenen Exit 0" "0" "$rc"
check "K4 env Domain gefunden" "yes" "$(grep -q 'udp.envtest.example' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════════
# (16) Modify-Body enthält <enabled>true</enabled> (K5)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
printf '%s\n' p2d2_wfst_main >> "$GS_STATE_DIR/users.list"
mkdir -p "$GS_STATE_DIR/userroles"
: > "$GS_STATE_DIR/userroles/p2d2_wfst_main.list"
rc="$(run_script --url "$URL" --ns "$NS")"
check "K5 Exit 0" "0" "$rc"
check "K5 <enabled>true</enabled>" "yes" "$(grep -q '<enabled>true</enabled>' "$CURL_BODY_LOG" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════════
# (17) _secret_apply schlägt fehl -> Exit 1, Meldung, kein User-POST (K7)
# ═══════════════════════════════════════════════════════════════════════════════
reset_state
export KUBECTL_APPLY_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K7 Exit 1"          "1" "$rc"
check "K7 klare Meldung"   "yes" "$(grep -q 'konnte nicht gespeichert werden' "$T/err.log" && echo yes || echo no)"
check "K7 kein User-POST"  "0" "$(grep -c 'security/usergroup/users$' "$CURL_LOG" || true)"
unset KUBECTL_APPLY_FAIL

# ═══════════════════════════════════════════════════════════════════════════════
# (18) --help/-h -> Exit 0, Hilfe auf stdout (K6)
# ═══════════════════════════════════════════════════════════════════════════════
rc="$(run_script --help)"
check "--help Exit 0" "0" "$rc"
check "--help Usage auf stdout" "yes" "$(grep -q 'Usage:' "$T/out.log" && echo yes || echo no)"
rc="$(run_script -h)"
check "-h Exit 0" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════
# (19) K8: users.json leer -> Plausibilität schlägt fehl -> Exit 2 (Install + Uninstall)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_USERS_EMPTY=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 users leer Install Exit 2" "2" "$rc"
check "K8 users leer kein POST" "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K8 users leer Uninstall Exit 2" "2" "$rc"
unset GS_USERS_EMPTY

# ═══════════════════════════════════════════════════════════════════════════
# (20) K8: users.json HTTP 500 -> Exit 2
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_USERS_500=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 users 500 Exit 2" "2" "$rc"
unset GS_USERS_500

# ═══════════════════════════════════════════════════════════════════════════
# (21) K8: Uninstall-Schlussverifikation Lesefehler -> Exit 1, keine Erfolgsmeldung
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_USERS_FAIL_ON=2
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "K8 Schlussverifikation Lesefehler Exit 1" "1" "$rc"
check "K8 Schlussverifikation keine Erfolgsmeldung" "0" "$(grep -c 'Uninstall verifiziert' "$T/out.log" || true)"
unset GS_USERS_FAIL_ON

# ═══════════════════════════════════════════════════════════════════════════
# (22) K8: anderer Admin-Name per GS_ADMIN_USER funktioniert
# ═══════════════════════════════════════════════════════════════════════════
reset_state
printf '%s\n' customadmin > "$GS_STATE_DIR/users.list"
export GS_ADMIN_USER=customadmin
rc="$(run_script --url "$URL" --ns "$NS")"
check "K8 customadmin Exit 0" "0" "$rc"
unset GS_ADMIN_USER

# ═══════════════════════════════════════════════════════════════════════════
# (23) How-To: enthält keinen Passwortwert
# ═══════════════════════════════════════════════════════════════════════════
reset_state
for n in p2d2-geoserver-wfst-main p2d2-geoserver-wfst-develop p2d2-geoserver-wfst-de1 \
         p2d2-geoserver-wfst-de2 p2d2-geoserver-wfst-fv p2d2-geoserver-wfs-user; do
  seed_secret "$n" "$PASS_VALID_B64"
done
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "How-To vorhanden"        "yes" "$([ -n "$howto_file" ] && echo yes || echo no)"
check "How-To kein Passwortwert" "0" "$(grep -c "$PASS_VALID" "$howto_file" 2>/dev/null || true)"
check "How-To kein base64"       "0" "$(grep -c "$PASS_VALID_B64" "$howto_file" 2>/dev/null || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (24) How-To: Struktur-Abschnitte, erhaltene Codes, Modus
# ═══════════════════════════════════════════════════════════════════════════
check "How-To Konventionen"      "yes" "$(grep -q '## Konventionen' "$howto_file" && echo yes || echo no)"
check "How-To Lesende Schritte"  "yes" "$(grep -q '## Lesende Schritte' "$howto_file" && echo yes || echo no)"
check "How-To Secret-Schritte"   "yes" "$(grep -q '## Secret-Schritte' "$howto_file" && echo yes || echo no)"
check "How-To Verifikation"      "yes" "$(grep -q '## Verifikation' "$howto_file" && echo yes || echo no)"
check "How-To Entscheidungslogik" "yes" "$(grep -q '## Entscheidungslogik' "$howto_file" && echo yes || echo no)"
check "How-To erhaltene Codes"   "yes" "$(grep -q 'erhalten 20' "$howto_file" && echo yes || echo no)"
check "How-To Modus ausgeführt"  "yes" "$(grep -q 'Modus: ausgeführt' "$howto_file" && echo yes || echo no)"
check "How-To Workspaces Abschnitt" "yes" "$(grep -q '## Workspaces' "$howto_file" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (25) How-To Dry-Run: Modus geplant
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --dry-run --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "How-To Dry-Run geplant" "yes" "$(grep -q 'Modus: dry-run (geplant)' "$howto_file" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (26) Workspaces: Erstlauf legt sechs Workspaces mit korrektem Payload an
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Erstlauf Exit 0"              "0" "$rc"
check "WS Erstlauf 6 Workspaces"        "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
check "WS main URI"                     "urn:data-dna:govdata:main" "$(cat "$GS_STATE_DIR/namespaces/main.uri")"
check "WS friedhofsplaene URI"          "urn:data-dna:tiffdata" "$(cat "$GS_STATE_DIR/namespaces/friedhofsplaene.uri")"
check "WS Payload prefix main"          "yes" "$(grep -q '"prefix":"main"' "$CURL_BODY_LOG" && echo yes || echo no)"
check "WS Payload uri main"             "yes" "$(grep -q '"uri":"urn:data-dna:govdata:main"' "$CURL_BODY_LOG" && echo yes || echo no)"
check "WS kein Passwort in curl-Args"    "0" "$(grep -c "$PASS_VALID" "$CURL_LOG" || true)"
check "WS kein Passwort in kubectl-Args" "0" "$(grep -c "$PASS_VALID" "$KUBECTL_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (27) Workspaces: Zweitlauf idempotent
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Zweitlauf Exit 0"               "0" "$rc"
check "WS Zweitlauf weiterhin 6"          "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
check "WS Zweitlauf kein namespaces POST" "0" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (28) Workspaces: Konflikt (abweichende URI) -> Exit 1, keine Änderung, Rest läuft
# ═══════════════════════════════════════════════════════════════════════════
reset_state
seed_workspace "main" "urn:data-dna:govdata:WRONG"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Konflikt Exit 1"               "1" "$rc"
check "WS Konflikt main URI unverändert" "urn:data-dna:govdata:WRONG" "$(cat "$GS_STATE_DIR/namespaces/main.uri")"
check "WS Konflikt 5 weitere angelegt"   "5" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (29) Workspaces: leere Liste als "" und als []
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_WS_EMPTY_FORM=str
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS leer (str) Exit 0"    "0" "$rc"
check "WS leer (str) 6 angelegt" "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
unset GS_WS_EMPTY_FORM
reset_state
export GS_WS_EMPTY_FORM=arr
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS leer (arr) Exit 0"    "0" "$rc"
check "WS leer (arr) 6 angelegt" "6" "$(count_lines "$GS_STATE_DIR/workspaces.list")"
unset GS_WS_EMPTY_FORM

# ═══════════════════════════════════════════════════════════════════════════
# (30) Workspaces: Workspace ohne Namespace -> Exit 1, übrige laufen weiter
# ═══════════════════════════════════════════════════════════════════════════
reset_state
seed_workspace "dev"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS ohne Namespace Exit 1"  "1" "$rc"
check "WS ohne Namespace Meldung" "yes" "$(grep -q 'Namespace nicht lesbar' "$T/err.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (31) Workspaces: Dry-run ohne POST
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "WS Dry-Run Exit 0"               "0" "$rc"
check "WS Dry-Run kein namespaces POST" "0" "$(grep -c 'rest/namespaces' "$CURL_BODY_LOG" || true)"
check "WS Dry-Run keine Workspaces"     "0" "$(count_lines "$GS_STATE_DIR/workspaces.list")"

# ═══════════════════════════════════════════════════════════════════════════
# (32) Workspaces: Uninstall löscht nur Soll, ohne recurse
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
seed_workspace "foreign_ws" "urn:data-dna:govdata:foreign"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS Uninstall Exit 0"          "0" "$rc"
check "WS Uninstall foreign bleibt"  "foreign_ws" "$(cat "$GS_STATE_DIR/workspaces.list")"
check "WS Uninstall ohne recurse"    "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (33) Workspaces: DELETE 404 gilt als schon weg
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_WS_DELETE_404=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS 404 Exit 0"    "0" "$rc"
check "WS 404 schon weg" "yes" "$(grep -q 'schon weg' "$T/out.log" && echo yes || echo no)"
unset GS_WS_DELETE_404

# ═══════════════════════════════════════════════════════════════════════════
# (34) Workspaces: nicht-leerer Workspace (403) -> Exit 1, Secrets bleiben
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_WS_NONEMPTY=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "WS nicht-leer Exit 1"          "1" "$rc"
check "WS nicht-leer Secrets bleiben" "6" "$(count_secrets)"
unset GS_WS_NONEMPTY

# ═══════════════════════════════════════════════════════════════════════════
# (35) Workspaces: aggregierter Verifikationsfehler -> Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_WS_VERIFY_BAD=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "WS Verifikation Fehler Exit 1" "1" "$rc"
check "WS Verifikation Meldung"       "yes" "$(grep -q 'weicht ab' "$T/err.log" && echo yes || echo no)"
unset GS_WS_VERIFY_BAD

# ═══════════════════════════════════════════════════════════════════════════
# (36) Workspaces: Startprüfung SOL/WS (tampered copy)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
sed 's/main|urn:data-dna:govdata:main//' "$SCRIPT" > "$T/script-ws-missing.sh"
# Vollständiges Bundle für die mutierte Einstiegskopie bereitstellen (Loader braucht geoserver-config/).
cp -r "$REPO/supplement/geoserver-config" "$T/geoserver-config"
rc="$( cd "$WORK" && bash "$T/script-ws-missing.sh" --url "$URL" --ns "$NS" >"$T/out.log" 2>"$T/err.log"; printf '%s' "$?" )"
check "WS Startprüfung Exit 2"  "2" "$rc"
check "WS Startprüfung Meldung" "yes" "$(grep -q 'fehlt in WS_TABLE' "$T/err.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (37) A1: Uninstall-Schlussverifikation mit leerer Liste -> Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_USERS_EMPTY_ON=2
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "A1 Schlussverifikation Exit 1"         "1" "$rc"
check "A1 keine Uninstall-verifiziert-Zeile"  "0" "$(grep -c 'Uninstall verifiziert' "$T/out.log" || true)"
unset GS_USERS_EMPTY_ON

# ═══════════════════════════════════════════════════════════════════════════
# (38) A2: Credential-Escaping (Anführungszeichen + Backslash)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_ADMIN_PW='ab"cd\ef'
rc="$(run_script --url "$URL" --ns "$NS")"
check "A2 escape Exit 0"           "0" "$rc"
check "A2 escape in stdin-Konfig"  "yes" "$(grep -Fq 'ab\"cd\\ef' "$CURL_STDIN_LOG" && echo yes || echo no)"
unset GS_ADMIN_PW

# ═══════════════════════════════════════════════════════════════════════════
# (39) A2: Passwort mit Zeilenumbruch -> Exit 2
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_ADMIN_PW=$'secret\nline2'
rc="$(run_script --url "$URL" --ns "$NS")"
check "A2 newline Exit 2" "2" "$rc"
unset GS_ADMIN_PW

# ═══════════════════════════════════════════════════════════════════════════
# (40) A3: Lesefehler hinterlässt keine Temp-Datei
# ═══════════════════════════════════════════════════════════════════════════
reset_state
mkdir -p "$T/tmpdir"
export TMPDIR="$T/tmpdir"
export GS_USERS_500=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "A3 Lesefehler Exit 2"      "2" "$rc"
check "A3 keine Temp-Datei übrig" "0" "$(find "$T/tmpdir" -type f | awk 'END{print NR}')"
unset GS_USERS_500 TMPDIR

# ═══════════════════════════════════════════════════════════════════════════
# (41) R1: Workspace-Verifikation sichtbar (log_ok + howto_step)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "R1 Exit 0"                       "0" "$rc"
check "R1 Namespace-URI ok sichtbar"    "yes" "$(grep -q 'Namespace-URI ok' "$T/out.log" && echo yes || echo no)"
check "R1 WMS GetCapabilities sichtbar" "yes" "$(grep -q 'WMS GetCapabilities 200' "$T/out.log" && echo yes || echo no)"
check "R1 WFS GetCapabilities sichtbar" "yes" "$(grep -q 'WFS GetCapabilities 200' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (42) R2: Antworttext erscheint gekürzt in der Fehlermeldung
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
LONG="$(head -c 240 /dev/zero | tr '\0' 'A')TAIL"
export GS_WS_NONEMPTY=1
export GS_403_BODY="$LONG"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "R2 Exit 1"                          "1" "$rc"
check "R2 Antworttext gekürzt (kein TAIL)" "0" "$(grep -c 'TAIL' "$T/err.log" || true)"
check "R2 Antworttext vorhanden (A…)"      "yes" "$(grep -q 'AAAAAA' "$T/err.log" && echo yes || echo no)"
unset GS_WS_NONEMPTY GS_403_BODY

# ═══════════════════════════════════════════════════════════════════════════
# (43) Datastores: Erstlauf legt fünf Datastores mit 20 Einträgen an
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Erstlauf Exit 0"        "0" "$rc"
check "DS Erstlauf 5 Datastores"  "5" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f | awk 'END{print NR}')"
check "DS Payload 20 Einträge"    "20" "$(jq '.dataStore.connectionParameters.entry | length' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null || echo 0)"
check "DS Payload passwd korrekt" "$DB_PW" "$(jq -r '.dataStore.connectionParameters.entry[] | select(."@key"=="passwd") | ."$"' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null)"
check "DS Payload user korrekt"   "P2D2-MAIN" "$(jq -r '.dataStore.connectionParameters.entry[] | select(."@key"=="user") | ."$"' "$GS_STATE_DIR/ds/main/main_pg.json" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (44) Datastores: Zweitlauf setzt per PUT
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Zweitlauf Exit 0"     "0" "$rc"
check "DS Zweitlauf 5 PUT"      "5" "$(grep -c 'METHOD=PUT' "$CURL_BODY_LOG" || true)"
check "DS Zweitlauf kein POST"  "0" "$(grep 'datastores' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"

# ═══════════════════════════════════════════════════════════════════════════
# (45) Datastores: fehlender ENV-Schlüssel -> Exit 2 ohne Mutation
# ═══════════════════════════════════════════════════════════════════════════
reset_state
unset P2D2_BASE_DB_NAME
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS fehlender ENV Exit 2"    "2" "$rc"
check "DS fehlender ENV kein POST" "0" "$(grep -c '\-X POST' "$CURL_LOG" || true)"
export P2D2_BASE_DB_NAME="p2d2"

# ═══════════════════════════════════════════════════════════════════════════
# (46) Datastores: fehlendes Secret -> Fehler der Stage, übrige laufen, Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rm -f "$KUBE_STATE_DIR/secrets/p2d2-main-secret.dbpw"
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS fehlendes Secret Exit 1"        "1" "$rc"
check "DS fehlendes Secret 4 weitere"     "4" "$(grep 'datastores' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"
check "DS fehlendes Secret kein main POST" "0" "$(grep -c 'workspaces/main/datastores METHOD=POST' "$CURL_BODY_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (47) Datastores: Dry-run ohne POST/PUT
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "DS Dry-Run Exit 0"           "0" "$rc"
check "DS Dry-Run kein POST/PUT"    "0" "$(grep -c 'METHOD=POST\|METHOD=PUT' "$CURL_BODY_LOG" || true)"
check "DS Dry-Run keine Datastores" "0" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"

# ═══════════════════════════════════════════════════════════════════════════
# (48) Datastores: Uninstall löscht Datastores vor Workspaces, ohne recurse
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "DS Uninstall Exit 0"           "0" "$rc"
check "DS Uninstall ohne recurse"     "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"
check "DS Uninstall keine Datastores" "0" "$(find "$GS_STATE_DIR/ds" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
ds_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'datastores/[^/]*$' | head -1 | cut -d: -f1)"
ws_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'rest/workspaces/[^/]*$' | head -1 | cut -d: -f1)"
check "DS Uninstall Datastores vor Workspaces" "yes" "$([ -n "$ds_line" ] && [ -n "$ws_line" ] && [ "$ds_line" -lt "$ws_line" ] && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (49) Datastores: 403 beim Löschen -> Exit 1, Secrets bleiben
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_DS_NONEMPTY=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "DS nicht-leer Exit 1"          "1" "$rc"
check "DS nicht-leer Secrets bleiben" "6" "$(count_secrets)"
unset GS_DS_NONEMPTY

# ═══════════════════════════════════════════════════════════════════════════
# (50) Datastores: Verifikationsfehler (list=available ungleich 200) -> Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_LIST_AVAILABLE_FAIL_ON=6
rc="$(run_script --url "$URL" --ns "$NS")"
check "DS Verifikation list=available Exit 1"  "1" "$rc"
check "DS Verifikation list=available Meldung" "yes" "$(grep -q 'list=available' "$T/err.log" && echo yes || echo no)"
check "DS Verifikation erreicht (FeatureTypes angelegt)" "25" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
unset GS_LIST_AVAILABLE_FAIL_ON

# ═══════════════════════════════════════════════════════════════════════════
# (51) Datastores: kein DB-Passwort in Argumentlisten von curl/kubectl/jq
reset_state
export JQ_LOG_ARGS=1
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "DS kein DB-Passwort in curl-Args"    "0" "$(grep -c "$DB_PW" "$CURL_LOG" || true)"
check "DS kein DB-Passwort in kubectl-Args" "0" "$(grep -c "$DB_PW" "$KUBECTL_LOG" || true)"
check "DS kein DB-Passwort in jq-Args"      "0" "$(grep -c "$DB_PW" "$JQ_LOG" || true)"
unset JQ_LOG_ARGS

# ═══════════════════════════════════════════════════════════════════════════
# (52) R3: zwei Läufe unterschiedlichen Modus → zwei How-To-Dateien (Modus im Namen)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rm -f "$WORK"/p2d2-geoserver-config_v1_*.howto.md
run_script --dry-run --url "$URL" --ns "$NS" >/dev/null 2>&1
run_script --dry-run --uninstall --url "$URL" --ns "$NS" >/dev/null 2>&1
check "R3 zwei How-To-Dateien" "2" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_*.howto.md' -type f 2>/dev/null | awk 'END{print NR}')"
check "R3 install-dry-run im Namen" "yes" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_install-dry-run_*.howto.md' -type f 2>/dev/null | grep -q . && echo yes || echo no)"
check "R3 uninstall-dry-run im Namen" "yes" "$(find "$WORK" -maxdepth 1 -name 'p2d2-geoserver-config_v1_uninstall-dry-run_*.howto.md' -type f 2>/dev/null | grep -q . && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (53) R7: WMS-Dienstprüfung hart (503 → Exit 1)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_WMS_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "R7 WMS 503 Exit 1"             "1" "$rc"
check "R7 WMS GetCapabilities Meldung" "yes" "$(grep -q 'WMS GetCapabilities' "$T/err.log" && echo yes || echo no)"
unset GS_WMS_FAIL

# ═══════════════════════════════════════════════════════════════════════════
# (54) R4: abweichender Datastore-Parameter nennt erwartet/vorhanden
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_DS_BAD_PARAM=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "R4 DS-Bad-Param Exit 1"       "1" "$rc"
check "R4 DS-Diagnose user"          "yes" "$(grep -q 'user(erwartet P2D2-MAIN, vorhanden WRONG)' "$T/err.log" && echo yes || echo no)"
unset GS_DS_BAD_PARAM

# ═══════════════════════════════════════════════════════════════════════════
# (55) D: FeatureTypes Erstlauf (25 Stück, Umlaut-Titel, Default-Styles)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Erstlauf Exit 0"                "0" "$rc"
check "D Erstlauf 25 FeatureTypes"       "25" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "D graeber Titel Umlaut"           "Gräber (main)" "$(jq -r '.featureType.title' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" 2>/dev/null)"
check "D graeber Default-Style generic"  "generic" "$(cat "$GS_STATE_DIR/layers/main/graeber.style" 2>/dev/null)"
check "D geo-containers Style polygon"   "polygon" "$(cat "$GS_STATE_DIR/layers/main/geo-containers.style" 2>/dev/null)"
check "D Erstlauf kein Default-Style-PUT"  "0" "$(grep -c 'defaultStyle' "$CURL_BODY_LOG" || true)"
check "D Erstlauf 5 Attribution-PUTs"       "5" "$(grep -c 'attribution' "$CURL_BODY_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (55a) D: abweichender Default-Style -> PUT-Reparatur
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_DEFAULT_STYLE=point
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Style-Reparatur Exit 0"        "0" "$rc"
check "D Style-Reparatur 25 Default-Style-PUT"  "25" "$(grep -c 'defaultStyle' "$CURL_BODY_LOG" || true)"
unset GS_DEFAULT_STYLE

# ═══════════════════════════════════════════════════════════════════════════
# (56) D: Zweitlauf ohne Abweichung → kein POST/PUT auf FeatureTypes/Layer
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Zweitlauf Exit 0"             "0" "$rc"
check "D Zweitlauf kein FeatureType POST" "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=POST')"
check "D Zweitlauf kein FeatureType PUT"  "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=PUT')"
check "D Zweitlauf kein Layer PUT"       "0" "$(grep 'layers/' "$CURL_BODY_LOG" | grep -c 'METHOD=PUT')"

# ═══════════════════════════════════════════════════════════════════════════
# (57) D: abweichender Titel → PUT (nur bei Abweichung)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
jq '.featureType.title = "X-Titel"' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" > "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/graeber.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "D Titel-Abweichung Exit 0"           "0" "$rc"
check "D Titel-Abweichung 1 PUT auf graeber" "1" "$(grep -c 'featuretypes/graeber METHOD=PUT' "$CURL_BODY_LOG")"

# ═══════════════════════════════════════════════════════════════════════════
# (58) D: fehlender Native-Name → Exit 1, kein POST für den betroffenen FeatureType
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_LIST_AVAILABLE_MISSING_NATIVE=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D fehlender Native Exit 1"     "1" "$rc"
check "D fehlender Native kein graeber" "0" "$(test -f "$GS_STATE_DIR/ft/main/main_pg/graeber.json" && echo 1 || echo 0)"
check "D fehlender Native 20 übrige"   "20" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
unset GS_LIST_AVAILABLE_MISSING_NATIVE

# ═══════════════════════════════════════════════════════════════════════════
# (59) D: fehlender Stil → Exit 2, keine Mutation
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_STYLE_POLYGON_MISSING=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D fehlender Stil Exit 2"          "2" "$rc"
check "D fehlender Stil keine FeatureTypes" "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "D fehlender Stil keine Secrets"    "0" "$(count_secrets)"
unset GS_STYLE_POLYGON_MISSING

# ═══════════════════════════════════════════════════════════════════════════
# (60) D: Dry-run → kein Schreibaufruf (FeatureTypes)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "D Dry-Run Exit 0"                  "0" "$rc"
check "D Dry-Run kein FeatureType POST/PUT" "0" "$(grep 'featuretypes' "$CURL_BODY_LOG" | grep -c 'METHOD=POST\|METHOD=PUT')"
check "D Dry-Run keine FeatureTypes"       "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"

# ═══════════════════════════════════════════════════════════════════════════
# (61) D: Uninstall Reihenfolge Layer → FeatureType → Datastore, ohne recurse
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "D Uninstall Exit 0"          "0" "$rc"
check "D Uninstall ohne recurse"    "0" "$(grep -c 'recurse' "$CURL_LOG" || true)"
check "D Uninstall keine FeatureTypes" "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
layer_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'layers/' | head -1 | cut -d: -f1)"
ft_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'featuretypes/' | head -1 | cut -d: -f1)"
ds_line="$(grep -n -- '-X DELETE' "$CURL_LOG" | grep 'datastores/[^/]*$' | head -1 | cut -d: -f1)"
check "D Uninstall Layer vor FeatureType" "yes" "$([ -n "$layer_line" ] && [ -n "$ft_line" ] && [ "$layer_line" -lt "$ft_line" ] && echo yes || echo no)"
check "D Uninstall FeatureType vor Datastore" "yes" "$([ -n "$ft_line" ] && [ -n "$ds_line" ] && [ "$ft_line" -lt "$ds_line" ] && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (62) D: WFS-Antwort mit ExceptionReport → Verifikationsfehler Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_WFS_EXCEPTION=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "D WFS-Exception Exit 1"        "1" "$rc"
check "D WFS-Exception Meldung"       "yes" "$(grep -q 'DescribeFeatureType' "$T/err.log" && echo yes || echo no)"
unset GS_WFS_EXCEPTION

# ═══════════════════════════════════════════════════════════════════════════
# (63) B1: Uninstall nach Install — kein 500, „Uninstall verifiziert"
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B1 Uninstall Exit 0"                 "0" "$rc"
check "B1 kein featuretypes.json 500"       "0" "$(grep -c 'featuretypes.json fehlgeschlagen (HTTP 500)' "$T/err.log" || true)"
check "B1 Uninstall verifiziert"            "yes" "$(grep -q 'Uninstall verifiziert' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (64) B2: zweiter Uninstall idempotent
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
run_script --uninstall --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B2 zweiter Uninstall Exit 0"      "0" "$rc"
check "B2 zweiter Uninstall verifiziert" "yes" "$(grep -q 'Uninstall verifiziert' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (65) B3: Dry-run Install auf leerem System
# ═══════════════════════════════════════════════════════════════════════════
reset_state
clear_logs
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "B3 Dry-Run leer Install Exit 0"       "0" "$rc"
check "B3 Dry-Run leer Install keine FEHLER" "0" "$(grep -c 'FEHLER' "$T/err.log" || true)"
check "B3 Dry-Run leer würde angelegt"       "yes" "$(grep -q 'main/geo-containers würde angelegt' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (66) B3: Dry-run Uninstall auf leerem System
# ═══════════════════════════════════════════════════════════════════════════
reset_state
clear_logs
rc="$(run_script --dry-run --uninstall --url "$URL" --ns "$NS")"
check "B3 Dry-Run leer Uninstall Exit 0"       "0" "$rc"
check "B3 Dry-Run leer Uninstall keine FEHLER" "0" "$(grep -c 'FEHLER' "$T/err.log" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (67) B1: echter Lesefehler (500 für vorhandenen Datastore) bleibt Fehler
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_FT_LIST_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B1 500 vorhandener Datastore Exit 1" "1" "$rc"
check "B1 500 nicht als leer gewertet"      "yes" "$(grep -q 'FeatureType-Liste für' "$T/err.log" && echo yes || echo no)"
unset GS_FT_LIST_FAIL

# ═══════════════════════════════════════════════════════════════════════════
# (68) B4: Meldungen mit <ws>/<name>-Präfix
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
check "B4 Präfix main/geo-containers angelegt"      "yes" "$(grep -q 'main/geo-containers angelegt' "$T/out.log" && echo yes || echo no)"
check "B4 Präfix main/graeber DescribeFeatureType"  "yes" "$(grep -q 'main/graeber: DescribeFeatureType ok' "$T/out.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (69) B5: numerische Bounding-Box (-10.0 == -10) → unverändert
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
sed 's/"minx": -10,/"minx": -10.0,/g' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp"
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 numerische BBox Exit 0"  "0" "$rc"
check "B5 numerische BBox kein PUT" "0" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# ═══════════════════════════════════════════════════════════════════════════
# (70) B5: metadata.entry als Array → unverändert
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
jq '.featureType.metadata.entry = [.featureType.metadata.entry]' "$GS_STATE_DIR/ft/main/main_pg/grabflure.json" > "$GS_STATE_DIR/ft/main/main_pg/grabflure.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/grabflure.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/grabflure.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 metadata-Array Exit 0"  "0" "$rc"
check "B5 metadata-Array kein PUT" "0" "$(grep -c 'featuretypes/grabflure METHOD=PUT' "$CURL_BODY_LOG")"

# ═══════════════════════════════════════════════════════════════════════════
# (71) B5: Titel-Abweichung → PUT mit Info-Zeile statt FEHLER
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
jq '.featureType.title = "X-Titel"' "$GS_STATE_DIR/ft/main/main_pg/graeber.json" > "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/graeber.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/graeber.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B5 Titel-Abweichung Exit 0"            "0" "$rc"
check "B5 Titel-Abweichung 1 PUT"             "1" "$(grep -c 'featuretypes/graeber METHOD=PUT' "$CURL_BODY_LOG")"
check "B5 Titel-Abweichung Info statt FEHLER" "yes" "$(grep -q 'title weicht ab' "$T/out.log" && echo yes || echo no)"
check "B5 Titel-Abweichung kein FEHLER title" "0" "$(grep -c 'FEHLER.*title weicht ab' "$T/err.log" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (72) B6/B7: Hilfe und How-To
# ═══════════════════════════════════════════════════════════════════════════
rc="$(run_script --help)"
check "B6 --help nennt FeatureTypes" "yes" "$(grep -q 'FeatureTypes' "$T/out.log" && echo yes || echo no)"

reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "B7 How-To Ausgeführte Schritte" "yes" "$(grep -q '## Ausgeführte Schritte' "$howto_file" && echo yes || echo no)"
check "B7 How-To Body-Skelett"         "yes" "$(grep -q 'nativeBoundingBox' "$howto_file" && echo yes || echo no)"
check "B7 How-To FT_TABLE"             "yes" "$(grep -q 'geo-containers|p2d2_containers' "$howto_file" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (73) A: Erstlauf Attribut-Mapping geo-containers (osm_name -> name)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping Erstlauf Exit 0"          "0" "$rc"
check "A Mapping name mit source osm_name" "osm_name" "$(jq -r '.featureType.attributes.attribute[]? | select(.name=="name") | .source // empty' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" 2>/dev/null)"
check "A Mapping kein osm_name extra"       "" "$(jq -r '[.featureType.attributes.attribute[]?.name] | index("osm_name") // empty' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" 2>/dev/null)"
check "A Mapping 5 PUTs"                    "5" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# ═══════════════════════════════════════════════════════════════════════════
# (74) A: Zweitlauf ohne Mapping-PUT
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping Zweitlauf Exit 0"   "0" "$rc"
check "A Mapping Zweitlauf kein PUT" "0" "$(grep -c 'featuretypes/geo-containers METHOD=PUT' "$CURL_BODY_LOG")"

# ═══════════════════════════════════════════════════════════════════════════
# (75) A: Konflikt doppeltes Attribut (name und osm_name)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
jq '.featureType.attributes.attribute = [{"name":"name","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"},{"name":"osm_name","minOccurs":0,"maxOccurs":1,"nillable":true,"binding":"java.lang.String"}]' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping doppelt Exit 1"   "1" "$rc"
check "A Mapping doppelt Meldung"  "yes" "$(grep -q 'doppeltes Attribut' "$T/err.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (76) A: Konflikt fehlende Quelle (kein name und kein osm_name)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
jq '.featureType.attributes.attribute = []' "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json" > "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" 2>/dev/null
mv "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json.tmp" "$GS_STATE_DIR/ft/main/main_pg/geo-containers.json"
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "A Mapping quelle fehlt Exit 1"  "1" "$rc"
check "A Mapping quelle fehlt Meldung" "yes" "$(grep -q 'weder' "$T/err.log" && echo yes || echo no)"

# ═══════════════════════════════════════════════════════════════════════════
# (77) B: Erstlauf 50 Layer-ACLs mit Stage-Trennung
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Erstlauf Exit 0"             "0" "$rc"
check "B ACL 50 Regeln"                    "50" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL 50 POSTs"                     "50" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG")"
check "B ACL Stage-Trennung (de1)"         "P2D2_WFST_DE1,ADMIN" "$(jq -r '."de1.grabflure_versionen.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL geo-containers write"         "P2D2_IMPORT_ROLE,ADMIN" "$(jq -r '."main.geo-containers.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL grabflure write"              "ADMIN" "$(jq -r '."main.grabflure.w"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (78) B: Zweitlauf ohne unnötige Mutation
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
clear_logs
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Zweitlauf Exit 0"     "0" "$rc"
check "B ACL Zweitlauf kein POST"  "0" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG" || true)"

# ═══════════════════════════════════════════════════════════════════════════
# (79) B: fremde Regeln bleiben unverändert
# ═══════════════════════════════════════════════════════════════════════════
reset_state
printf '%s' '{"foreign.layer.r":"ROLE_X"}' > "$GS_STATE_DIR/acl.map"
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL fremd Exit 0"      "0" "$rc"
check "B ACL fremd bleibt"      "ROLE_X" "$(jq -r '."foreign.layer.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL fremd + 50 eigene" "51" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (80) B: Konflikt (gleiche Regel, andere Rollen) -> Exit 1, keine Änderung
# ═══════════════════════════════════════════════════════════════════════════
reset_state
printf '%s' '{"main.geo-containers.r":"SOMETHING_ELSE"}' > "$GS_STATE_DIR/acl.map"
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Konflikt Exit 1"   "1" "$rc"
check "B ACL Konflikt Meldung"  "yes" "$(grep -q 'Konflikt' "$T/err.log" && echo yes || echo no)"
check "B ACL Konflikt unverändert" "SOMETHING_ELSE" "$(jq -r '."main.geo-containers.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (81) B: Lesefehler (GET acl) -> Exit 1
# ═══════════════════════════════════════════════════════════════════════════
reset_state
export GS_ACL_GET_FAIL=1
rc="$(run_script --url "$URL" --ns "$NS")"
check "B ACL Lesefehler Exit 1" "1" "$rc"
unset GS_ACL_GET_FAIL

# ═══════════════════════════════════════════════════════════════════════════
# (82) B: Dry-run ohne ACL-POST
# ═══════════════════════════════════════════════════════════════════════════
reset_state
rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
check "B ACL Dry-Run Exit 0"       "0" "$rc"
check "B ACL Dry-Run kein POST"    "0" "$(grep -c 'security/acl/layers' "$CURL_BODY_LOG" || true)"
check "B ACL Dry-Run keine Regeln" "0" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (83) B: Uninstall entfernt eigene Regeln, fremde bleiben (nicht exakt 50 DELETEs)
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
# Fremde Regel nach dem Install dazulegen (bleibt bei Uninstall erhalten).
printf '%s' '{"foreign.layer.r":"ROLE_X"}' > "$GS_STATE_DIR/acl.add"
jq -s '.[0] * .[1]' "$GS_STATE_DIR/acl.map" "$GS_STATE_DIR/acl.add" > "$GS_STATE_DIR/acl.map.new" 2>/dev/null
mv "$GS_STATE_DIR/acl.map.new" "$GS_STATE_DIR/acl.map"
rm -f "$GS_STATE_DIR/acl.add"
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B ACL Uninstall Exit 0"        "0" "$rc"
check "B ACL Uninstall eigene weg"    "no" "$(jq -e 'has("main.geo-containers.r")' "$GS_STATE_DIR/acl.map" >/dev/null 2>&1 && echo yes || echo no)"
check "B ACL Uninstall fremde bleibt" "ROLE_X" "$(jq -r '."foreign.layer.r"' "$GS_STATE_DIR/acl.map" 2>/dev/null)"
check "B ACL Uninstall nur fremde"    "1" "$(jq 'length' "$GS_STATE_DIR/acl.map" 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════════
# (84) B: Teilfehler — nur ein Layer-DELETE scheitert; ACL/Rolle bleiben, Rest räumt auf
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --url "$URL" --ns "$NS" >/dev/null 2>&1
export GS_LAYER_DELETE_FAIL=1
clear_logs
rc="$(run_script --uninstall --url "$URL" --ns "$NS")"
check "B ACL Layer bleibt Exit 1"           "1" "$rc"
check "B ACL Layer bleibt Regel bleibt"     "yes" "$(jq -e 'has("main.geo-containers.r")' "$GS_STATE_DIR/acl.map" >/dev/null 2>&1 && echo yes || echo no)"
check "B ACL Layer bleibt Rolle bleibt"     "yes" "$(grep -q 'P2D2_IMPORT_ROLE' "$GS_STATE_DIR/roles.list" && echo yes || echo no)"
check "B ACL Layer bleibt FeatureType weg"  "0" "$(find "$GS_STATE_DIR/ft" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
check "B ACL Layer bleibt WFS-USER weg"    "yes" "$(grep -qx 'WFS-USER' "$GS_STATE_DIR/roles.list" && echo no || echo yes)"
unset GS_LAYER_DELETE_FAIL

}

# ═══════════════════════════════════════════════════════════════════════════
# Gate: alte Szenarien nur laufen lassen, wenn GEOSERVER_ONLY nicht "new" ist.
# ═══════════════════════════════════════════════════════════════════════════
[ "${GEOSERVER_ONLY:-all}" = "new" ] || scenarios_legacy

# ═══════════════════════════════════════════════════════════════════════════
# Neue Szenarien 85–96 (Metadaten, Workspace-/Dienst-Einstellungen, Layer)
# ═══════════════════════════════════════════════════════════════════════════

# (85) leerer Zustand, Install: Einstellungen + Dienst-Metadaten + 8 Stellen
if want 85; then
  reset_state
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S85 Exit 0" "0" "$rc"
  check "S85 numDecimals 8 (5 WS)" "5" "$(for ws in main dev de1 de2 fv; do jq -r '.settings.numDecimals // empty' "$GS_STATE_DIR/settings/$ws.json" 2>/dev/null; done | grep -c '^8$')"
  check "S85 charset UTF-8 (5 WS)" "5" "$(for ws in main dev de1 de2 fv; do jq -r '.settings.charset // empty' "$GS_STATE_DIR/settings/$ws.json" 2>/dev/null; done | grep -c '^UTF-8$')"
  check "S85 Kontakt main" "info@data-dna.eu" "$(jq -r '.settings.contact.contactEmail // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
  check "S85 10 Dienst-Einstellungen" "10" "$(find "$GS_STATE_DIR/service" -name '*.json' -type f 2>/dev/null | awk 'END{print NR}')"
  check "S85 GetFeature 8 Stellen" "5" "$(grep -c 'mit 8 Nachkommastellen' "$T/out.log")"
fi

# (86) Snapshot, zweiter Lauf: idempotent, keine settings PUT/POST
if want 86; then
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S86 Exit 0" "0" "$rc"
  check "S86 kein settings PUT/POST" "0" "$(grep -c '/settings' "$CURL_BODY_LOG" || true)"
fi

# (87) Snapshot, dev lokal auf 4: genau ein Reparatur-PUT auf dev
if want 87; then
  ensure_snap_installed
  restore_state
  jq '.settings.numDecimals = 4' "$GS_STATE_DIR/settings/dev.json" > "$GS_STATE_DIR/settings/dev.json.tmp" 2>/dev/null
  mv "$GS_STATE_DIR/settings/dev.json.tmp" "$GS_STATE_DIR/settings/dev.json"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S87 Exit 0" "0" "$rc"
  check "S87 genau 1 settings PUT dev" "1" "$(grep -c 'workspaces/dev/settings METHOD=PUT' "$CURL_BODY_LOG")"
  check "S87 Info weicht ab" "yes" "$(grep -q 'weichen ab' "$T/out.log" && echo yes || echo no)"
fi

# (88) Snapshot: charset und contact.id bleiben (Ersetzen-Falle)
if want 88; then
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S88 Exit 0" "0" "$rc"
  check "S88 charset bleibt" "UTF-8" "$(jq -r '.settings.charset // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
  check "S88 contact.id bleibt" "contact" "$(jq -r '.settings.contact.id // empty' "$GS_STATE_DIR/settings/main.json" 2>/dev/null)"
fi

# (89) GS_SETTINGS_PUT_DROPS_KEY=charset: Exit 1, verlorener Schlüssel gemeldet
if want 89; then
  ensure_snap_installed
  restore_state
  export GS_SETTINGS_PUT_DROPS_KEY=charset
  jq '.settings.numDecimals = 3' "$GS_STATE_DIR/settings/dev.json" > "$GS_STATE_DIR/settings/dev.json.tmp" 2>/dev/null
  mv "$GS_STATE_DIR/settings/dev.json.tmp" "$GS_STATE_DIR/settings/dev.json"
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S89 Exit 1" "1" "$rc"
  check "S89 Meldung verlorener Schlüssel" "yes" "$(grep -q 'charset' "$T/err.log" && echo yes || echo no)"
  unset GS_SETTINGS_PUT_DROPS_KEY
fi

# (90) YAML mit TODO: Exit 2 ohne Mutation; mit --allow-incomplete-metadata: Exit 0 + WARN
if want 90; then
  reset_state
  bundle_copy "$T/todo"
  sed 's|license: "ODbL-1.0"|license: "TODO"|' "$REPO/supplement/geoserver-metadata.md" > "$T/todo/geoserver-metadata.md"
  rc="$(run_bundle "$T/todo" --url "$URL" --ns "$NS")"
  check "S90 TODO Exit 2" "2" "$rc"
  check "S90 TODO keine Mutation" "0" "$(grep -cE 'METHOD=(POST|PUT|DELETE)' "$CURL_BODY_LOG" || true)"
  clear_logs
  rc="$(run_bundle "$T/todo" --allow-incomplete-metadata --url "$URL" --ns "$NS")"
  check "S90 allow Exit 0" "0" "$rc"
  check "S90 allow WARN" "yes" "$(grep -q 'unvollständig' "$T/err.log" && echo yes || echo no)"
fi

# (91) Snapshot: Titel/Abstract je Workspace korrekt aufgelöst
if want 91; then
  ensure_snap_installed
  check "S91 dev WMS-Titel" "p2d2 Karten – dev" "$(jq -r '.wms.title // empty' "$GS_STATE_DIR/service/dev/wms.json" 2>/dev/null)"
  check "S91 de1 WFS-Abstract Team-Staging DE1" "yes" "$(jq -r '.wfs.abstrct // empty' "$GS_STATE_DIR/service/de1/wfs.json" 2>/dev/null | grep -q 'Team-Staging DE1' && echo yes || echo no)"
fi

# (92) GS_CAPS_NO_TITLE=1: Exit 1 aus der Capabilities-Verifikation
if want 92; then
  ensure_snap_installed
  restore_state
  export GS_CAPS_NO_TITLE=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S92 Exit 1" "1" "$rc"
  unset GS_CAPS_NO_TITLE
fi

# (93) GS_IGNORE_SETTINGS=1: Exit 1, Koordinaten auf 4 Stellen gerundet
if want 93; then
  ensure_snap_installed
  restore_state
  export GS_IGNORE_SETTINGS=1
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S93 Exit 1" "1" "$rc"
  check "S93 Meldung 4 Stellen" "yes" "$(grep -q 'auf 4 Stellen gerundet' "$T/err.log" && echo yes || echo no)"
  unset GS_IGNORE_SETTINGS
fi

# (94) --dry-run: Exit 0, keine Mutation, How-To im Dry-run-Modus
if want 94; then
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --dry-run --url "$URL" --ns "$NS")"
  check "S94 Exit 0" "0" "$rc"
  check "S94 keine Mutation" "0" "$(grep -cE 'METHOD=(POST|PUT|DELETE)' "$CURL_BODY_LOG" || true)"
  howto_file="$(latest_howto)"
  check "S94 How-To dry-run" "yes" "$(grep -q 'dry-run' "$howto_file" && echo yes || echo no)"
fi

# (95) GS_SERVICE_PUT_405=1: Anlage per POST, HowTo nennt die Methode
if want 95; then
  reset_state
  export GS_SERVICE_PUT_405=1
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S95 Exit 0" "0" "$rc"
  check "S95 Service-POST" "yes" "$(grep -q 'services/wms/workspaces/main/settings METHOD=POST' "$CURL_BODY_LOG" && echo yes || echo no)"
  howto_file="$(latest_howto)"
  check "S95 How-To nennt POST" "yes" "$(grep -q 'POST services/wms/workspaces/main/settings' "$howto_file" && echo yes || echo no)"
  unset GS_SERVICE_PUT_405
fi

# (96) Snapshot: Attribution nur bei Abweichung (Zweitlauf keiner)
if want 96; then
  ensure_snap_installed
  restore_state
  clear_logs
  rc="$(run_script --url "$URL" --ns "$NS")"
  check "S96 Exit 0" "0" "$rc"
  check "S96 kein Layer-PUT im Zweitlauf" "0" "$(grep -c '/layers/' "$CURL_BODY_LOG" || true)"
  check "S96 Attribution gesetzt" "© OpenStreetMap-Mitwirkende" "$(jq -r '.title // empty' "$GS_STATE_DIR/layers/main/geo-containers.attr.json" 2>/dev/null)"
fi

rm -rf "$T"

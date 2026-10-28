#!/usr/bin/env bash
# Suite 31: DB-Passwort-Mechanik — Platzhalter-Erkennung, .env-Spiegel
# (Backup/atomar/idempotent), keine Klartext-Literale, keine Passwörter in
# Prozesslisten. Nur Testwerte und Stubs, kein Cluster/Netz.

begin_suite "db_passwoerter"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

export ADDON_DB_NS="cc-prd-database-stack"
export ADDON_NS="cc-prd-geodata-stack"
export ADDON_ENV_FILE="$T/.env.p2d2-addon"

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_00_postgresql.sh"
set +e

# ── (c) Platzhalter-Erkennung ─────────────────────────────────────────────────
check "c leer ist leer"       "0" "$(_p2d2_pw_empty "" && echo 0 || echo 1)"
check "c changeme ist leer"   "0" "$(_p2d2_pw_empty "changeme-main" && echo 0 || echo 1)"
check "c CHANGEME ist leer"   "0" "$(_p2d2_pw_empty "CHANGEME-main" && echo 0 || echo 1)"
check "c Wert ist nicht leer" "1" "$(_p2d2_pw_empty "abc123" && echo 0 || echo 1)"

# ── _p2d2_pw_gen: 48 Hex-Zeichen ──────────────────────────────────────────────
pw="$(_p2d2_pw_gen)"
check "pw_gen 48 Zeichen" "48" "$(printf '%s' "$pw" | wc -c)"
check "pw_gen nur Hex" "yes" "$(printf '%s' "$pw" | grep -qE '^[0-9a-f]{48}$' && echo yes || echo no)"

# ── (b/f) .env-Spiegel: Backup, idempotent, Kommentare/Reihenfolge ────────────
cat > "$T/env" <<EOF
# Kommentar oben
export DOMAIN_NAME="example.org"
export P2D2_MAIN_DB_PASSWORD="old"
export P2D2_MAIN_SESSION_SECRET="keep"
# Kommentar unten
EOF

# (b) erster Spiegel mit neuem Wert -> Backup + Schreiben.
_p2d2_env_mirror "$T/env" "P2D2_MAIN_DB_PASSWORD" "newhexvalue" >/dev/null 2>&1
check "b .bak vorhanden" "yes" "$([[ -f "$T/env.bak" ]] && echo yes || echo no)"
check "b .bak Mode 600" "600" "$(stat -c '%a' "$T/env.bak")"
check "b Wert ersetzt" "newhexvalue" "$(sed -n 's/^export P2D2_MAIN_DB_PASSWORD="\([^"]*\)"/\1/p' "$T/env")"
check "b Kommentar oben erhalten" "yes" "$(grep -q '^# Kommentar oben$' "$T/env" && echo yes || echo no)"
check "b Kommentar unten erhalten" "yes" "$(grep -q '^# Kommentar unten$' "$T/env" && echo yes || echo no)"
check "b andere Zeile unverändert" "keep" "$(sed -n 's/^export P2D2_MAIN_SESSION_SECRET="\([^"]*\)"/\1/p' "$T/env")"
check "b DOMAIN unverändert" "example.org" "$(sed -n 's/^export DOMAIN_NAME="\([^"]*\)"/\1/p' "$T/env")"

# (f) zweiter Spiegel mit gleichem Wert: keine Änderung (Prüfsumme identisch).
before_sum="$(sha256sum "$T/env" | awk '{print $1}')"
_p2d2_env_mirror "$T/env" "P2D2_MAIN_DB_PASSWORD" "newhexvalue" >/dev/null 2>&1
check "f kein zweites Schreiben" "$before_sum" "$(sha256sum "$T/env" | awk '{print $1}')"

# Append, wenn Variable fehlt.
_p2d2_env_mirror "$T/env" "P2D2_RO_DB_PASSWORD" "rohex" >/dev/null 2>&1
check "append RO vorhanden" "rohex" "$(sed -n 's/^export P2D2_RO_DB_PASSWORD="\([^"]*\)"/\1/p' "$T/env")"

# ── (e) Schreibfehler -> Warnung, Rückgabe 1, kein Abbruch ────────────────────
: > "$LOGBUF"
_p2d2_env_mirror "$T/nonexistent" "P2D2_MAIN_DB_PASSWORD" "x" >/dev/null 2>&1
check "e Schreibfehler rc=1" "1" "$?"
check "e Schreibfehler Warnung" "yes" "$(grep -q 'Spiegeln übersprungen' "$LOGBUF" && echo yes || echo no)"

# ── (h) kein changeme-Literal in addon_00 außerhalb der Erkennungs-Hilfe ──────
hit="$(grep -nI -i 'changeme' "$REPO/modules_addon_V1s/addon_00_postgresql.sh" \
  | grep -v 'changeme\*' | grep -v '_p2d2_pw_empty' || true)"
check "h kein changeme-Literal" "" "$hit"

# ── (g) keine Passwörter per --from-literal (Prozessliste) ────────────────────
check "g kein --from-literal Passwort" "0" \
  "$(grep -cE 'from-literal=.*(admin_pw|ro_pw|stage_pw|DB_PASSWORD)' "$REPO/modules_addon_V1s/addon_00_postgresql.sh")"
check "g kein --from-literal in Bibliothek" "0" \
  "$(grep -cE 'from-literal' "$REPO/modules_addon_V1s/addon_03_secrets.sh")"

# ── C8(a) mehrere Variablen -> .bak enthält den Ausgangszustand ───────────────
cat > "$T/env2" <<EOF
# Kopf
export P2D2_MAIN_DB_PASSWORD="orig-main"
export P2D2_RO_DB_PASSWORD="orig-ro"
EOF
_p2d2_env_backup_reset
_p2d2_env_mirror "$T/env2" "P2D2_MAIN_DB_PASSWORD" "new-main" >/dev/null 2>&1
_p2d2_env_mirror "$T/env2" "P2D2_RO_DB_PASSWORD" "new-ro" >/dev/null 2>&1
check "a .bak = Ausgangszustand (main)" "orig-main" "$(sed -n 's/^export P2D2_MAIN_DB_PASSWORD="\([^"]*\)"/\1/p' "$T/env2.bak")"
check "a .bak = Ausgangszustand (ro)" "orig-ro" "$(sed -n 's/^export P2D2_RO_DB_PASSWORD="\([^"]*\)"/\1/p' "$T/env2.bak")"

# ── C8(c) Validierung: Sonderzeichen/zu kurz -> abgelehnt ─────────────────────
: > "$LOGBUF"
_p2d2_pw_validate "P2D2_MAIN_DB_PASSWORD" "abc'def" >/dev/null 2>&1
check "c Hochkomma abgelehnt" "1" "$?"
_p2d2_pw_validate "P2D2_MAIN_DB_PASSWORD" 'abc$def' >/dev/null 2>&1
check "c Dollar abgelehnt" "1" "$?"
_p2d2_pw_validate "P2D2_MAIN_DB_PASSWORD" "short" >/dev/null 2>&1
check "c zu kurz abgelehnt" "1" "$?"
_p2d2_pw_validate "P2D2_MAIN_DB_PASSWORD" "abcdefghijklmnopqrstuvwxyz" >/dev/null 2>&1
check "c gültiger Wert ok" "0" "$?"
check "c Fehlermeldung ohne Wert" "no" "$(grep -q "abc'def" "$LOGBUF" && echo yes || echo no)"

# ── C8(d) Host-Merge: nur verwaltete Zeilen, ein .bak, Mode 600 ───────────────
cat > "$T/vm-env" <<EOF
export P2D2_MAIN_DB_PASSWORD="vm-main"
export P2D2_MAIN_SESSION_SECRET="vm-session"
export UNRELATED="keep-me"
EOF
cat > "$T/host-env" <<EOF
# Kopf
export P2D2_MAIN_DB_PASSWORD="host-old"
export P2D2_MAIN_SESSION_SECRET="host-session"
export UNRELATED="keep-me"
EOF
_p2d2_env_backup_reset
_p2d2_env_merge_from "$T/vm-env" "$T/host-env" >/dev/null 2>&1
check "d DB_PASSWORD übernommen" "vm-main" "$(sed -n 's/^export P2D2_MAIN_DB_PASSWORD="\([^"]*\)"/\1/p' "$T/host-env")"
check "d SESSION_SECRET unverändert" "host-session" "$(sed -n 's/^export P2D2_MAIN_SESSION_SECRET="\([^"]*\)"/\1/p' "$T/host-env")"
check "d UNRELATED unverändert" "keep-me" "$(sed -n 's/^export UNRELATED="\([^"]*\)"/\1/p' "$T/host-env")"
check "d .bak vorhanden" "yes" "$([[ -f "$T/host-env.bak" ]] && echo yes || echo no)"
check "d .bak Mode 600" "600" "$(stat -c '%a' "$T/host-env.bak")"

# ── D2(a) Sentinel + direkter Aufruf setzt/exportiert im aufrufenden Prozess ──
_f() { export ZZ_TEST=1; printf x; }
v="$(_f)"
check "D2 Substitution verliert Export" "yes" "$([[ -z "${ZZ_TEST:-}" ]] && echo yes || echo no)"
_f >/dev/null
check "D2 direkter Aufruf behält Export" "1" "${ZZ_TEST:-}"

# ── D2(a) _p2d2_pw_resolve direkt aufgerufen -> Variable gesetzt ─────────────
unset P2D2_MAIN_DB_PASSWORD
_p2d2_pw_resolve P2D2_MAIN_DB_PASSWORD "ns" "p2d2-main-secret" "DB_PASSWORD"
check "D2 resolve setzt Variable" "yes" "$([[ -n "${P2D2_MAIN_DB_PASSWORD:-}" ]] && echo yes || echo no)"
check "D2 resolve valider Wert" "0" "$(_p2d2_pw_is_valid "${P2D2_MAIN_DB_PASSWORD}" && echo 0 || echo 1)"

# ── D2(b) _addon_ensure_secret bricht für aufgelöstes DB_PASSWORD nicht ab ────
export ADDON_DOMAIN="udp.example.org"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
: > "$LOGBUF"
_addon_ensure_secret ns p2d2-main-secret "DB_PASSWORD=${P2D2_MAIN_DB_PASSWORD}" >/dev/null 2>&1
check "D2 ensure_secret ok (aufgelöst)" "0" "$?"

# ── D2(c) statisch: kein _p2d2_pw_resolve in Befehlssubstitution ─────────────
check "D2 kein _p2d2_pw_resolve in Substitution" "0" \
  "$(grep -rEn '\$\([[:space:]]*_p2d2_pw_resolve' "$REPO/modules_addon_V1s" "$REPO/p2d2-civitas-addon-v1s.sh" | wc -l)"

# ── D3 Kommentar am Zeilenende bleibt erhalten ───────────────────────────────
cat > "$T/env3" <<EOF
export P2D2_MAIN_DB_PASSWORD="old"   # K3 - kommentar
EOF
_p2d2_env_backup_reset
_p2d2_env_mirror "$T/env3" "P2D2_MAIN_DB_PASSWORD" "new-value" >/dev/null 2>&1
check "D3 Wert ersetzt" "new-value" "$(_p2d2_env_read "$T/env3" "P2D2_MAIN_DB_PASSWORD")"
check "D3 Kommentar erhalten" "yes" "$(grep -q '# K3 - kommentar' "$T/env3" && echo yes || echo no)"
before_sum3="$(sha256sum "$T/env3" | awk '{print $1}')"
_p2d2_env_mirror "$T/env3" "P2D2_MAIN_DB_PASSWORD" "new-value" >/dev/null 2>&1
check "D3 idempotent (Kommentar)" "$before_sum3" "$(sha256sum "$T/env3" | awk '{print $1}')"

# ── D5 umask bleibt unverändert ──────────────────────────────────────────────
u0="$(umask)"
_p2d2_secret_apply ns p2d2-x-secret "DB_PASSWORD=abcdefghijklmnop" >/dev/null 2>&1
check "D5 umask unverändert" "$u0" "$(umask)"

# ── Phase 1 (D1): _p2d2_managed_vars enthält WFST-Passwörter ───────────────
managed="$( _p2d2_managed_vars )"
check "WFST managed 5 Stages" "5" "$(printf '%s\n' "$managed" | grep -cE '^P2D2_(MAIN|DEVELOP|DE1|DE2|FV)_WFST_PASSWORD$')"
check "WFST managed MAIN enthalten" "yes" "$(printf '%s\n' "$managed" | grep -qx 'P2D2_MAIN_WFST_PASSWORD' && echo yes || echo no)"

# ── Phase 1 (B6): _p2d2_secret_apply base64 korrekt (Manifest-Vergleich) ────
cat > "$T/kube.sh" <<'EOF'
if [[ "$*" == *"get secret"* ]]; then
  echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"x","namespace":"ns"},"type":"Opaque","data":{}}'
  exit 0
fi
if [[ "$*" == *"apply"* ]]; then
  manifest=""; args=("$@"); i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    if [ "${args[$i]}" = "-f" ]; then manifest="${args[$((i+1))]}"; break; fi
    i=$((i+1))
  done
  if [ -n "$manifest" ] && [ -f "$manifest" ]; then cp "$manifest" "$KUBECTL_MANIFEST_OUT"; fi
  exit 0
fi
exit 0
EOF
export KUBECTL_SCRIPT="$T/kube.sh"
export KUBECTL_MANIFEST_OUT="$T/manifest.json"
export PATH="$REPO/tests/stubs:$PATH"
_p2d2_secret_apply ns p2d2-x-secret "WFST_PASSWORD=abcdefghijklmnop" >/dev/null 2>&1
check "WFST secret apply rc=0" "0" "$?"
expected_b64="$(printf '%s' 'abcdefghijklmnop' | base64 -w0)"
check "WFST secret base64 korrekt" "$expected_b64" "$(jq -r '.data.WFST_PASSWORD // empty' "$T/manifest.json" 2>/dev/null)"

# ── Phase 1: ungültiger WFST-Wert bricht früh ab ────────────────────────────
export P2D2_MAIN_WFST_PASSWORD="tooshort"
_p2d2_pw_validate_env >/dev/null 2>&1
check "WFST ungültig bricht ab" "1" "$?"
unset P2D2_MAIN_WFST_PASSWORD

# ── Phase 1 (D1): allow_empty für WFST in addon_validate_nonempty ────────────
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_01_config.sh"
unset P2D2_MAIN_WFST_PASSWORD
addon_validate_nonempty "P2D2_MAIN_WFST_PASSWORD" 1
check "WFST leer allow_empty ok" "0" "$?"
addon_validate_nonempty "P2D2_MAIN_WFST_PASSWORD"
check "WFST leer Pflicht Fehler" "1" "$?"

# ── Phase 2: die vier Lib-Dateien setzen beim Sourcen keine Variablen ──────
rc="$( bash -c '
set -euo pipefail
before="$(compgen -v | sort)"
for f in core catalog security settings; do
  source "$1/modules_addon_V1s/addon_11_geoserver_config_${f}.sh"
done
after="$(compgen -v | sort)"
new="$(comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | grep -vE "^(f|before|after|new)$" || true)"
[[ -z "$new" ]] && echo OK || echo "LECK: $new"
' _ "$REPO" )"
check "addon_11 Libs sourcen ohne Variablen" "OK" "$rc"

# ── Phase 2 (Fix 2): Einstieg sourcen ohne Variablen (Guard + addon_03) ──────
rc="$( bash -c '
set -euo pipefail
export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
# shellcheck disable=SC1090,SC1091
source "$1/modules_addon_V1s/addon_03_secrets.sh"
before="$(compgen -v | sort)"
# shellcheck disable=SC1090,SC1091
source "$1/modules_addon_V1s/addon_11_geoserver_config.sh"
after="$(compgen -v | sort)"
new="$(comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | grep -vE "^(f|before|after|new|BASH_REMATCH)$" || true)"
[[ -z "$new" ]] && echo OK || echo "LECK: $new"
' _ "$REPO" )"
check "addon_11 Einstieg sourcen ohne Variablen" "OK" "$rc"

# ── Phase 2 (Fix 2 + Auflage 8/9): Laufzeittest mit Stubs ──────────────────
# Szenarien: Variablen-Leck (install/verify/uninstall), .env-Spiegel e1-e6,
# Uninstall mit Rest (Auflage 9). Alles in einer Subshell, ohne Netz/echte Secrets.
cat > "$T/runtime_gs.sh" <<'RUNTIME'
#!/usr/bin/env bash
set -u
REPO="$1"
T="$(mktemp -d)"
mkdir -p "$T/stubs"
export PATH="$T/stubs:$PATH"

log()      { :; }
log_ok()   { :; }
log_warn() { echo "W: $*" >&2; }
log_error(){ echo "E: $*" >&2; }

FAILS=""
reset_wfst() {
  unset P2D2_MAIN_WFST_PASSWORD P2D2_DEVELOP_WFST_PASSWORD P2D2_DE1_WFST_PASSWORD P2D2_DE2_WFST_PASSWORD P2D2_FV_WFST_PASSWORD
  _p2d2_env_backup_reset
  export GS_KUBECTL_WFST_VALUE=""
  export GS_KUBECTL_SECRET_PRESENT="0"
  export GS_KUBECTL_SECRET_ERROR="0"
  export GS_CURL_DS_REST=""
}

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
export ADDON_SUPPLEMENT_DIR="$REPO/supplement"
export P2D2_BASE_DB_HOST="central-db.test.svc.cluster.local"
export P2D2_BASE_DB_PORT="5432"
export P2D2_BASE_DB_NAME="p2d2"
export P2D2_MAIN_DB_USER="P2D2-MAIN"
export P2D2_DEVELOP_DB_USER="P2D2-DEVELOP"
export P2D2_DE1_DB_USER="P2D2-DE1"
export P2D2_DE2_DB_USER="P2D2-DE2"
export P2D2_FV_DB_USER="P2D2-FV"
export P2D2_MAIN_WFST_WORKSPACE="main"
export P2D2_MAIN_WFST_USERNAME="p2d2_wfst_main"
export P2D2_DEVELOP_WFST_WORKSPACE="dev"
export P2D2_DEVELOP_WFST_USERNAME="p2d2_wfst_develop"
export P2D2_DE1_WFST_WORKSPACE="de1"
export P2D2_DE1_WFST_USERNAME="p2d2_wfst_de1"
export P2D2_DE2_WFST_WORKSPACE="de2"
export P2D2_DE2_WFST_USERNAME="p2d2_wfst_de2"
export P2D2_FV_WFST_WORKSPACE="fv"
export P2D2_FV_WFST_USERNAME="p2d2_wfst_fv"

cat > "$T/stubs/kubectl" <<'K'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *"get secret geoserver-geoserver"*"jsonpath"*"geoserver-user"*) printf 'admin' | base64 -w0; exit 0 ;;
  *"get secret geoserver-geoserver"*"jsonpath"*"geoserver-password"*) printf 'geoserverpass1234' | base64 -w0; exit 0 ;;
  *"get secret"*"jsonpath"*"DB_PASSWORD"*) printf 'dbpassword1234567890' | base64 -w0; exit 0 ;;
  *"get secret"*"jsonpath"*"password"*)
    if [ -n "${GS_KUBECTL_WFST_VALUE:-}" ]; then printf '%s' "$GS_KUBECTL_WFST_VALUE" | base64 -w0; fi
    exit 0 ;;
  *"get secret"*"jsonpath"*) exit 0 ;;
  *"get secret"*"-o json"*) printf '{}'; exit 0 ;;
  *"get secret"*"-o name"*)
    if [ "${GS_KUBECTL_SECRET_ERROR:-0}" = "1" ]; then exit 1; fi
    if [ "${GS_KUBECTL_SECRET_PRESENT:-0}" = "1" ]; then printf 'secret/x'; fi
    exit 0 ;;
  *"get secret"*) [ "${GS_KUBECTL_SECRET_PRESENT:-0}" = "1" ] && exit 0 || exit 1 ;;
  *"delete secret"*) exit 0 ;;
  *"apply"*) exit 0 ;;
  *) exit 0 ;;
esac
K
chmod +x "$T/stubs/kubectl"

cat > "$T/stubs/yq" <<'Y'
#!/usr/bin/env bash
case "$*" in
  *"--version"*) echo "yq (https://github.com/mikefarah/yq) version v4.44.3" ;;
  *) printf '%s' '{"workspace_settings":{"numDecimals":7,"charset":"UTF-8","contact":{"contactEmail":"test@example.org"},"onlineResource":"https://example.org"},"service":{"onlineResource":"https://example.org","wms":{"title":"WMS","abstract":"A"},"wfs":{"title":"WFS","abstract":"A","featureBounding":null},"maintainer":"M","fees":"F","accessConstraints":"C","keywords":["k"]},"layers":{"geo-containers":{"title":"T","abstract":"A"},"grabflure":{"title":"T"},"grabflure_versionen":{"title":"T"},"graeber":{"title":"T"},"graeber_versionen":{"title":"T"}},"stages":{"main":"Main","dev":"Dev","de1":"DE1","de2":"DE2","fv":"FV"}}' ;;
esac
Y
chmod +x "$T/stubs/yq"

cat > "$T/stubs/curl" <<'C'
#!/usr/bin/env bash
set -u
stdin="$(cat 2>/dev/null || true)"
url=""; method="GET"; has_w=0; out_file="/dev/null"; prev=""
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    -X) prev="X" ;;
    -w) has_w=1 ;;
    -o) prev="o" ;;
    -I) : ;;
    *) case "$prev" in
         X) method="$a"; prev="" ;;
         o) out_file="$a"; prev="" ;;
       esac ;;
  esac
done
code="200"; body=""
case "$url" in
  *"/ows"*) case "$stdin" in *falsch_*) code=401 ;; *) code=200 ;; esac; body="" ;;
  *"/security/roles.json") body='{"roles":["ADMIN"]}' ;;
  *"/security/usergroup/users.json") body='{"users":[{"userName":"admin"}]}' ;;
  *"/security/roles/user/"*) body='{"roles":[]}' ;;
  *"/security/acl/layers"*) body='{}' ;;
  *"/workspaces.json") body='{"workspaces":{"workspace":[]}}' ;;
  *"/namespaces/"*) body='{"namespace":{"uri":"urn:x"}}' ;;
  *"/datastores/"*"/featuretypes.json?list=available"*) body='{"list":{"string":["p2d2_containers","v_grabflure_aktuell","p2d2_grabflure_versionen","v_graeber_aktuell","p2d2_graeber_versionen"]}}' ;;
  *"/datastores/"*"/featuretypes/"*) body='{"featureType":{"attributes":{"attribute":[{"name":"osm_name"}]}}}' ;;
  *"/datastores/"*"/featuretypes.json") body='{"featureTypes":""}' ;;
  *"/datastores.json")
    ws="$(printf '%s' "$url" | sed -E 's#.*/workspaces/([^/]+)/datastores.json.*#\1#')"
    body="{\"dataStores\":{\"dataStore\":[{\"name\":\"${ws}_pg\"}]}}"
    ;;
  *"/services/"*"/workspaces/"*)
    if [ "$method" = "GET" ]; then code=404; else code=200; body='{}'; fi ;;
  *"/workspaces/"*"/settings.json") body='{"settings":{"numDecimals":7,"charset":"UTF-8","onlineResource":"https://example.org","contact":{"contactEmail":"test@example.org"}}}' ;;
  *"/services/"*"/settings.json") body='{"wms":{"id":"wms"},"wfs":{"id":"wfs"}}' ;;
  *"/layers/"*) body='{"layer":{"attribution":null}}' ;;
  *) code=200; body='{}' ;;
esac
if [ "$out_file" != "/dev/null" ]; then printf '%s' "$body" > "$out_file"; fi
if [ "$has_w" = "1" ]; then printf '%s' "$code"; fi
C
chmod +x "$T/stubs/curl"

# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_03_secrets.sh"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_11_geoserver_config.sh"

# ── Szenario: Variablen-Leck (install/verify/uninstall) ─────────────────────
reset_wfst
before="$(compgen -v | sort)"
install_addon_geoserver_config >/dev/null 2>&1
verify_addon_geoserver_config >/dev/null 2>&1
uninstall_addon_geoserver_config >/dev/null 2>&1
after="$(compgen -v | sort)"
new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -vE '^(f|before|after|new|BASH_REMATCH|FAILS)$' || true)"
leak="$(printf '%s\n' "$new" | grep -vE '^P2D2_(MAIN|DEVELOP|DE1|DE2|FV)_WFST_PASSWORD$' || true)"
[ -z "$leak" ] || FAILS="$FAILS leak"

# ── e1: beide leer -> erzeugt -> gespiegelt ──────────────────────────────────
reset_wfst
envf="$(mktemp)"; printf 'P2D2_MAIN_WFST_PASSWORD=""   # Kommentar\n' > "$envf"; chmod 600 "$envf"
export ADDON_ENV_FILE="$envf"
install_addon_geoserver_config >/dev/null 2>&1
val="$(_p2d2_env_read "$envf" "P2D2_MAIN_WFST_PASSWORD")"
[ "${#val}" -ge 16 ] || FAILS="$FAILS e1_wert"
grep -q '# Kommentar' "$envf" || FAILS="$FAILS e1_kommentar"
[ "$(ls "$envf".bak* 2>/dev/null | wc -l)" -eq 1 ] || FAILS="$FAILS e1_bak"
[ "$(stat -c %a "$envf")" = "600" ] || FAILS="$FAILS e1_rechte"
rm -f "$envf" "$envf".bak*

# ── e2: gesetzter gültiger Wert -> .env unverändert, kein .bak ───────────────
reset_wfst
GUELTIG20="aaaaaaaaaaaaaaaaaaaa"
envf="$(mktemp)"
for k in MAIN DEVELOP DE1 DE2 FV; do
  printf 'P2D2_%s_WFST_PASSWORD="%s"\n' "$k" "$GUELTIG20" >> "$envf"
  export "P2D2_${k}_WFST_PASSWORD=$GUELTIG20"
done
chmod 600 "$envf"; cp -p "$envf" "$envf.ref"
export ADDON_ENV_FILE="$envf"
_p2d2_env_backup_reset
install_addon_geoserver_config >/dev/null 2>&1
cmp -s "$envf" "$envf.ref" || FAILS="$FAILS e2_unveraendert"
[ ! -e "$envf.bak" ] || FAILS="$FAILS e2_bak"
rm -f "$envf" "$envf.ref" "$envf".bak*

# ── e3: .env leer, Secret mit gültigem Wert -> Wert in .env ──────────────────
reset_wfst
export GS_KUBECTL_WFST_VALUE="secretvalue123456"
envf="$(mktemp)"; printf 'P2D2_MAIN_WFST_PASSWORD=""\n' > "$envf"; chmod 600 "$envf"
export ADDON_ENV_FILE="$envf"
install_addon_geoserver_config >/dev/null 2>&1
val="$(_p2d2_env_read "$envf" "P2D2_MAIN_WFST_PASSWORD")"
[ "$val" = "secretvalue123456" ] || FAILS="$FAILS e3_wert"
rm -f "$envf" "$envf".bak*

# ── e4: ADDON_ENV_FILE zeigt auf nicht vorhandene Datei -> Exit 0 + Warnung ──
reset_wfst
export ADDON_ENV_FILE="/nonexistent/path/env.p2d2-addon"
out="$(install_addon_geoserver_config 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || FAILS="$FAILS e4_exit"
grep -q 'Env-Datei nicht vorhanden' <<< "$out" || FAILS="$FAILS e4_warn"

# ── e5: für p2d2_wfs_user entsteht keine .env-Zeile ──────────────────────────
reset_wfst
envf="$(mktemp)"; : > "$envf"; chmod 600 "$envf"
export ADDON_ENV_FILE="$envf"
install_addon_geoserver_config >/dev/null 2>&1
grep -q 'p2d2_wfs_user\|P2D2_RO_WFST_PASSWORD' "$envf" && FAILS="$FAILS e5_ro"
cnt="$(grep -cE 'P2D2_(MAIN|DEVELOP|DE1|DE2|FV)_WFST_PASSWORD=' "$envf")"
[ "$cnt" -eq 5 ] || FAILS="$FAILS e5_anzahl"
rm -f "$envf" "$envf".bak*

# ── e6: _p2d2_env_merge_from übernimmt WFST_PASSWORD in die Ziel-.env ────────
_p2d2_env_backup_reset
src="$(mktemp)"; dst="$(mktemp)"
printf 'P2D2_MAIN_WFST_PASSWORD="mergevalue12345"\n' > "$src"
: > "$dst"
_p2d2_env_merge_from "$src" "$dst" >/dev/null 2>&1
val="$(_p2d2_env_read "$dst" "P2D2_MAIN_WFST_PASSWORD")"
[ "$val" = "mergevalue12345" ] || FAILS="$FAILS e6_merge"
rm -f "$src" "$dst" "$dst".bak*

# ── Auflage 9: Uninstall mit Rest (Secret + Datastore bleiben) ────────────────
reset_wfst
export GS_KUBECTL_SECRET_PRESENT="1"
export GS_CURL_DS_REST="main"
vor="$(compgen -v | sort)"
out="$(uninstall_addon_geoserver_config 2>&1)"; rc=$?
nach="$(compgen -v | sort)"
[ "$rc" -eq 1 ] || FAILS="$FAILS rest_exit"
grep -q 'Secret p2d2-geoserver-wfst-main noch vorhanden' <<< "$out" || FAILS="$FAILS rest_secret"
grep -q 'Datastore main_pg noch vorhanden' <<< "$out" || FAILS="$FAILS rest_datastore"
neu="$(comm -13 <(printf '%s\n' "$vor") <(printf '%s\n' "$nach") | grep -vE '^(P2D2_(MAIN|DEVELOP|DE1|DE2|FV)_WFST_PASSWORD|BASH_REMATCH|vor|nach|neu|out|rc|FAILS|GS_KUBECTL_SECRET_PRESENT|GS_CURL_DS_REST)$' || true)"
[ -z "$neu" ] || FAILS="$FAILS rest_leak"

# ── Pflichtkorrektur Turn 14: get-Fehler ist nicht "nicht vorhanden" ──────────
reset_wfst
export GS_KUBECTL_SECRET_ERROR="1"
out="$(uninstall_addon_geoserver_config 2>&1)"; rc=$?
[ "$rc" -eq 1 ] || FAILS="$FAILS rbac_exit"
grep -q 'Secret p2d2-geoserver-wfst-main nicht prüfbar' <<< "$out" || FAILS="$FAILS rbac_msg"
grep -q 'Secret p2d2-geoserver-wfst-main nicht vorhanden' <<< "$out" && FAILS="$FAILS rbac_falsch"

rm -rf "$T"
[[ -z "$FAILS" ]] && echo OK || echo "FAIL: $FAILS"
RUNTIME
rc="$( bash "$T/runtime_gs.sh" "$REPO" )"
check "addon_11 Laufzeit (Leck/Env/Uninstall-Rest)" "OK" "$rc"

rm -rf "$T"

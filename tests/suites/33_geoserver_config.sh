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
export KUBECTL_LOG="$T/kubectl.log"

# Stub-Verzeichnis voranstellen (überschreibt die globalen tests/stubs/*).
STUBS="$T/stubs"
mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

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

if [ -n "$body_file" ] && [ -f "$body_file" ]; then
  { printf 'URL=%s METHOD=%s\n' "$url" "$method"; cat "$body_file"; printf '\n---\n'; } >> "${CURL_BODY_LOG:?}"
fi

S="${GS_STATE_DIR:?}"
has_role() { grep -qx "$1" "$S/roles.list" 2>/dev/null; }
has_user() { grep -qx "$1" "$S/users.list" 2>/dev/null; }

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

code="200"; body=""
case "$url" in
  *"/ows"*)
    if [ "${GS_NEG200:-0}" = "1" ]; then code=200
    else case "$stdin_data" in *falsch_*) code=401 ;; *) code=200 ;; esac
    fi ;;
  *"/security/roles.json")
    [ "${GS_PREFLIGHT_FAIL:-0}" = "1" ] && code=500
    body="$(roles_json)" ;;
  *"/security/usergroup/users.json")
    if [ -n "${GS_USERS_FAIL_ON:-}" ]; then
      c=0; [ -f "$S/users_get_count" ] && c="$(cat "$S/users_get_count")"
      c=$((c+1)); printf '%s' "$c" > "$S/users_get_count"
      [ "$c" -ge "$GS_USERS_FAIL_ON" ] && code=500
    fi
    [ "${GS_USERS_500:-0}" = "1" ] && code=500
    if [ "${GS_USERS_EMPTY:-0}" = "1" ]; then body='{"users":[]}'
    else body="$(users_json)"; fi ;;
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

# ── Helfer ─────────────────────────────────────────────────────────────────────
clear_logs() { : > "$CURL_LOG"; : > "$CURL_BODY_LOG"; : > "$KUBECTL_LOG"; }

reset_state() {
  rm -rf "$GS_STATE_DIR" "$KUBE_STATE_DIR"
  mkdir -p "$GS_STATE_DIR/userroles" "$KUBE_STATE_DIR/secrets"
  printf '%s\n' admin > "$GS_STATE_DIR/users.list"
  printf '%s\n' ADMIN > "$GS_STATE_DIR/roles.list"
  clear_logs
  unset GS_OFF GS_NEG200 GS_PREFLIGHT_FAIL GS_DELETE_FAIL GS_USERS_500 GS_USERS_EMPTY GS_USERS_FAIL_ON KUBECTL_NO_NS KUBECTL_APPLY_FAIL 2>/dev/null || true
}

run_script() { run_script_in "$WORK" "$@"; }

run_script_in() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$SCRIPT" "$@" >"$T/out.log" 2>"$T/err.log" )
  printf '%s' "$?"
}

count_lines()  { awk 'END{print NR}' "$1" 2>/dev/null || printf '0'; }
count_secrets(){ find "$KUBE_STATE_DIR/secrets" -maxdepth 1 -name '*.b64' -type f 2>/dev/null | awk 'END{print NR}'; }
latest_howto() { ls -t "$WORK"/p2d2-geoserver-config_v1_*.howto.md 2>/dev/null | head -1; }

seed_secret() { # <name> <b64>
  mkdir -p "$KUBE_STATE_DIR/secrets"
  printf '%s' "$2" > "$KUBE_STATE_DIR/secrets/$1.b64"
}

NS="cc-prd-geodata-stack"
URL="https://geo.example/geoserver"
PASS_VALID="abcdefghijklmnop123456"
PASS_VALID_B64="YWJjZGVmZ2hpamtsbW5vcDEyMzQ1Ng=="
PASS_INVALID_B64="a3Vyeg=="   # base64("kurz")

# ═══════════════════════════════════════════════════════════════════════════════
# (1) Erstlauf legt sechs Secrets + sechs Benutzer an
# ═══════════════════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════════════
# (25) How-To Dry-Run: Modus geplant
# ═══════════════════════════════════════════════════════════════════════════
reset_state
run_script --dry-run --url "$URL" --ns "$NS" >/dev/null 2>&1
howto_file="$(latest_howto)"
check "How-To Dry-Run geplant" "yes" "$(grep -q 'Modus: dry-run (geplant)' "$howto_file" && echo yes || echo no)"

rm -rf "$T"

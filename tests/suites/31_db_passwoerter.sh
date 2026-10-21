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

# ── D5 umask bleibt unverändert ───────────────────────────────────────────────
u0="$(umask)"
_p2d2_secret_apply ns p2d2-x-secret "DB_PASSWORD=abcdefghijklmnop" >/dev/null 2>&1
check "D5 umask unverändert" "$u0" "$(umask)"

rm -rf "$T"

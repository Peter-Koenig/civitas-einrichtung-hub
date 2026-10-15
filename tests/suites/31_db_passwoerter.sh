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

rm -rf "$T"

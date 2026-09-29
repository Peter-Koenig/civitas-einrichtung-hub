#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# verify-p2d2-schema-dumps.sh
#
# Rein statische, nicht-produktive Pruefung, ob das schema-parametrisierte DDL-Template
#   supplement/templates/p2d2-postgresql/schema.sql.j2
# mit den fuenf Stage-Dumps unter supplement/db-dumps/<STAGE>.sql zusammenpasst.
#
# Prueft je Stage:
#   1. Rendering (sed, wie im Installer) ohne verbleibende {{ }}-Platzhalter.
#   2. Jede vom Dump referenzierte Tabelle ist im gerenderten Template vorhanden
#      (und umgekehrt) — statischer Struktur-Nachweis.
#   3. DE1/rheinkassel_gf wird explizit ausgewertet.
#
# Runtime-Test (SQL-Apply gegen eine echte PostgreSQL-Instanz) wird NICHT behauptet:
# dieses Skript prueft nur statisch. Ein echter Apply-Test erfordert eine lokale
# PostgreSQL-/Container-Instanz (auf sdt nicht vorhanden); der ausstehende
# Runtime-Test wird am Ende exakt benannt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/p2d2-postgresql/schema.sql.j2"
DUMP_DIR="${SCRIPT_DIR}/db-dumps"
STAGES=(MAIN DEVELOP DE1 DE2 FV)
SCHEMAS=(p2d2_main p2d2_develop p2d2_de1 p2d2_de2 p2d2_fv)

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILED=1; }

log "=== verify-p2d2-schema-dumps.sh (statisch) ==="

[[ -f "$TEMPLATE" ]] || { echo "FEHLER: Template fehlt: $TEMPLATE" >&2; exit 1; }

# Voraussetzung fuer einen echten Runtime-Test feststellen.
RUNTIME_AVAILABLE=0
if command -v pg_isready >/dev/null 2>&1 && pg_isready -q 2>/dev/null; then
  RUNTIME_AVAILABLE=1
fi
if command -v initdb >/dev/null 2>&1; then
  RUNTIME_AVAILABLE=1
fi

FAILED=0

for i in "${!STAGES[@]}"; do
  stage="${STAGES[$i]}"
  schema="${SCHEMAS[$i]}"
  dump="${DUMP_DIR}/${stage}.sql"
  log "Stage ${stage} (${schema})"

  [[ -s "$dump" ]] || { fail "Dump fehlt/leer: ${dump}"; continue; }

  rendered="$(mktemp)"
  sed -e "s/{{ p2d2_instance_schema }}/${schema}/g" \
      -e "s/{{ p2d2_admin_role }}/P2D2-Admin-Role/g" \
      "$TEMPLATE" > "$rendered"

  # 1) keine verbleibenden Platzhalter
  if grep -q '{{' "$rendered"; then
    fail "verbleibende {{ }}-Platzhalter im gerenderten Template"
  else
    ok "Rendering ohne Platzhalterreste"
  fi

  # 2) Tabellen: Dump vs. Template
  dump_tables="$(grep -oE "COPY ${schema}\.\"[a-zA-Z0-9_]+\" FROM stdin" "$dump" \
    | sed -E "s/COPY ${schema}\.\"([a-zA-Z0-9_]+)\" FROM stdin/\1/" | sort -u)"
  tpl_tables="$(grep -oE 'CREATE (UNLOGGED )?TABLE IF NOT EXISTS \{\{ p2d2_instance_schema \}\}\.[a-zA-Z0-9_]+' "$TEMPLATE" \
    | sed -E 's/.*\.([a-zA-Z0-9_]+)$/\1/' | sort -u)"

  missing_in_tpl=""
  for t in $dump_tables; do
    grep -qx "$t" <<<"$tpl_tables" || missing_in_tpl="$missing_in_tpl $t"
  done
  missing_in_dump=""
  for t in $tpl_tables; do
    grep -qx "$t" <<<"$dump_tables" || missing_in_dump="$missing_in_dump $t"
  done

  [[ -z "$missing_in_tpl" ]] && ok "alle Dump-Tabellen im Template ($(wc -w <<<"$dump_tables") Tabellen)" \
    || fail "Dump-Tabellen fehlen im Template:$missing_in_tpl"
  [[ -z "$missing_in_dump" ]] && ok "alle Template-Tabellen im Dump" \
    || fail "Template-Tabellen ohne Dump:$missing_in_dump"

  rm -f "$rendered"
done

# 3) DE1/rheinkassel_gf explizit
log "DE1 / rheinkassel_gf"
if grep -qE 'COPY p2d2_de1\."(gt_pk_metadata|rheinkassel_gf)" FROM stdin' "${DUMP_DIR}/DE1.sql"; then
  fail "DE1.sql referenziert gt_pk_metadata/rheinkassel_gf (unerwartet)"
else
  ok "DE1.sql ohne gt_pk_metadata/rheinkassel_gf (bewusst ausgeschlossen)"
fi
if grep -qE 'CREATE (UNLOGGED )?TABLE IF NOT EXISTS \{\{ p2d2_instance_schema \}\}\.(gt_pk_metadata|rheinkassel_gf)' "$TEMPLATE"; then
  fail "Template enthaelt gt_pk_metadata/rheinkassel_gf als Tabelle"
else
  ok "Template ohne gt_pk_metadata/rheinkassel_gf als Tabelle (nur Header-Kommentar)"
fi

log "=== Ergebnis ==="
if [[ "$FAILED" -ne 0 ]]; then
  echo "STATISCH FEHLGESCHLAGEN (siehe oben)." >&2
  exit 1
fi

echo "Statische Pruefung bestanden (alle ${#STAGES[@]} Stages)."

if [[ "$RUNTIME_AVAILABLE" -eq 0 ]]; then
  cat <<EOF

RUNTIME-TEST AUSSTEHEND: auf sdt ist keine lokale PostgreSQL-/Container-Instanz
vorhanden (weder pg_isready/Server noch initdb/docker). Ein echter Apply-Test
(Rendern + psql -v ON_ERROR_STOP=1 gegen eine Wegwerf-DB) wurde daher NICHT
ausgefuehrt. Ausstehendes Kommando (nicht-produktiv, Wegwerf-DB, danach loeschen):

  # pro Stage, z. B. MAIN:
  sed -e 's/{{ p2d2_instance_schema }}/p2d2_main/g' \\
      -e 's/{{ p2d2_admin_role }}/P2D2-Admin-Role/g' \\
      supplement/templates/p2d2-postgresql/schema.sql.j2 \\
    | psql -v ON_ERROR_STOP=1 -d <wegwerf-db>
  # anschliessend Dump-Import gegen dieselbe Struktur pruefen (COPY-Textformat).
EOF
  exit 0
fi

echo "Lokale PostgreSQL-Instanz erkannt — Runtime-Test koennte ergaenzt werden (derzeit nicht implementiert)."
exit 0

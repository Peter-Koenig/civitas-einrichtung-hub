#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# verify-p2d2-schema-runtime.sh — echter Wegwerf-Apply-Test des p2d2-DDL-Templates
# plus MAIN.sql-Dump-Import gegen eine isolierte, eindeutig benannte Wegwerf-Datenbank.
#
# Bewusst getrennt vom Statiktest (verify-p2d2-schema-dumps.sh) und NICHT Teil des
# regulären Installers. Der Test legt eine temporäre Datenbank an, befüllt sie und
# löscht sie in JEDEM Fall wieder (auch bei Fehler) — keine produktiven Daten.
#
# Ablauf:
#   1. Statische Ordnungsprüfung (ohne DB): alle PRIMARY KEY/UNIQUE vor allen
#      FOREIGN KEY; jede FK referenziert eine vorhandene PK/UNIQUE-Voraussetzung.
#   2. Runtime (nur bei verfügbarer, nicht-produktiver PostgreSQL-Instanz):
#      Render p2d2_main → CREATE EXTENSION postgis → CREATE ROLE P2D2-Admin-Role
#      → Apply DDL (psql -v ON_ERROR_STOP=1) → Import MAIN.sql → objektive
#      Prüfungen → Drop der Wegwerf-DB (und der Rolle).
#
# Laufzeit ermitteln (Priorität):
#   a) P2D2_TEST_ADMIN_DSN           (expliziter, schreibender Admin-Zugang)
#   b) lokale laufende Instanz       (pg_isready auf 127.0.0.1:5432)
#   c) initdb/postgres/pg_ctl        (temporärer, lokaler Wegwerf-Cluster)
#   d) docker/podman                 (temporärer postgis/postgis-Container)
# Sonst: fail-fast mit dokumentierter Voraussetzung — KEINE Behauptung
# "Runtime-Test bestanden".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/templates/p2d2-postgresql/schema.sql.j2"
DUMP="${SCRIPT_DIR}/db-dumps/MAIN.sql"
SCHEMA="p2d2_main"
ROLE="P2D2-Admin-Role"

# Erwartete Objektzahlen (1:1 zum DDL-Template; siehe p2d2-extract-db-schema.py).
EXPECTED_TABLES=14
EXPECTED_PK=14
EXPECTED_UNIQUE=9
EXPECTED_FK=16
EXPECTED_SEQUENCES=7
EXPECTED_VIEWS=2
EXPECTED_FUNCTIONS=3
EXPECTED_TRIGGERS=2

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; FAILED=1; }
FAILED=0

[[ -f "$TEMPLATE" ]] || { echo "FEHLER: Template fehlt: $TEMPLATE" >&2; exit 1; }
[[ -s "$DUMP" ]]     || { echo "FEHLER: Dump fehlt/leer: $DUMP" >&2; exit 1; }

log "=== verify-p2d2-schema-runtime.sh (statisch + Wegwerf-Apply) ==="

# Rendern exakt wie der Installer (sed, zwei Platzhalter).
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed -e "s/{{ p2d2_instance_schema }}/${SCHEMA}/g" \
    -e "s/{{ p2d2_admin_role }}/${ROLE}/g" \
    "$TEMPLATE" > "$RENDERED"

if grep -q '{{' "$RENDERED"; then
  fail "verbleibende {{ }}-Platzhalter im gerenderten Template"
fi

# ---------------------------------------------------------------------------
# 1) Statische Ordnungs-/Vollständigkeitsprüfung der Constraints (Python, ohne DB)
# ---------------------------------------------------------------------------
log "1) Statische Constraint-Ordnungs-/Referenzpruefung"
python3 - "$RENDERED" <<'PY'
import re, sys
sql = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r'ALTER TABLE ONLY \S+\.(\w+)\s*\n\s*ADD CONSTRAINT (\w+) (.+?);', sql, re.S)
if not blocks:
    print("  ✗ keine ADD CONSTRAINT-Blöcke gefunden")
    sys.exit(1)

def cols(s):
    m = re.search(r'\(([^)]*)\)', s)
    return frozenset(x.strip().strip('"') for x in m.group(1).split(',')) if m else frozenset()

pks, uniques = {}, {}
fks = []
for table, name, definition in blocks:
    if 'PRIMARY KEY' in definition:
        pks.setdefault(table, set()).add(cols(definition))
    elif re.search(r'\bUNIQUE\b', definition):
        uniques.setdefault(table, []).append(cols(definition))
    elif 'FOREIGN KEY' in definition:
        m = re.search(r'REFERENCES\s+(?:\S+\.)?(\w+)\s*\(([^)]*)\)', definition)
        ref_table = m.group(1) if m else None
        ref_cols = frozenset(x.strip().strip('"') for x in m.group(2).split(',')) if m else frozenset()
        fks.append((table, name, ref_table, ref_cols))

# Ordnung: alle PK/UNIQUE vor allen FK (Blockreihenfolge).
fk_start = next((i for i, b in enumerate(blocks) if 'FOREIGN KEY' in b[2]), len(blocks))
bad_order = [b[1] for b in blocks[fk_start:] if ('PRIMARY KEY' in b[2] or re.search(r'\bUNIQUE\b', b[2]))]
if bad_order:
    print(f"  ✗ PK/UNIQUE NACH FK einsortiert: {', '.join(bad_order)}")
    sys.exit(1)

# Vollstaendigkeit: jede FK referenziert eine vorhandene PK/UNIQUE (exakte Spaltenmenge).
missing = []
for table, name, ref_table, ref_cols in fks:
    ok = False
    if ref_table in pks and ref_cols in pks[ref_table]:
        ok = True
    if ref_table in uniques and any(ref_cols == u for u in uniques[ref_table]):
        ok = True
    if not ok:
        missing.append(f"{name}->{ref_table}({','.join(sorted(ref_cols))})")
if missing:
    print(f"  ✗ FK ohne PK/UNIQUE-Voraussetzung: {', '.join(missing)}")
    sys.exit(1)

print(f"  ✓ {len(pks)} PK / {sum(len(v) for v in uniques.values())} UNIQUE vor {len(fks)} FK; alle FK-Referenzen abgedeckt")
PY
if [[ "$FAILED" -ne 0 ]]; then
  echo "STATISCHE PRÜFUNG FEHLGESCHLAGEN." >&2
  exit 1
fi
ok "statische Ordnungs-/Referenzpruefung bestanden"

# ---------------------------------------------------------------------------
# 2) Laufzeit ermitteln
# ---------------------------------------------------------------------------
log "2) Laufzeit fuer Wegwerf-Apply ermitteln"
PSQL_ADMIN=()   # psql-Aufruf mit Rechten zum CREATE/DROP DATABASE
MODE=""

if [[ -n "${P2D2_TEST_ADMIN_DSN:-}" ]]; then
  MODE="dsn"
  PSQL_ADMIN=(psql -X -v ON_ERROR_STOP=1 "${P2D2_TEST_ADMIN_DSN}")
elif command -v pg_isready >/dev/null 2>&1 && pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then
  MODE="local-server"
  PSQL_ADMIN=(psql -X -v ON_ERROR_STOP=1)
elif command -v initdb >/dev/null 2>&1 && command -v postgres >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
  MODE="temp-cluster"
  PGDATA="$(mktemp -d)"
  initdb -D "$PGDATA" --auth=trust -U postgres >/dev/null 2>&1
  pg_ctl -D "$PGDATA" -o "-k $PGDATA -p 55432 -F" -l "$PGDATA/log" start >/dev/null 2>&1
  PSQL_ADMIN=(psql -X -v ON_ERROR_STOP=1 -h "$PGDATA" -p 55432 -U postgres)
elif command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
  MODE="container"
  RUNTIME="$(command -v podman || command -v docker)"
  CNAME="p2d2-runtime-test-$$-$RANDOM"
  "$RUNTIME" run -d --rm --name "$CNAME" -e POSTGRES_PASSWORD=postgres -e POSTGRES_USER=postgres postgis/postgis:16-3.4 >/dev/null 2>&1
  PSQL_ADMIN=(psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres)
  PGPASSWORD=postgres
  export PGPASSWORD
else
  MODE="none"
fi

if [[ "$MODE" == "none" ]]; then
  cat <<'EOF'
RUNTIME-TEST NICHT AUSGEFUEHRT: keine nicht-produktive, schreibende PostgreSQL-
Instanz verfuegbar. Es ist weder eine lokale laufende Instanz (pg_isready) noch
initdb/postgres/pg_ctl noch docker/podman vorhanden; ein expliziter Admin-Zugang
kann per P2D2_TEST_ADMIN_DSN gesetzt werden. Die statische Pruefung ist bestanden,
ein echter Apply-Test wurde aber NICHT behauptet.

Voraussetzung fuer den echten Lauf (eine der folgenden, mit postgis verfuegbar):
  - P2D2_TEST_ADMIN_DSN="postgresql://<admin>:<pw>@<host>:<port>/postgres" ./verify-p2d2-schema-runtime.sh
  - lokale PostgreSQL-Instanz mit postgis
  - initdb/postgres/pg_ctl (PostgreSQL-Serverpaket inkl. postgis) lokal installiert
  - docker/podman mit Image postgis/postgis
EOF
  exit 0
fi

log "   Modus: ${MODE}"

# ---------------------------------------------------------------------------
# 3) Wegwerf-Apply + Import + Pruefung + Cleanup
# ---------------------------------------------------------------------------
DBNAME="p2d2_runtime_test_$$_$(date +%s)"
ROLE_NAME="${ROLE}"

cleanup() {
  local db="$1"
  # DB ggf. noch vorhanden -> force-drop; Rolle ggf. entfernen.
  "${PSQL_ADMIN[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE);" >/dev/null 2>&1 || true
  "${PSQL_ADMIN[@]}" -d postgres -c "DROP ROLE IF EXISTS \"${ROLE_NAME}\";" >/dev/null 2>&1 || true
  case "$MODE" in
    temp-cluster) pg_ctl -D "$PGDATA" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$PGDATA" || true ;;
    container)    "$RUNTIME" stop "$CNAME" >/dev/null 2>&1 || true ;;
  esac
}

log "3) Wegwerf-DB '${DBNAME}' anlegen + Apply + Import"
trap 'cleanup "$DBNAME"; rm -f "$RENDERED"' EXIT

"${PSQL_ADMIN[@]}" -d postgres -c "CREATE DATABASE \"${DBNAME}\";"
"${PSQL_ADMIN[@]}" -d "$DBNAME" -c "CREATE ROLE \"${ROLE_NAME}\" NOLOGIN;"
"${PSQL_ADMIN[@]}" -d "$DBNAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;"

# DDL anwenden (ON_ERROR_STOP=1).
"${PSQL_ADMIN[@]}" -d "$DBNAME" < "$RENDERED"

# Dump-Import exakt wie der Installer (session_replication_role=replica + setval-Resync).
{
  echo "SET session_replication_role = replica;"
  cat "$DUMP"
  echo "SELECT setval('${SCHEMA}.p2d2_grabflur_mapping_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.p2d2_grabflur_mapping));"
  echo "SELECT setval('${SCHEMA}.p2d2_kommunen_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.p2d2_kommunen));"
  echo "SELECT setval('${SCHEMA}.wf_feature_status_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.wf_feature_status));"
  echo "SELECT setval('${SCHEMA}.wf_protokoll_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.wf_protokoll));"
  echo "SELECT setval('${SCHEMA}.wf_qs_maengel_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.wf_qs_maengel));"
  echo "SELECT setval('${SCHEMA}.wf_sessions_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.wf_sessions));"
  echo "SELECT setval('${SCHEMA}.wf_snapshots_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${SCHEMA}.wf_snapshots));"
  echo "SET session_replication_role = origin;"
} | "${PSQL_ADMIN[@]}" -d "$DBNAME"

# Objektive Prüfungen.
check_count() {
  local label="$1" expected="$2" got="$3"
  if [[ "$got" == "$expected" ]]; then ok "$label = $expected"; else fail "$label = $got (erwartet $expected)"; fi
}

q() { "${PSQL_ADMIN[@]}" -At -d "$DBNAME" -c "$1"; }

check_count "Tabellen"      "$EXPECTED_TABLES"   "$(q "SELECT count(*) FROM pg_tables WHERE schemaname='${SCHEMA}';")"
check_count "Primary Keys"  "$EXPECTED_PK"       "$(q "SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='${SCHEMA}' AND c.contype='p';")"
check_count "Unique"        "$EXPECTED_UNIQUE"   "$(q "SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='${SCHEMA}' AND c.contype='u';")"
check_count "Foreign Keys"  "$EXPECTED_FK"       "$(q "SELECT count(*) FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='${SCHEMA}' AND c.contype='f';")"
check_count "Sequenzen"     "$EXPECTED_SEQUENCES" "$(q "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='S';")"
check_count "Views"         "$EXPECTED_VIEWS"    "$(q "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='v';")"
check_count "Funktionen"    "$EXPECTED_FUNCTIONS" "$(q "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='${SCHEMA}';")"
check_count "Trigger"       "$EXPECTED_TRIGGERS" "$(q "SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND NOT t.tgisinternal;")"

kommunen_rows="$(q "SELECT count(*) FROM ${SCHEMA}.p2d2_kommunen;")"
if [[ "$kommunen_rows" -gt 0 ]]; then ok "Dump-Import: p2d2_kommunen mit ${kommunen_rows} Zeilen"; else fail "Dump-Import: p2d2_kommunen leer"; fi

# Cleanup (immer, auch bei Fehler).
cleanup "$DBNAME"

if [[ "$FAILED" -ne 0 ]]; then
  echo "RUNTIME-TEST FEHLGESCHLAGEN (siehe oben)." >&2
  exit 1
fi
echo "RUNTIME-TEST BESTANDEN (Wegwerf-DB '${DBNAME}' wieder geloescht)."
exit 0

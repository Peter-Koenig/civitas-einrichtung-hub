#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_00_postgresql.sh — p2d2-AddOn: PostgreSQL-Baustein
#
# Schritt 1 (dieser Stand): gemeinsame Rollen + je Stage
#   Rollen (P2D2-User-<B>, P2D2-<B>) -> Schema (Owner P2D2-Admin-Role)
#   -> DDL (schema.sql.j2) -> Grants + ALTER DEFAULT PRIVILEGES
#   -> optionaler Dump-Import (supplement/db-dumps/<STAGE>.sql).
#   Idempotent: Rollen/Schema via Existenz-Guards, Mitgliedschaft via
#   separatem idempotentem GRANT (nicht nur IN ROLE im CREATE-Guard — sonst
#   geht die Mitgliedschaft verloren, wenn die Rolle bereits existiert),
#   DDL nur bei leerem Schema (die CONSTRAINT-Sektion des Templates nutzt
#   DROP+ADD und ist nicht wiederholbar — PK wird von FK referenziert),
#   Dump-Import nur bei leerem Ziel (keine Duplikate).
#
# Offen (separate Turns): Minimal-Seed für den „kein Dump"-Fall,
#   Stage-Scope (`--stage=main|all`), Passwort-Rotation (Phase 2),
#   Schema-Migration (Template-Änderungen auf bereits initialisierte
#   Schemata anwenden — heute bewusst ausgeklammert).
#
# Ablauf extrahiert aus p2d2-civitas-addon/v1/tasks/p2d2-postgresql.yml bzw.
# postgresql.md (Manuell-Installation). Passwörter bleiben Platzhalter
# (`changeme-*`), die echte Rotation ist Phase 2.

# Fail-Fast: ohne ADDON_DB_NS sofort abbrechen (Modul nicht isoliert sourcen).
if [[ -z "${ADDON_DB_NS:-}" ]]; then
  echo "FEHLER: ADDON_DB_NS nicht gesetzt — addon_00_postgresql.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

install_addon_postgresql() {
  log "=== AddOn 00: PostgreSQL (Rollen/Schemata/DDL/Grants/Dump-Import) ==="

  local db_ns="${ADDON_DB_NS}"
  local db_name="p2d2"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"

  # Zalando-Superuser-Credentials (nur aus dem aktiven Secret lesen).
  local superuser superpass
  superuser="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.username}' | base64 -d)"
  superpass="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.password}' | base64 -d)"
  log "Superuser für ${db_name}: ${superuser}"

  # DDL-Template (zwei Jinja2-Platzhalter, per sed gerendert).
  local schema_template="${P2D2_SCHEMA_TEMPLATE:-/srv/p2d2/repos/p2d2-civitas-addon/v1/templates/p2d2-postgresql/schema.sql.j2}"
  # Dump-Ablage (Analogie zu supplement/geotiffs/, git-ignored).
  local dump_dir="${ADDON_SUPPLEMENT_DIR:-/srv/p2d2/repos/civitas_einrichtung/supplement}/db-dumps"

  if [[ ! -f "${schema_template}" ]]; then
    log_error "DDL-Template nicht gefunden: ${schema_template}"
    return 1
  fi

  local -a psql_pod
  psql_pod=(kubectl -n "$db_ns" exec -i central-db-0 -- psql -v ON_ERROR_STOP=1 -U "$superuser" -d "$db_name")

  # 1) Gemeinsame Rollen (einmalig, idempotent).
  log "  Gemeinsame Rollen (P2D2-Admin-Role/-Admin, P2D2-RO-Role/-RO)"
  "${psql_pod[@]}" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-Admin-Role') THEN
    CREATE ROLE "P2D2-Admin-Role" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-Admin') THEN
    CREATE ROLE "P2D2-Admin" LOGIN PASSWORD 'changeme-admin';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-RO-Role') THEN
    CREATE ROLE "P2D2-RO-Role" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-RO') THEN
    CREATE ROLE "P2D2-RO" LOGIN PASSWORD 'changeme-ro';
  END IF;
END
$$;
GRANT "P2D2-Admin-Role" TO "P2D2-Admin";
GRANT "P2D2-RO-Role" TO "P2D2-RO";
ALTER ROLE "P2D2-Admin" SET search_path = p2d2_main, public;
SQL

  # 2) Je Stage: Rollen + Schema + DDL + Grants + Dump-Import.
  local stage suffix schema
  for stage in MAIN DEVELOP DE1 DE2 FV; do
    case "$stage" in
      MAIN)    suffix="MAIN";    schema="p2d2_main" ;;
      DEVELOP) suffix="DEVELOP"; schema="p2d2_develop" ;;
      DE1)     suffix="DE1";     schema="p2d2_de1" ;;
      DE2)     suffix="DE2";     schema="p2d2_de2" ;;
      FV)      suffix="FV";      schema="p2d2_fv" ;;
    esac
    log "  Stage ${stage}: Schema ${schema}"

    # (a) Rollen + Schema (idempotent).
    "${psql_pod[@]}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-User-${suffix}') THEN
    CREATE ROLE "P2D2-User-${suffix}" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-${suffix}') THEN
    CREATE ROLE "P2D2-${suffix}" LOGIN PASSWORD 'changeme-${suffix}';
  END IF;
END
\$\$;
GRANT "P2D2-User-${suffix}" TO "P2D2-${suffix}";
ALTER ROLE "P2D2-${suffix}" SET search_path = ${schema}, public;
CREATE SCHEMA IF NOT EXISTS ${schema};
ALTER SCHEMA ${schema} OWNER TO "P2D2-Admin-Role";
SQL

    # (b) DDL rendern (sed) und einspielen — nur bei noch nicht initialisiertem
    #     Schema. Das Template ist für Tabellen/Sequenzen/Views/Funktionen
    #     idempotent (IF NOT EXISTS / OR REPLACE), aber seine CONSTRAINT-Sektion
    #     (DROP+ADD) scheitert beim Wiederholungslauf, weil der PK von den FKs
    #     referenziert wird. Daher wird die DDL strukturell nur einmalig
    #     angewendet; Schema-Migration ist eine separate Folgeaufgabe.
    local tbl_count
    tbl_count="$(kubectl -n "$db_ns" exec central-db-0 -- psql -At -U "$superuser" -d "$db_name" \
      -c "SELECT count(*) FROM pg_tables WHERE schemaname = '${schema}';" 2>/dev/null || true)"
    if [[ -n "${tbl_count}" && "${tbl_count}" != "0" ]]; then
      log "    DDL übersprungen (Schema ${schema} bereits initialisiert: ${tbl_count} Tabellen)."
    else
      sed -e "s/{{ p2d2_instance_schema }}/${schema}/g" \
          -e "s/{{ p2d2_admin_role }}/P2D2-Admin-Role/g" \
        "${schema_template}" \
        | "${psql_pod[@]}"
    fi

    # (c) Grants + ALTER DEFAULT PRIVILEGES (idempotent).
    "${psql_pod[@]}" <<SQL
GRANT USAGE ON SCHEMA ${schema} TO "P2D2-User-${suffix}";
GRANT USAGE ON SCHEMA ${schema} TO "P2D2-RO-Role";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ${schema} TO "P2D2-User-${suffix}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO "P2D2-User-${suffix}";
GRANT SELECT ON ALL TABLES IN SCHEMA ${schema} TO "P2D2-RO-Role";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA ${schema} TO "P2D2-Admin-Role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO "P2D2-Admin-Role";
ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA ${schema} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "P2D2-User-${suffix}";
ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA ${schema} GRANT USAGE, SELECT ON SEQUENCES TO "P2D2-User-${suffix}";
ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA ${schema} GRANT SELECT ON TABLES TO "P2D2-RO-Role";
ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA ${schema} GRANT ALL PRIVILEGES ON TABLES TO "P2D2-Admin-Role";
ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA ${schema} GRANT USAGE, SELECT ON SEQUENCES TO "P2D2-Admin-Role";
SQL

    # (d) Dump-Import, nur falls ein Dump vorhanden ist und das Ziel noch leer ist.
    local dump_file="${dump_dir}/${stage}.sql"
    if [[ ! -s "${dump_file}" ]]; then
      log "    Kein Dump vorhanden (${dump_file}) — Minimal-Seed folgt in separatem Turn."
      continue
    fi

    local row_count
    row_count="$(kubectl -n "$db_ns" exec central-db-0 -- psql -At -U "$superuser" -d "$db_name" -c "SELECT count(*) FROM ${schema}.p2d2_kommunen;" 2>/dev/null || true)"
    if [[ -n "${row_count}" && "${row_count}" != "0" ]]; then
      log_warn "    Schema ${schema} bereits befüllt (p2d2_kommunen: ${row_count} Zeilen) — Dump-Import übersprungen."
      continue
    fi

    log "    Dump-Import: ${dump_file}"
    {
      echo "SET session_replication_role = replica;"
      cat "${dump_file}"
      echo "SELECT setval('${schema}.p2d2_grabflur_mapping_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.p2d2_grabflur_mapping));"
      echo "SELECT setval('${schema}.p2d2_kommunen_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.p2d2_kommunen));"
      echo "SELECT setval('${schema}.wf_feature_status_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.wf_feature_status));"
      echo "SELECT setval('${schema}.wf_protokoll_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.wf_protokoll));"
      echo "SELECT setval('${schema}.wf_qs_maengel_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.wf_qs_maengel));"
      echo "SELECT setval('${schema}.wf_sessions_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.wf_sessions));"
      echo "SELECT setval('${schema}.wf_snapshots_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${schema}.wf_snapshots));"
      echo "SET session_replication_role = origin;"
    } | "${psql_pod[@]}"
  done

  log_ok "AddOn 00 PostgreSQL abgeschlossen (Schritt 1: DDL + Grants + Dump-Import)"
}

# uninstall_addon_postgresql — Rückbau (DROP SCHEMA + ROLE je Stage, umgekehrte Reihenfolge).
# Schützt den Superuser: nur die P2D2-*-Rollen werden entfernt, nie der Superuser selbst.
# Hinweis: entfernt derzeit nur P2D2-<B> + Schema; die gemeinsamen Rollen
# (P2D2-Admin-Role/-Admin, P2D2-RO-Role/-RO) und P2D2-User-<B> bleiben offen
# (Folgeaufgabe, analog zur Minimal-Seed-/Stage-Scope-Lücke).
uninstall_addon_postgresql() {
  log "=== Uninstall AddOn 00: PostgreSQL (Schemata/Rollen entfernen) ==="

  local db_ns="${ADDON_DB_NS}"
  local db_name="p2d2"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"
  local superuser
  superuser="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.username}' | base64 -d)"

  local stage role schema
  for stage in FV DE2 DE1 DEVELOP MAIN; do
    case "$stage" in
      MAIN)    role="P2D2-MAIN";    schema="p2d2_main" ;;
      DEVELOP) role="P2D2-DEVELOP"; schema="p2d2_develop" ;;
      DE1)     role="P2D2-DE1";     schema="p2d2_de1" ;;
      DE2)     role="P2D2-DE2";     schema="p2d2_de2" ;;
      FV)      role="P2D2-FV";      schema="p2d2_fv" ;;
    esac

    log "  Stage ${stage}: Schema ${schema} + Rolle ${role} entfernen"
    kubectl -n "$db_ns" exec central-db-0 -- \
      psql -v ON_ERROR_STOP=0 -U "$superuser" -d "$db_name" -c \
      "DROP SCHEMA IF EXISTS \"${schema}\" CASCADE;" || log_warn "    Schema ${schema} evtl. schon entfernt"
    kubectl -n "$db_ns" exec central-db-0 -- \
      psql -v ON_ERROR_STOP=0 -U "$superuser" -d "$db_name" -c \
      "DROP ROLE IF EXISTS \"${role}\";" || log_warn "    Rolle ${role} evtl. schon entfernt"
  done

  log_ok "Uninstall AddOn 00 PostgreSQL abgeschlossen"
}

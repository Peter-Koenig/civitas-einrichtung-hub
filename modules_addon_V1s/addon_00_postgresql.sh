#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_00_postgresql.sh — p2d2-AddOn: PostgreSQL-Baustein
#
# Schritt 1 (dieser Stand): gemeinsame Rollen + je Stage
#   Rollen (P2D2-User-<B>, P2D2-<B>) -> Schema (Owner P2D2-Admin-Role)
#   -> DDL (schema.sql.j2) -> Grants + ALTER DEFAULT PRIVILEGES
#   -> optionaler Dump-Import (supplement/db-dumps/<STAGE>.sql)
#   -> Cross-Schema-Lesezugriff: jede P2D2-User-<B>-Gruppe erhält SELECT
#      (+ USAGE) auf alle fünf Schemata (P2D2-User-Role ist Legacy, wird
#      nicht nachgebaut).
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

# ── Datenbank-Provisionierung über den Zalando-Postgres-Operator ────────────────
# Der Operator erzeugt/entfernt die Datenbank p2d2 deklarativ über das Feld
# spec.preparedDatabases.p2d2 im CR central-db. Das Shell-SQL-Modul erzeugt die DB
# NICHT per CREATE DATABASE; es bleibt für Inhalte (Rollen/Schemata/DDL/Dumps)
# zuständig. Diese Funktionen stellen den CR-Zustand idempotent her bzw. zurück.

# _pg_master_pod — bestimmt den laufenden Master-Pod des central-db-Clusters
# dynamisch (Label-basiert), Fallback auf den deterministischen central-db-0.
_pg_master_pod() {
  local db_ns="${ADDON_DB_NS}"
  local pod
  pod="$(kubectl -n "$db_ns" get pods -l application=spilo -l cluster-name=central-db \
    -l spilo-role=master --field-selector=status.phase=Running -o name 2>/dev/null \
    | head -1 | sed 's|pod/||')"
  [[ -n "$pod" ]] || pod="central-db-0"
  printf '%s' "$pod"
}

# ensure_p2d2_database — stellt spec.preparedDatabases.p2d2 idempotent sicher,
# wartet auf die Operator-Reconciliation und verifiziert die DB-Existenz.
ensure_p2d2_database() {
  local db_ns="${ADDON_DB_NS}"
  local cr="central-db"
  local target='{"defaultUsers":true,"extensions":{"postgis":"public"},"schemas":{"public":{"defaultRoles":false}}}'

  log "=== PostgreSQL-Datenbank p2d2 (Operator) sicherstellen ==="
  log "  kubeconfig: ${KUBECONFIG:-<default>}  Kontext: $(kubectl config current-context 2>/dev/null || echo '?')"

  # B.1: API-Zugriff, CR vorhanden, Rechte.
  if ! kubectl -n "$db_ns" get postgresql "$cr" >/dev/null 2>&1; then
    log_error "PostgreSQL-CR '${cr}' in ${db_ns} nicht gefunden/lesbar"
    return 1
  fi
  if ! kubectl auth can-i patch postgresqls.acid.zalan.do -n "$db_ns" >/dev/null 2>&1; then
    log_error "Keine patch-Berechtigung auf postgresqls.acid.zalan.do in ${db_ns}"
    return 1
  fi
  log_ok "Zugriff auf postgresql/${cr} in ${db_ns} vorhanden"

  # B.2: lesen -> abgleichen -> nur bei Bedarf (idempotent) patchen.
  local current cur_norm tgt_norm
  current="$(kubectl -n "$db_ns" get postgresql "$cr" -o jsonpath='{.spec.preparedDatabases.p2d2}' 2>/dev/null || true)"
  cur_norm=""; tgt_norm=""
  if command -v jq >/dev/null 2>&1; then
    cur_norm="$(printf '%s' "$current" | jq -cS . 2>/dev/null || true)"
    tgt_norm="$(printf '%s' "$target" | jq -cS . 2>/dev/null || true)"
  fi
  if [[ -n "$cur_norm" && -n "$tgt_norm" && "$cur_norm" == "$tgt_norm" ]]; then
    log_ok "preparedDatabases.p2d2 bereits vorhanden und äquivalent — kein Patch"
  elif [[ -n "$current" && -z "$cur_norm" ]]; then
    log_warn "preparedDatabases.p2d2 vorhanden, aber jq fehlt — überspringe Patch (Annahme: korrekt)"
  else
    log "  preparedDatabases.p2d2 setzen (additiv, merge)"
    kubectl -n "$db_ns" patch postgresql "$cr" --type merge \
      -p "{\"spec\":{\"preparedDatabases\":{\"p2d2\":${target}}}}" \
      || { log_error "Patch auf postgresql/${cr} fehlgeschlagen"; return 1; }
  fi

  # B.3: auf Reconciliation warten und DB-Existenz prüfen.
  local superuser db_pod waited step max_wait
  superuser="$(kubectl -n "$db_ns" get secret postgres.central-db.credentials.postgresql.acid.zalan.do \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo 'postgres')"
  db_pod="$(_pg_master_pod)"
  waited=0; step=5; max_wait="${ADDON_DB_WAIT_SECONDS:-300}"
  while [[ "$waited" -lt "$max_wait" ]]; do
    if kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='p2d2';" 2>/dev/null | grep -q 1; then
      log_ok "Datenbank p2d2 vorhanden (Operator-Reconciliation abgeschlossen)"
      return 0
    fi
    sleep "$step"
    waited=$((waited + step))
  done

  log_error "Timeout: Datenbank p2d2 nach ${max_wait}s nicht vorhanden"
  log "  Diagnose (CR/Events/Pods, ohne Secrets):"
  kubectl -n "$db_ns" get postgresql "$cr" -o jsonpath='{.spec.preparedDatabases}' 2>/dev/null | head -c 500; echo
  kubectl -n "$db_ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
  kubectl -n "$db_ns" get pods 2>/dev/null || true
  return 1
}

# remove_p2d2_database — entfernt spec.preparedDatabases.p2d2 gezielt (JSON Patch
# remove, idempotent) und wartet auf die Operator-Reconciliation.
remove_p2d2_database() {
  local db_ns="${ADDON_DB_NS}"
  local cr="central-db"

  log "=== PostgreSQL-Datenbank p2d2 (Operator) entfernen ==="

  if ! kubectl -n "$db_ns" get postgresql "$cr" >/dev/null 2>&1; then
    log_warn "PostgreSQL-CR '${cr}' nicht lesbar — überspringe preparedDatabases-Entfernung"
    return 0
  fi

  local current
  current="$(kubectl -n "$db_ns" get postgresql "$cr" -o jsonpath='{.spec.preparedDatabases.p2d2}' 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    log_ok "preparedDatabases.p2d2 bereits nicht vorhanden — idempotent, kein Patch"
    return 0
  fi

  log "  Entferne preparedDatabases.p2d2 (JSON Patch remove)"
  kubectl -n "$db_ns" patch postgresql "$cr" --type json \
    -p '[{"op":"remove","path":"/spec/preparedDatabases/p2d2"}]' \
    || { log_error "JSON-Patch remove auf /spec/preparedDatabases/p2d2 fehlgeschlagen"; return 1; }

  local superuser db_pod waited step max_wait
  superuser="$(kubectl -n "$db_ns" get secret postgres.central-db.credentials.postgresql.acid.zalan.do \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo 'postgres')"
  db_pod="$(_pg_master_pod)"
  waited=0; step=5; max_wait="${ADDON_DB_WAIT_SECONDS:-300}"
  while [[ "$waited" -lt "$max_wait" ]]; do
    if ! kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='p2d2';" 2>/dev/null | grep -q 1; then
      log_ok "Datenbank p2d2 entfernt (Operator-Reconciliation abgeschlossen)"
      return 0
    fi
    sleep "$step"
    waited=$((waited + step))
  done
  log_warn "Datenbank p2d2 nach ${max_wait}s weiterhin vorhanden — Operator-Semantik (DB-Löschung) prüfen"
  return 0
}

# _schema_state — objektiver Initialisierungszustand eines Schemas:
#   empty    = Schema enthält keine der erwarteten p2d2-Tabellen
#   complete = alle 14 erwarteten Tabellen UND die komplette Constraint-Sektion
#              (Nachweis ueber 16 Foreign Keys, den letzten Constraint-Block) vorhanden
#   partial  = Teilmenge vorhanden (z. B. Tabellen ohne Constraints nach einem
#              abgebrochenen DDL-Lauf)
# Grundlage ist die konkrete Tabellen-/Constraint-Menge, nicht allein count(pg_tables).
_schema_state() {
  local db_ns="$1" superuser="$2" db_name="$3" schema="$4"
  local -a expected=(
    p2d2_containers p2d2_graeber p2d2_graeber_snapshots p2d2_graeber_versionen
    p2d2_grabflur_mapping p2d2_grabflure p2d2_grabflure_snapshots p2d2_grabflure_versionen
    p2d2_kommunen wf_feature_status wf_protokoll wf_qs_maengel wf_sessions wf_snapshots
  )
  local present fk_count t missing
  present="$(kubectl -n "$db_ns" exec central-db-0 -- psql -At -U "$superuser" -d "$db_name" \
    -c "SELECT tablename FROM pg_tables WHERE schemaname='${schema}' ORDER BY tablename;" 2>/dev/null || true)"
  if [[ -z "$(printf '%s' "$present" | tr -d '[:space:]')" ]]; then
    echo "empty"; return 0
  fi
  missing=0
  for t in "${expected[@]}"; do
    grep -qx "$t" <<<"$present" || missing=$((missing + 1))
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "partial"; return 0
  fi
  # Alle 14 Tabellen vorhanden. Ob die Constraint-Sektion vollständig durchlief, wird
  # über die Foreign Keys geprüft (16 Stück, im Template der letzte Constraint-Block).
  fk_count="$(kubectl -n "$db_ns" exec central-db-0 -- psql -At -U "$superuser" -d "$db_name" \
    -c "SELECT count(*) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${schema}' AND con.contype='f';" 2>/dev/null || true)"
  if [[ "$fk_count" == "16" ]]; then
    echo "complete"
  else
    echo "partial"
  fi
}

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

  # Operator-verwaltete Datenbank p2d2 deklarativ sicherstellen (preparedDatabases.p2d2).
  ensure_p2d2_database || return 1

  # Supplement-Ablage (analog supplement/geotiffs/, git-ignored). Das DDL-Template
  # liegt jetzt self-contained im Supplement, nicht mehr im Fremd-Repo
  # p2d2-civitas-addon (nach VM-Restore nicht verfuegbar).
  local supplement_dir="${ADDON_SUPPLEMENT_DIR:-/srv/p2d2/repos/civitas_einrichtung/supplement}"
  # DDL-Template (zwei Jinja2-Platzhalter, per sed gerendert).
  local schema_template="${P2D2_SCHEMA_TEMPLATE:-${supplement_dir}/templates/p2d2-postgresql/schema.sql.j2}"
  # Dump-Ablage.
  local dump_dir="${supplement_dir}/db-dumps"
  # Manifest mit Prüfsummen (p2d2-db-artifacts.sha256).
  local manifest="${supplement_dir}/p2d2-db-artifacts.sha256"

  # Fail-Fast: Template, Manifest und alle fünf Dumps müssen vor jedem
  # Datenbankeingriff vorhanden und prüfsummenkonform sein.
  if [[ ! -f "${schema_template}" ]]; then
    log_error "DDL-Template nicht gefunden: ${schema_template}"
    return 1
  fi
  if [[ ! -f "${manifest}" ]]; then
    log_error "Manifest nicht gefunden: ${manifest}"
    return 1
  fi
  local d
  for d in MAIN DEVELOP DE1 DE2 FV; do
    if [[ ! -s "${dump_dir}/${d}.sql" ]]; then
      log_error "Dump fehlt/leer: ${dump_dir}/${d}.sql"
      return 1
    fi
  done
  if ! (cd "${supplement_dir}" && sha256sum --check --quiet "${manifest}" >/dev/null 2>&1); then
    log_error "Prüfsummen-Manifest fehlgeschlagen: ${manifest}"
    return 1
  fi

  local -a psql_pod
  psql_pod=(kubectl -n "$db_ns" exec -i central-db-0 -- psql -v ON_ERROR_STOP=1 -U "$superuser" -d "$db_name")

  # B.4: Verteidigung in der Tiefe — DB-Existenz vor der ersten SQL-Ausführung.
  if ! kubectl -n "$db_ns" exec "$(_pg_master_pod)" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${db_name}';" 2>/dev/null | grep -q 1; then
    log_error "Datenbank ${db_name} nicht vorhanden — Provisionierung fehlgeschlagen?"
    return 1
  fi

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

    # (b) DDL rendern (sed) und einspielen — nur auf einem leeren Schema.
    #     Das Template ist fuer Tabellen/Sequenzen/Views/Funktionen idempotent
    #     (IF NOT EXISTS / OR REPLACE), aber die CONSTRAINT-Sektion (ADD
    #     CONSTRAINT) ist nicht wiederholbar. Daher: leer -> anwenden,
    #     vollstaendig -> ueberspringen, partiell -> abbrechen (kein stilles
    #     Ueberspringen eines defekten Teilzustands).
    local state
    state="$(_schema_state "$db_ns" "$superuser" "$db_name" "$schema")"
    case "$state" in
      empty)
        sed -e "s/{{ p2d2_instance_schema }}/${schema}/g" \
            -e "s/{{ p2d2_admin_role }}/P2D2-Admin-Role/g" \
          "${schema_template}" \
          | "${psql_pod[@]}"
        ;;
      complete)
        log "    DDL uebersprungen (Schema ${schema} bereits vollstaendig initialisiert)."
        ;;
      partial)
        log_error "    Schema ${schema} ist partiell initialisiert — kein stiller Uebersprung. Bitte Cleanup/Uninstall (siehe ai-run) ausfuehren."
        return 1
        ;;
    esac

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

  # 3) Cross-Schema-Lesezugriff: jede P2D2-User-<STAGE>-Gruppenrolle erhält
  #    SELECT (+ USAGE auf Schema/Sequenzen) auf alle fünf Schemata, inkl.
  #    ALTER DEFAULT PRIVILEGES für künftige Objekte. P2D2-User-Role ist
  #    Legacy und wird bewusst NICHT nachgebaut.
  log "  Cross-Schema-Lesezugriff (jede P2D2-User-<STAGE> auf alle fünf Schemata)"
  local cr_suffix cr_schema
  {
    for cr_suffix in MAIN DEVELOP DE1 DE2 FV; do
      for cr_schema in p2d2_main p2d2_develop p2d2_de1 p2d2_de2 p2d2_fv; do
        printf 'GRANT USAGE ON SCHEMA %s TO "P2D2-User-%s";\n' "${cr_schema}" "${cr_suffix}"
        printf 'GRANT SELECT ON ALL TABLES IN SCHEMA %s TO "P2D2-User-%s";\n' "${cr_schema}" "${cr_suffix}"
        printf 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO "P2D2-User-%s";\n' "${cr_schema}" "${cr_suffix}"
        printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA %s GRANT SELECT ON TABLES TO "P2D2-User-%s";\n' "${cr_schema}" "${cr_suffix}"
        printf 'ALTER DEFAULT PRIVILEGES FOR ROLE "P2D2-Admin-Role" IN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO "P2D2-User-%s";\n' "${cr_schema}" "${cr_suffix}"
      done
    done
  } | "${psql_pod[@]}"

  log_ok "AddOn 00 PostgreSQL abgeschlossen (Schritt 1: DDL + Grants + Dump-Import + Cross-Schema-Read)"
}

# uninstall_addon_postgresql — vollständiger Rückbau aller von install_addon_postgresql
# angelegten Objekte (5 Schemata + 14 Rollen). Reihenfolge zweiphasig: erst alle
# Schemata (CASCADE entfernt Objekte, schema-gebundene Grants und ALTER DEFAULT
# PRIVILEGES mit), dann alle Rollen (erst Login-/Mitglied-Rollen, dann Gruppen-Rollen).
# DROP OWNED BY ist ein defensives Sicherheitsnetz gegen unvorhergesehene Reste.
# Schützt den Superuser und die Zalando-Rollen (p2d2_*): es werden nur P2D2-*-Rollen entfernt.
uninstall_addon_postgresql() {
  log "=== Uninstall AddOn 00: PostgreSQL (Schemata/Rollen entfernen) ==="

  local db_ns="${ADDON_DB_NS}"
  local db_name="p2d2"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"
  local superuser
  superuser="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.username}' | base64 -d)"

  # ON_ERROR_STOP=0: Uninstall muss auch bei Teil-Resten aus früheren Läufen robust laufen.
  local -a psql_u
  psql_u=(kubectl -n "$db_ns" exec central-db-0 -- psql -v ON_ERROR_STOP=0 -U "$superuser" -d "$db_name")

  # 1) Alle fünf Schemata zuerst (Cross-Schema-Grants aus Turn 9 erfordern, dass
  #    erst alle Schemata fallen, bevor Rollen droppbar sind).
  local stage schema
  for stage in FV DE2 DE1 DEVELOP MAIN; do
    case "$stage" in
      MAIN)    schema="p2d2_main" ;;
      DEVELOP) schema="p2d2_develop" ;;
      DE1)     schema="p2d2_de1" ;;
      DE2)     schema="p2d2_de2" ;;
      FV)      schema="p2d2_fv" ;;
    esac
    log "  Schema ${schema} entfernen"
    "${psql_u[@]}" -c "DROP SCHEMA IF EXISTS \"${schema}\" CASCADE;" || log_warn "    Schema ${schema} evtl. schon entfernt"
  done

  # 2) Rollen in abhängigkeitsfreier Reihenfolge: erst Login-Rollen (Mitglieder),
  #    dann Gruppen-Rollen, zuletzt die gemeinsamen Rollen.
  local role
  for role in \
      P2D2-MAIN P2D2-DEVELOP P2D2-DE1 P2D2-DE2 P2D2-FV \
      P2D2-User-MAIN P2D2-User-DEVELOP P2D2-User-DE1 P2D2-User-DE2 P2D2-User-FV \
      P2D2-Admin P2D2-RO \
      P2D2-Admin-Role P2D2-RO-Role; do
    log "  Rolle ${role} entfernen"
    "${psql_u[@]}" -c "DROP OWNED BY \"${role}\";" || log_warn "    DROP OWNED BY ${role} ohne Effekt"
    "${psql_u[@]}" -c "DROP ROLE IF EXISTS \"${role}\";" || log_warn "    Rolle ${role} evtl. schon entfernt"
  done

  # Operator-verwaltete Datenbank p2d2 deklarativ entfernen (preparedDatabases.p2d2).
  remove_p2d2_database || return 1

  log_ok "Uninstall AddOn 00 PostgreSQL abgeschlossen (5 Schemata + 14 Rollen + DB)"
}

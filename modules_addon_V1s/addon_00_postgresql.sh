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
#   Stage-Scope (`--stage=main|all`),
#   Schema-Migration (Template-Änderungen auf bereits initialisierte
#   Schemata anwenden — heute bewusst ausgeklammert).
#
# Ablauf extrahiert aus p2d2-civitas-addon/v1/tasks/p2d2-postgresql.yml bzw.
# postgresql.md (Manuell-Installation). Login-Rollen erhalten keine
# Klartext-Passwort-Literale: Werte werden aufgelöst (Umgebung -> Cluster-Secret
# -> zufällig erzeugt), im Cluster verwaltet und in der .env gespiegelt.

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

# _db_exists — prüft über die Maintenance-DB postgres, ob eine Datenbank existiert.
# Gibt "yes"/"no"/"error" auf stdout aus und liefert immer Exit 0 (set -e-sicher).
# "error" bedeutet Verbindungsfehler (kubectl/psql), "no" bedeutet sauber abgefragt
# und nicht vorhanden. Die Unterscheidung ist für den Uninstall relevant: ein
# Verbindungsfehler darf nicht als "schon entfernt" (falsch-grün) gewertet werden.
_db_exists() {
  local pod="$1" superuser="$2" db="$3" out
  if ! out="$(kubectl -n "${ADDON_DB_NS}" exec "$pod" -- psql -U "$superuser" -d postgres -tAc \
      "SELECT 1 FROM pg_database WHERE datname='${db}';" 2>/dev/null)"; then
    printf 'error'
    return 0
  fi
  if [[ "$(printf '%s' "$out" | tr -d '[:space:]')" == "1" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
  return 0
}

# _pg_first_err <text> — erste Zeile (auf 200 Zeichen gekürzt) aus stderr-Text.
# Verhindert, dass rohe psql-Fehler mit Verbindungsdaten ungekürzt ins Log laufen.
_pg_first_err() {
  printf '%s' "$1" | head -1 | cut -c1-200
}

# Gemeinsame Passwort-/Secret-Helfer (addon_03_secrets.sh): Auflösung, Erzeugung,
# Validierung, Secret-Merge, .env-Spiegel und Rückweg-Merge.
# shellcheck source=./addon_03_secrets.sh
source "$(dirname "${BASH_SOURCE[0]}")/addon_03_secrets.sh"

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

# remove_p2d2_database — entfernt spec.preparedDatabases.p2d2 (JSON Patch remove,
# idempotent), droppt die Datenbank p2d2 synchron und räumt die vom Zalando-
# Operator zusätzlich angelegten p2d2_*-Rollen/-Secrets ab. Der frühere
# 300-s-Wartebereich entfällt: DROP DATABASE ist synchron, die Verifikation liest
# den Zustand unmittelbar danach. Kein Wildcard-/LIKE-Muster, nur exakte Namen.
remove_p2d2_database() {
  local db_ns="${ADDON_DB_NS}"
  local cr="central-db"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"
  local superuser db_pod

  log "=== PostgreSQL-Datenbank p2d2 (Operator) entfernen ==="

  superuser="$(kubectl -n "$db_ns" get secret "$secret" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo 'postgres')"
  db_pod="$(_pg_master_pod)"

  # 1) preparedDatabases.p2d2 aus dem CR entfernen — MUSS vor dem Drop kommen,
  #    damit der Operator die Datenbank nicht wieder anlegt.
  local current
  if kubectl -n "$db_ns" get postgresql "$cr" >/dev/null 2>&1; then
    current="$(kubectl -n "$db_ns" get postgresql "$cr" \
      -o jsonpath='{.spec.preparedDatabases.p2d2}' 2>/dev/null || true)"
    if [[ -n "$current" ]]; then
      log "  Entferne preparedDatabases.p2d2 (JSON Patch remove)"
      if ! kubectl -n "$db_ns" patch postgresql "$cr" --type json \
        -p '[{"op":"remove","path":"/spec/preparedDatabases/p2d2"}]'; then
        log_error "JSON-Patch remove auf /spec/preparedDatabases/p2d2 fehlgeschlagen"
        return 1
      fi
      current="$(kubectl -n "$db_ns" get postgresql "$cr" \
        -o jsonpath='{.spec.preparedDatabases.p2d2}' 2>/dev/null || true)"
      if [[ -n "$current" ]]; then
        log_error "preparedDatabases.p2d2 nach Patch weiterhin vorhanden"
        return 1
      fi
      log_ok "preparedDatabases.p2d2 entfernt"
    else
      log_ok "preparedDatabases.p2d2 bereits nicht vorhanden"
    fi
  else
    log_warn "PostgreSQL-CR '${cr}' nicht lesbar — preparedDatabases-Entfernung übersprungen"
  fi

  # 2) Datenbank p2d2 droppen, falls vorhanden (synchron). PostgreSQL >= 13
  #    kann DROP DATABASE WITH (FORCE); ältere Versionen benötigen vorher
  #    pg_terminate_backend.
  local db_state ver err
  db_state="$(_db_exists "$db_pod" "$superuser" "p2d2")"
  if [[ "$db_state" == "yes" ]]; then
    ver="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
      'SHOW server_version_num;' 2>/dev/null | tr -d '[:space:]')" || true
    log "  Datenbank p2d2 droppen"
    if [[ "$ver" =~ ^[0-9]+$ ]] && [[ "$ver" -ge 130000 ]]; then
      if ! err="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres \
          -c 'DROP DATABASE p2d2 WITH (FORCE);' 2>&1 >/dev/null)"; then
        log_error "DROP DATABASE p2d2 fehlgeschlagen: $(_pg_first_err "${err}")"
        return 1
      fi
    else
      kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='p2d2';" >/dev/null 2>&1 || true
      if ! err="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres \
          -c 'DROP DATABASE p2d2;' 2>&1 >/dev/null)"; then
        log_error "DROP DATABASE p2d2 fehlgeschlagen: $(_pg_first_err "${err}")"
        return 1
      fi
    fi
    db_state="$(_db_exists "$db_pod" "$superuser" "p2d2")"
    if [[ "$db_state" == "yes" ]]; then
      log_error "Datenbank p2d2 nach DROP weiterhin vorhanden"
      return 1
    fi
    if [[ "$db_state" == "error" ]]; then
      log_error "Verifikation nicht möglich (Verbindungsfehler) — Datenbank p2d2 manuell prüfen"
      return 1
    fi
    log_ok "Datenbank p2d2 entfernt"
  elif [[ "$db_state" == "error" ]]; then
    log_error "PostgreSQL-Verbindung nicht möglich — Datenbank p2d2 nicht verifizierbar"
    return 1
  else
    log_ok "Datenbank p2d2 bereits nicht vorhanden"
  fi

  # 3) Operator-Rollen (exakte Liste, LOGIN-Rollen zuerst, dann NOLOGIN-Gruppen).
  local role
  for role in p2d2_owner_user p2d2_reader_user p2d2_writer_user p2d2_writer p2d2_reader p2d2_owner; do
    if ! err="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres \
        -c "DROP ROLE IF EXISTS \"${role}\";" 2>&1 >/dev/null)"; then
      log_error "DROP ROLE ${role} fehlgeschlagen: $(_pg_first_err "${err}")"
      return 1
    fi
  done

  # 4) Operator-Secrets (exakte Namen).
  local s
  for s in \
    p2d2-owner-user.central-db.credentials.postgresql.acid.zalan.do \
    p2d2-reader-user.central-db.credentials.postgresql.acid.zalan.do \
    p2d2-writer-user.central-db.credentials.postgresql.acid.zalan.do; do
    kubectl -n "$db_ns" delete secret "$s" --ignore-not-found >/dev/null 2>&1 || true
  done

  # 5) Verifikation: keine der sechs Rollen, keines der drei Secrets.
  local leftover
  leftover="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN ('p2d2_owner_user','p2d2_reader_user','p2d2_writer_user','p2d2_writer','p2d2_reader','p2d2_owner') ORDER BY rolname;" 2>/dev/null || true)"
  if [[ -n "$(printf '%s' "$leftover" | tr -d '[:space:]')" ]]; then
    log_error "Operator-Rollen weiterhin vorhanden: $(printf '%s' "$leftover" | tr '\n' ' ')"
    return 1
  fi
  for s in \
    p2d2-owner-user.central-db.credentials.postgresql.acid.zalan.do \
    p2d2-reader-user.central-db.credentials.postgresql.acid.zalan.do \
    p2d2-writer-user.central-db.credentials.postgresql.acid.zalan.do; do
    if kubectl -n "$db_ns" get secret "$s" >/dev/null 2>&1; then
      log_error "Secret ${s} weiterhin vorhanden"
      return 1
    fi
  done

  log_ok "PostgreSQL-Datenbank p2d2 + Operator-Rollen/-Secrets entfernt"
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

  # Passwortwerte aus der Umgebung vorab validieren (kein Teilzustand).
  _p2d2_pw_validate_env || return 1

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

  # 1) Gemeinsame Rollen (P2D2-Admin/-RO): Passwörter auflösen + konvergieren.
  log "  Gemeinsame Rollen (P2D2-Admin-Role/-Admin, P2D2-RO-Role/-RO)"
  local admin_pw ro_pw admin_secret="p2d2-db-admin-secret"
  admin_pw="$(_p2d2_pw_resolve "P2D2_ADMIN_DB_PASSWORD" "$db_ns" "$admin_secret" "admin")" || return 1
  ro_pw="$(_p2d2_pw_resolve "P2D2_RO_DB_PASSWORD" "$db_ns" "$admin_secret" "ro")" || return 1

  # Cluster-seitig ablegen (dediziertes Secret, nur diese beiden Keys).
  _p2d2_secret_apply "$db_ns" "$admin_secret" "admin=${admin_pw}" "ro=${ro_pw}" \
    || log_warn "Secret ${admin_secret} konnte nicht aktualisiert werden"

  "${psql_pod[@]}" <<SQL
SET log_statement = 'none';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-Admin-Role') THEN
    CREATE ROLE "P2D2-Admin-Role" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-Admin') THEN
    CREATE ROLE "P2D2-Admin" LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-RO-Role') THEN
    CREATE ROLE "P2D2-RO-Role" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-RO') THEN
    CREATE ROLE "P2D2-RO" LOGIN;
  END IF;
END
\$\$;
ALTER ROLE "P2D2-Admin" PASSWORD '${admin_pw}';
ALTER ROLE "P2D2-RO" PASSWORD '${ro_pw}';
GRANT "P2D2-Admin-Role" TO "P2D2-Admin";
GRANT "P2D2-RO-Role" TO "P2D2-RO";
ALTER ROLE "P2D2-Admin" SET search_path = p2d2_main, public;
SQL

  _p2d2_env_mirror "${ADDON_ENV_FILE}" "P2D2_ADMIN_DB_PASSWORD" "$admin_pw" || true
  _p2d2_env_mirror "${ADDON_ENV_FILE}" "P2D2_RO_DB_PASSWORD" "$ro_pw" || true

  # 2) Je Stage: Rollen + Schema + DDL + Grants + Dump-Import.
  local stage suffix schema fe_suffix secret_name pw_var stage_pw old_pw
  for stage in MAIN DEVELOP DE1 DE2 FV; do
    case "$stage" in
      MAIN)    suffix="MAIN";    schema="p2d2_main";    fe_suffix="main"   ;;
      DEVELOP) suffix="DEVELOP"; schema="p2d2_develop"; fe_suffix="dev"    ;;
      DE1)     suffix="DE1";     schema="p2d2_de1";     fe_suffix="f-de1"  ;;
      DE2)     suffix="DE2";     schema="p2d2_de2";     fe_suffix="f-de2"  ;;
      FV)      suffix="FV";      schema="p2d2_fv";      fe_suffix="f-fv"   ;;
    esac
    log "  Stage ${stage}: Schema ${schema}"

    # (a) Passwort auflösen (Umgebung -> Cluster-Secret -> erzeugt) + Rollen/Schema.
    secret_name="p2d2-${fe_suffix}-secret"
    pw_var="P2D2_${stage}_DB_PASSWORD"
    old_pw="$(_p2d2_secret_get "${ADDON_NS}" "$secret_name" "DB_PASSWORD")"
    stage_pw="$(_p2d2_pw_resolve "$pw_var" "${ADDON_NS}" "$secret_name" "DB_PASSWORD")" || return 1

    "${psql_pod[@]}" <<SQL
SET log_statement = 'none';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-User-${suffix}') THEN
    CREATE ROLE "P2D2-User-${suffix}" NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'P2D2-${suffix}') THEN
    CREATE ROLE "P2D2-${suffix}" LOGIN;
  END IF;
END
\$\$;
ALTER ROLE "P2D2-${suffix}" PASSWORD '${stage_pw}';
GRANT "P2D2-User-${suffix}" TO "P2D2-${suffix}";
ALTER ROLE "P2D2-${suffix}" SET search_path = ${schema}, public;
CREATE SCHEMA IF NOT EXISTS ${schema};
ALTER SCHEMA ${schema} OWNER TO "P2D2-Admin-Role";
SQL

    # (a2) Stage-Secret schreiben (nur DB_PASSWORD, andere Keys bleiben), dann
    #      .env spiegeln und Frontend-Deployment bei Änderung neu starten.
    if [[ -z "$old_pw" || "$old_pw" != "$stage_pw" ]]; then
      _p2d2_secret_apply "${ADDON_NS}" "$secret_name" "DB_PASSWORD=${stage_pw}" || log_warn "Secret ${secret_name} konnte nicht aktualisiert werden"
    fi
    _p2d2_env_mirror "${ADDON_ENV_FILE}" "$pw_var" "$stage_pw" || true
    if [[ -n "$old_pw" && "$old_pw" != "$stage_pw" ]] \
        && kubectl -n "${ADDON_NS}" get deployment "p2d2-${fe_suffix}" >/dev/null 2>&1; then
      kubectl -n "${ADDON_NS}" rollout restart "deployment/p2d2-${fe_suffix}" >/dev/null 2>&1 \
        || log_warn "Rollout-Restart p2d2-${fe_suffix} fehlgeschlagen"
    fi

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
# angelegten Objekte (5 Schemata + 14 Rollen + DB + Operator-Rollen/-Secrets).
# Robuste Reihenfolge: erst alle Schemata (CASCADE entfernt Objekte, schema-gebundene
# Grants und ALTER DEFAULT PRIVILEGES mit), dann alle P2D2-*-Rollen. DROP OWNED BY ist
# ein defensives Sicherheitsnetz gegen unvorhergesehene Reste. Fehlt die Datenbank,
# werden Schemata/DROP OWNED BY übersprungen, die Rollen aber trotzdem (über postgres)
# entfernt. "abgeschlossen" nur nach bestandener Verifikation, sonst return 1.
uninstall_addon_postgresql() {
  log "=== Uninstall AddOn 00: PostgreSQL (Schemata/Rollen entfernen) ==="

  local db_ns="${ADDON_DB_NS}"
  local db_name="p2d2"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"
  local superuser db_pod
  superuser="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo 'postgres')"
  db_pod="$(_pg_master_pod)"

  local db_state rc=0
  db_state="$(_db_exists "$db_pod" "$superuser" "$db_name")"

  # 1) Schemata + DROP OWNED BY nur, wenn die Datenbank existiert (defensiv, -d p2d2).
  #    Cross-Schema-Grants (Turn 9) erfordern, dass erst alle Schemata fallen.
  if [[ "$db_state" == "yes" ]]; then
    local -a psql_pod
    psql_pod=(kubectl -n "$db_ns" exec "$db_pod" -- psql -v ON_ERROR_STOP=0 -U "$superuser" -d "$db_name")
    local stage schema schema_err
    for stage in FV DE2 DE1 DEVELOP MAIN; do
      case "$stage" in
        MAIN)    schema="p2d2_main" ;;
        DEVELOP) schema="p2d2_develop" ;;
        DE1)     schema="p2d2_de1" ;;
        DE2)     schema="p2d2_de2" ;;
        FV)      schema="p2d2_fv" ;;
      esac
      log "  Schema ${schema} entfernen"
      if ! schema_err="$("${psql_pod[@]}" -c "DROP SCHEMA IF EXISTS \"${schema}\" CASCADE;" 2>&1 >/dev/null)"; then
        log_warn "    Schema ${schema} konnte nicht entfernt werden: $(_pg_first_err "${schema_err}")"
        rc=1
      fi
    done

    # Defensives Sicherheitsnetz gegen unvorhergesehene Objekt-Reste (nur -d p2d2).
    local role
    for role in \
        P2D2-MAIN P2D2-DEVELOP P2D2-DE1 P2D2-DE2 P2D2-FV \
        P2D2-User-MAIN P2D2-User-DEVELOP P2D2-User-DE1 P2D2-User-DE2 P2D2-User-FV \
        P2D2-Admin P2D2-RO \
        P2D2-Admin-Role P2D2-RO-Role; do
      "${psql_pod[@]}" -c "DROP OWNED BY \"${role}\";" >/dev/null 2>&1 || true
    done
  elif [[ "$db_state" == "error" ]]; then
    log_error "PostgreSQL-Verbindung nicht möglich — Uninstall bricht ab"
    return 1
  else
    log_ok "Datenbank ${db_name} bereits nicht vorhanden — Schemata übersprungen"
  fi

  # 2) Die 14 P2D2-*-Rollen immer über -d postgres entfernen (cluster-global),
  #    unabhängig davon, ob die Datenbank existiert. DROP ROLE IF EXISTS liefert bei
  #    "nicht vorhanden" 0; ein Fehler ist ein Verbindungs-/Abhängigkeitsproblem.
  #    Reihenfolge: erst Login-/Mitglied-Rollen, dann Gruppen-Rollen, zuletzt gemeinsame.
  local role role_err
  for role in \
      P2D2-MAIN P2D2-DEVELOP P2D2-DE1 P2D2-DE2 P2D2-FV \
      P2D2-User-MAIN P2D2-User-DEVELOP P2D2-User-DE1 P2D2-User-DE2 P2D2-User-FV \
      P2D2-Admin P2D2-RO \
      P2D2-Admin-Role P2D2-RO-Role; do
    if ! role_err="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -v ON_ERROR_STOP=1 -U "$superuser" -d postgres \
      -c "DROP ROLE IF EXISTS \"${role}\";" 2>&1 >/dev/null)"; then
      log_warn "    Rolle ${role} konnte nicht entfernt werden: $(_pg_first_err "${role_err}")"
      rc=1
    fi
  done

  # 3) Operator-verwaltete Datenbank p2d2 deklarativ entfernen (preparedDatabases.p2d2
  #    + DROP DATABASE + Operator-Rollen/-Secrets).
  remove_p2d2_database || rc=1

  # 3b) AddOn-DB-Admin-/RO-Secret entfernen (exakter Name, Turn 5).
  kubectl -n "$db_ns" delete secret p2d2-db-admin-secret --ignore-not-found >/dev/null 2>&1 || true

  # 4) Verifikation: keine der 14 P2D2-*-Rollen mehr vorhanden (über -d postgres).
  local leftover
  leftover="$(kubectl -n "$db_ns" exec "$db_pod" -- psql -U "$superuser" -d postgres -tAc \
    "SELECT rolname FROM pg_roles WHERE rolname IN ('P2D2-Admin','P2D2-RO','P2D2-Admin-Role','P2D2-RO-Role','P2D2-User-MAIN','P2D2-User-DEVELOP','P2D2-User-DE1','P2D2-User-DE2','P2D2-User-FV','P2D2-MAIN','P2D2-DEVELOP','P2D2-DE1','P2D2-DE2','P2D2-FV') ORDER BY rolname;" 2>/dev/null || true)"
  if [[ -n "$(printf '%s' "$leftover" | tr -d '[:space:]')" ]]; then
    log_warn "P2D2-*-Rollen weiterhin vorhanden: $(printf '%s' "$leftover" | tr '\n' ' ')"
    rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    log_error "Uninstall AddOn 00 PostgreSQL mit Resten/Fehlern beendet"
    return 1
  fi
  log_ok "Uninstall AddOn 00 PostgreSQL abgeschlossen (5 Schemata + 14 Rollen + DB + Operator-Rollen/-Secrets)"
}

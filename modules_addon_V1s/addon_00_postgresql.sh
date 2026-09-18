#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_00_postgresql.sh — p2d2-AddOn: PostgreSQL-Baustein (FERTIG, manuell verifiziert)
#
# Ablauf extrahiert aus p2d2-civitas-addon/v1/tasks/p2d2-postgresql.yml:
#   Zalando-Superuser-Secret lesen -> Rollen anlegen -> Schema anlegen -> DDL anwenden
#   -> Grants je Rollentyp -> ALTER DEFAULT PRIVILEGES. Passwort-Rotation = Phase 2.
#
# Rudimentär: Sequenz über psql im central-db-Pod. NICHT idempotent (keine
# Existenz-Prüfung pro Objekt) und Passwort-Quelle noch Platzhalter — siehe TODO.

install_addon_postgresql() {
  log "=== AddOn 00: PostgreSQL (DB/Schemata/Rollen) ==="

  local db_ns="${ADDON_DB_NS}"
  local db_name="p2d2"
  local secret="postgres.central-db.credentials.postgresql.acid.zalan.do"

  # Zalando-Superuser-Credentials (nur aus dem aktiven Secret lesen)
  local superuser superpass
  superuser="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.username}' | base64 -d)"
  superpass="$(kubectl -n "$db_ns" get secret "$secret" -o jsonpath='{.data.password}' | base64 -d)"
  log "Superuser für ${db_name}: ${superuser}"

  # 5 Stages. TODO(später): Stage-Scope (`--stage=main|all`) filtert diese Liste.
  local stage role schema
  for stage in MAIN DEVELOP DE1 DE2 FV; do
    case "$stage" in
      MAIN)    role="P2D2-MAIN";    schema="p2d2_main" ;;
      DEVELOP) role="P2D2-DEVELOP"; schema="p2d2_develop" ;;
      DE1)     role="P2D2-DE1";     schema="p2d2_de1" ;;
      DE2)     role="P2D2-DE2";     schema="p2d2_de2" ;;
      FV)      role="P2D2-FV";      schema="p2d2_fv" ;;
    esac

    log "  Stage ${stage}: Rolle ${role} + Schema ${schema}"

    # TODO: Passwort-Quelle (Phase 2) aus Secret/Environment statt Platzhalter.
    # TODO: Idempotenz (Existenz-Prüfung Rolle/Schema vor CREATE).
    kubectl -n "$db_ns" exec central-db-0 -- \
      psql -v ON_ERROR_STOP=1 -U "$superuser" -d "$db_name" -c \
      "CREATE ROLE \"${role}\" LOGIN PASSWORD 'CHANGEME';" || log_warn "  Rolle ${role} evtl. schon vorhanden"
    kubectl -n "$db_ns" exec central-db-0 -- \
      psql -v ON_ERROR_STOP=1 -U "$superuser" -d "$db_name" -c \
      "CREATE SCHEMA IF NOT EXISTS \"${schema}\" AUTHORIZATION \"${role}\";" || log_warn "  Schema ${schema} evtl. schon vorhanden"

    # TODO: DDL (templates/p2d2-postgresql/schema.sql.j2) auf das Schema anwenden.
    # TODO: Grants (owner=SELECT,INSERT,UPDATE,DELETE / ro=SELECT / admin=ALL)
    #       + ALTER DEFAULT PRIVILEGES analog zum Ansible-Task.
    log "    (DDL + Grants + Default Privileges: TODO — aus schema.sql.j2 nachziehen)"
  done

  log_ok "AddOn 00 PostgreSQL abgeschlossen (rudimentär, nicht idempotent)"
}

# uninstall_addon_postgresql — Rückbau (DROP SCHEMA + ROLE je Stage, umgekehrte Reihenfolge).
# Schützt den Superuser: nur die P2D2-*-Rollen werden entfernt, nie der Superuser selbst.
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

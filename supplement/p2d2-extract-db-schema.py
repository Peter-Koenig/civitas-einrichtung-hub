#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# p2d2-extract-db-schema.py
#
# Extrahiert das p2d2-Basisschema (standardmaessig p2d2_develop) aus der
# Standalone-DB `data-dna` (192.168.122.110, PostgreSQL 18.6) und erzeugt daraus
# das schema-parametrisierte DDL-Template
#   supplement/templates/p2d2-postgresql/schema.sql.j2
#
# Versionsagnostisch: nutzt `psql` (Client 17.11) gegen den Server 18.6 per
# Katalog-Abfragen (pg_catalog + pg_get_*-Funktionen). `pg_dump` 17.11 wuerde
# neuere Server (18.6) verweigern, daher kein pg_dump.
#
# Lesend: verbindet sich als P2D2-RO (read-only) via PGPASSFILE; keine
# Schreibzugriffe, keine Passwort-Hardcodierung (PGPASSFILE wird nur gesetzt).
#
# Bewusst ausgeschlossen (Standalone-Altlasten, nicht Teil des p2d2-Datenmodells):
#   - Tabelle  gt_pk_metadata             (erzeugt GeoServer selbst)
#   - Tabelle  rheinkassel_gf             (Standalone-Altlast)
#   - Sequenz  rheinkassel_gf_ogc_fid_seq (zur obigen Tabelle)
#
# Enthaelt zusaetzlich den "de1-Zusatz" fn_container_mitversionen() +
# trg_container_mitversionen (im Live-Bestand nur in p2d2_de1 vorhanden), da
# dieser Bestandteil der dokumentierten Zielstruktur (3 Funktionen, 2 Trigger je
# Schema) ist — siehe postgresql.md.
import argparse
import os
import subprocess
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path

HOST = "192.168.122.110"
PORT = "5432"
DB = "data-dna"
USER = "P2D2-RO"

DEFAULT_SCHEMA = "p2d2_develop"
DE1_SCHEMA = "p2d2_de1"
DEFAULT_OUT = Path(
    "/srv/p2d2/repos/civitas_einrichtung/supplement/templates/p2d2-postgresql/schema.sql.j2"
)

SCH = "{{ p2d2_instance_schema }}"
ROLE = "{{ p2d2_admin_role }}"

EXCLUDE_TABLES = {"gt_pk_metadata", "rheinkassel_gf"}
EXCLUDE_SEQUENCES = {"rheinkassel_gf_ogc_fid_seq"}

# Nur diese beiden Objekte aus p2d2_de1 in das Basistemplate uebernehmen.
DE1_EXTRA_FUNCTIONS = {"fn_container_mitversionen"}
DE1_EXTRA_TRIGGERS = {"trg_container_mitversionen"}


def psql_argv():
    return ["psql", "-X", "-q", "-h", HOST, "-p", PORT, "-U", USER, "-d", DB]


def run(sql: str) -> str:
    env = dict(os.environ)
    env["PGPASSFILE"] = os.path.expanduser("~/.pgpass-P2D2-RO")
    env.setdefault("PGCLIENTENCODING", "UTF8")
    r = subprocess.run(psql_argv() + ["-At", "-c", sql], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(f"psql fehlgeschlagen: {r.stderr.strip()}")
    return r.stdout


def rows(sql: str):
    env = dict(os.environ)
    env["PGPASSFILE"] = os.path.expanduser("~/.pgpass-P2D2-RO")
    env.setdefault("PGCLIENTENCODING", "UTF8")
    r = subprocess.run(
        psql_argv() + ["-At", "-F", "\t", "-c", sql],
        capture_output=True,
        text=True,
        env=env,
    )
    if r.returncode != 0:
        raise RuntimeError(f"psql fehlgeschlagen: {r.stderr.strip()}")
    out = []
    for line in r.stdout.splitlines():
        if line == "":
            continue
        out.append(line.split("\t"))
    return out


def parametrize(text: str) -> str:
    text = text.replace(DEFAULT_SCHEMA, SCH)
    text = text.replace(DE1_SCHEMA, SCH)
    text = text.replace('"P2D2-Admin-Role"', f'"{ROLE}"')
    text = text.replace('"P2D2-Admin"', f'"{ROLE}"')
    text = text.replace("Owner: P2D2-Admin-Role", f"Owner: {ROLE}")
    text = text.replace("Owner: P2D2-Admin", f"Owner: {ROLE}")
    return text


def enum_blocks(schema: str) -> str:
    d = OrderedDict()
    for name, label in rows(
        f"""
        SELECT t.typname, e.enumlabel
        FROM pg_type t
        JOIN pg_enum e ON e.enumtypid = t.oid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = '{schema}' AND t.typtype = 'e'
        ORDER BY t.typname, e.enumsortorder
        """
    ):
        d.setdefault(name, []).append(label)
    blocks = []
    for name, labels in d.items():
        body = ",\n    ".join(f"'{lbl}'" for lbl in labels)
        blocks.append(
            "DO $$\n"
            "BEGIN\n"
            "    IF NOT EXISTS (\n"
            "        SELECT 1 FROM pg_type t\n"
            "        JOIN pg_namespace n ON n.oid = t.typnamespace\n"
            f"        WHERE t.typname = '{name}' AND n.nspname = '{SCH}'\n"
            "    ) THEN\n"
            f"        CREATE TYPE {SCH}.{name} AS ENUM (\n"
            f"    {body}\n"
            ");\n"
            "    END IF;\n"
            "END$$;\n\n\n"
            f'ALTER TYPE {SCH}.{name} OWNER TO "{ROLE}";\n'
        )
    return "\n".join(blocks)


def table_defs(schema: str) -> str:
    tbls = [
        (r[0], r[1])
        for r in rows(
            f"SELECT relname, relpersistence FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
            f"WHERE n.nspname='{schema}' AND c.relkind='r' ORDER BY c.relname"
        )
        if r[0] not in EXCLUDE_TABLES
    ]
    blocks = []
    for tbl, relpers in tbls:
        cols = rows(
            f"""
            SELECT a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = '{schema}.{tbl}'::regclass
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        )
        checks = rows(
            f"""
            SELECT con.conname, pg_get_constraintdef(con.oid)
            FROM pg_constraint con
            WHERE con.conrelid = '{schema}.{tbl}'::regclass AND con.contype = 'c'
            ORDER BY con.conname
            """
        )
        lines = []
        for attname, typ, notnull, default in cols:
            notnull = notnull == "t"
            typ = parametrize(typ)
            inline_default = ""
            if default and "nextval(" not in default:
                inline_default = f" DEFAULT {parametrize(default)}"
            lines.append(f"    {attname} {typ}{' NOT NULL' if notnull else ''}{inline_default}")
        for conname, condef in checks:
            lines.append(f"    CONSTRAINT {parametrize(conname)} {parametrize(condef)}")
        body = ",\n".join(lines)
        kind = "CREATE UNLOGGED TABLE" if relpers == "u" else "CREATE TABLE"
        blocks.append(
            f"{kind} IF NOT EXISTS {SCH}.{tbl} (\n{body}\n);\n\n\n"
            f'ALTER TABLE {SCH}.{tbl} OWNER TO "{ROLE}";\n'
        )
    return "\n".join(blocks)


def sequence_defs(schema: str) -> str:
    seqs = rows(
        f"""
        SELECT c.relname, format_type(s.seqtypid, NULL), s.seqstart, s.seqincrement,
               s.seqmax, s.seqmin, s.seqcache, s.seqcycle
        FROM pg_class c
        JOIN pg_sequence s ON s.seqrelid = c.oid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '{schema}' AND c.relkind = 'S'
        ORDER BY c.relname
        """
    )
    owned = rows(
        f"""
        SELECT s.relname AS seq, t.relname AS tbl, a.attname AS col
        FROM pg_depend d
        JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
        JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        JOIN pg_namespace n ON n.oid = s.relnamespace
        WHERE n.nspname = '{schema}' AND d.deptype = 'a'
          AND d.classid = 'pg_class'::regclass AND d.refclassid = 'pg_class'::regclass
        ORDER BY s.relname
        """
    )
    owned_map = {o[0]: (o[1], o[2]) for o in owned}
    blocks = []
    for name, typ, start, inc, mx, mn, cache, cycle in seqs:
        if name in EXCLUDE_SEQUENCES:
            continue
        parts = [f"CREATE SEQUENCE IF NOT EXISTS {SCH}.{name}", f"    AS {typ}", f"    START WITH {start}", f"    INCREMENT BY {inc}"]
        parts.append("    NO MINVALUE" if mn == "1" else f"    MINVALUE {mn}")
        parts.append("    NO MAXVALUE" if mx == "1" else f"    MAXVALUE {mx}")
        parts.append(f"    CACHE {cache}")
        if cycle == "t":
            parts.append("    CYCLE")
        block = "\n".join(parts) + ";" + f'\n\n\nALTER SEQUENCE {SCH}.{name} OWNER TO "{ROLE}";'
        if name in owned_map:
            tbl, col = owned_map[name]
            block += f"\n\nALTER SEQUENCE {SCH}.{name} OWNED BY {SCH}.{tbl}.{col};"
        blocks.append(block)
    return "\n".join(blocks)


def serial_defaults(schema: str) -> str:
    out = []
    for tbl, attname, default in rows(
        f"""
        SELECT c.relname, a.attname, pg_get_expr(d.adbin, d.adrelid)
        FROM pg_attrdef d
        JOIN pg_class c ON c.oid = d.adrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.adnum
        WHERE n.nspname = '{schema}' AND c.relkind = 'r'
          AND c.relname NOT IN ('gt_pk_metadata','rheinkassel_gf')
          AND pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%'
        ORDER BY c.relname, a.attname
        """
    ):
        out.append(f"ALTER TABLE ONLY {SCH}.{tbl} ALTER COLUMN {attname} SET DEFAULT {parametrize(default)};")
    return "\n".join(out)


def separate_constraints(schema: str) -> str:
    # Abhaengigkeitsreihenfolge: erst PRIMARY KEY, dann UNIQUE, zuletzt FOREIGN KEY.
    # Nur so existiert jede referenzierte PK/UNIQUE-Voraussetzung vor ihrem FK
    # (alphabetische Tabellen-Sortierung wuerde z. B. p2d2_grabflur_mapping vor
    # p2d2_graeber ziehen und den FK vor dem referenzierten PK anlegen).
    # Kein DROP CONSTRAINT: die DDL wird ausschliesslich auf ein leeres Schema
    # angewendet; ein DROP+ADD-Muster waere nicht wiederholungssicher und erzeugt
    # auf einem frischen Schema lediglich NOTICEs.

    def group(contype: str) -> str:
        blocks = []
        for tbl, conname, condef in rows(
            f"""
            SELECT c.relname, con.conname, pg_get_constraintdef(con.oid)
            FROM pg_constraint con
            JOIN pg_class c ON c.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '{schema}' AND con.contype = '{contype}'
              AND c.relname NOT IN ('gt_pk_metadata','rheinkassel_gf')
            ORDER BY c.relname, con.conname
            """
        ):
            conname = parametrize(conname)
            blocks.append(
                f"ALTER TABLE ONLY {SCH}.{tbl}\n"
                f"    ADD CONSTRAINT {conname} {parametrize(condef)};"
            )
        return "\n\n".join(blocks)

    return "\n\n".join(filter(None, (group("p"), group("u"), group("f"))))


def index_defs(schema: str) -> str:
    out = []
    for ioid, iname in rows(
        f"""
        SELECT ix.indexrelid, i.relname
        FROM pg_index ix
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_class c ON c.oid = ix.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '{schema}' AND NOT ix.indisprimary AND NOT ix.indisunique
          AND c.relname NOT IN ('gt_pk_metadata','rheinkassel_gf')
        ORDER BY i.relname
        """
    ):
        ddl = run(f"SELECT pg_get_indexdef({ioid})").strip()
        if ddl.startswith("CREATE INDEX "):
            ddl = ddl.replace("CREATE INDEX ", "CREATE INDEX IF NOT EXISTS ", 1)
        ddl = parametrize(ddl)
        out.append(ddl + ";")
    return "\n\n".join(out)


def view_defs(schema: str) -> str:
    out = []
    for name, oid in rows(
        f"SELECT c.relname, c.oid FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
        f"WHERE n.nspname='{schema}' AND c.relkind='v' ORDER BY c.relname"
    ):
        sel = run(f"SELECT pg_get_viewdef({oid}, true)").rstrip("\n")
        out.append(
            f"CREATE OR REPLACE VIEW {SCH}.{name} AS\n{parametrize(sel)};\n\n\n"
            f'ALTER VIEW {SCH}.{name} OWNER TO "{ROLE}";'
        )
    return "\n".join(out)


def function_defs(schema: str, only: set = None) -> str:
    out = []
    for oid, sign in rows(
        f"SELECT p.oid, p.oid::regprocedure::text FROM pg_proc p "
        f"JOIN pg_namespace n ON n.oid=p.pronamespace "
        f"WHERE n.nspname='{schema}' ORDER BY p.proname, p.oid::regprocedure::text"
    ):
        proname = sign.split("(")[0].split(".")[-1]
        if only is not None and proname not in only:
            continue
        ddl = run(f"SELECT pg_get_functiondef({oid})").rstrip("\n")
        ddl = parametrize(ddl)
        sig = parametrize(sign)
        out.append(ddl + ";" + f'\n\n\nALTER FUNCTION {sig} OWNER TO "{ROLE}";')
    return "\n".join(out)


def trigger_defs(schema: str, only: set = None) -> str:
    out = []
    for oid, name in rows(
        f"SELECT tg.oid, tg.tgname FROM pg_trigger tg "
        f"JOIN pg_class c ON c.oid=tg.tgrelid "
        f"JOIN pg_namespace n ON n.oid=c.relnamespace "
        f"WHERE n.nspname='{schema}' AND NOT tg.tgisinternal ORDER BY tg.tgname"
    ):
        if only is not None and name not in only:
            continue
        ddl = run(f"SELECT pg_get_triggerdef({oid})").strip()
        if ddl.startswith("CREATE TRIGGER "):
            ddl = ddl.replace("CREATE TRIGGER ", "CREATE OR REPLACE TRIGGER ", 1)
        ddl = parametrize(ddl)
        out.append(ddl + ";")
    return "\n\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", default=DEFAULT_SCHEMA, help="Basisschema (Default p2d2_develop)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()
    schema = args.schema

    # Plausibilitaet: Basis-Schema gegen die uebrigen Schemata absichern.
    def tbl_count(s):
        return rows(
            f"SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
            f"WHERE n.nspname='{s}' AND c.relkind='r' AND c.relname NOT IN ('gt_pk_metadata','rheinkassel_gf')"
        )[0][0]

    base = tbl_count(schema)
    diffs = [f"{o}:{tbl_count(o)}" for o in ("p2d2_main", "p2d2_de2", "p2d2_fv") if tbl_count(o) != base]
    if diffs:
        print(f"WARNUNG Basis-Schema {schema} ({base} Tabellen) weicht ab: " + "; ".join(diffs), file=sys.stderr)

    header = (
        f"-- p2d2 DDL-Template (Basisschema {schema}).\n"
        "-- Schema-parametrisiert: {{ p2d2_instance_schema }} / {{ p2d2_admin_role }}.\n"
        "-- Nur Struktur, keine Daten. Lesend aus der Standalone-DB data-dna extrahiert (P2D2-RO).\n"
        "-- Bewusst ausgeschlossen: gt_pk_metadata, rheinkassel_gf (+ zugehoerige Sequenz).\n"
    )

    parts = [
        header,
        enum_blocks(schema),
        table_defs(schema),
        sequence_defs(schema),
        serial_defaults(schema),
        separate_constraints(schema),
        index_defs(schema),
        view_defs(schema),
        function_defs(schema),
        trigger_defs(schema),
        "-- de1-Zusatz: fn_container_mitversionen() + trg_container_mitversionen",
        function_defs(DE1_SCHEMA, only=DE1_EXTRA_FUNCTIONS),
        trigger_defs(DE1_SCHEMA, only=DE1_EXTRA_TRIGGERS),
    ]
    content = "\n\n".join(p for p in parts if p) + "\n"

    args.out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(args.out.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, str(args.out))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

    print(f"[OK] Template geschrieben: {args.out}")


if __name__ == "__main__":
    main()

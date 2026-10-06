#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# Extrahiert je p2d2-Stage einen Daten-Dump (COPY-Textformat) aus der Standalone-DB
# `data-dna` (192.168.122.110) und legt ihn unter supplement/db-dumps/<stage>.sql ab.
#
# Versionsagnostisch: nutzt `psql` (Client 17.11) mit `COPY … TO STDOUT` gegen den
# Server PostgreSQL 18.6. `pg_dump` 17.11 wuerde neuere Server (18.6) verweigern.
#
# Nur Fach-Tabellen (relkind='r') werden gedumpt. Bewusst ausgeschlossen:
#   - `gt_pk_metadata`  -> erzeugt GeoServer selbst, nicht Teil des p2d2-Datenmodells
#   - `rheinkassel_gf`   -> Standalone-Altlast, nicht in schema.sql.j2 enthalten
# Sequenzen werden nicht gedumpt (P2D2-RO hat kein USAGE; Resync spaeter via max(id)).
import datetime
import os
import subprocess
from pathlib import Path

HOST = "192.168.122.110"
PORT = "5432"
DB = "data-dna"
USER = "P2D2-RO"
OUT_DIR = Path("/srv/p2d2/repos/civitas_einrichtung/supplement/db-dumps")

STAGES = {
    "MAIN": "p2d2_main",
    "DEVELOP": "p2d2_develop",
    "DE1": "p2d2_de1",
    "DE2": "p2d2_de2",
    "FV": "p2d2_fv",
}

EXCLUDE_TABLES = {"gt_pk_metadata", "rheinkassel_gf"}

HEADER = """-- ACHTUNG: Arbeits-Auszug der p2d2-Standalone-DB (Stand {date}, Stage {stage}).
-- Dies ist KEIN kuratierter Demo-Datensatz, sondern der reale Standalone-Bestand,
-- genutzt um ein arbeitsfähiges AddOn zum Testen bereitzustellen. Ein eigens erstellter,
-- bereinigter Demo-Datensatz ist eine separate, noch offene Aufgabe.
--
-- Format: COPY-Textformat (psql 17.11, `COPY … TO STDOUT` gegen PostgreSQL 18.6).
-- Nur Fach-Tabellen; ausgeschlossen: gt_pk_metadata, rheinkassel_gf.
-- Sequenzen nicht enthalten (Resync erfolgt beim Import via max(id)).
"""


def run_psql(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"psql failed: {r.stderr.strip()}")
    return r.stdout


def psql_base():
    return ["psql", "-X", "-q", "-h", HOST, "-p", PORT, "-U", USER, "-d", DB]


def main():
    os.environ["PGPASSFILE"] = os.path.expanduser("~/.pgpass-P2D2-RO")
    os.environ.setdefault("PGCLIENTENCODING", "UTF8")
    date = datetime.date.today().isoformat()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for stage, schema in STAGES.items():
        out = OUT_DIR / f"{stage}.sql"
        tables = run_psql(psql_base() + [
            "-At",
            "-c",
            f"SELECT tablename FROM pg_tables WHERE schemaname='{schema}' ORDER BY tablename",
        ])
        table_list = [
            t for t in tables.splitlines()
            if t.strip() and t.strip() not in EXCLUDE_TABLES
        ]
        dumped = 0
        with out.open("w", encoding="utf-8") as f:
            f.write(HEADER.format(date=date, stage=stage))
            f.write("\n")
            for t in table_list:
                data = run_psql(psql_base() + ["-c", f'COPY {schema}."{t}" TO STDOUT'])
                f.write(f'COPY {schema}."{t}" FROM stdin;\n')
                f.write(data)
                if data and not data.endswith("\n"):
                    f.write("\n")
                f.write("\\.\n\n")
                dumped += 1
        print(f"[OK] {stage} ({schema}): {dumped} Tabellen -> {out}")


if __name__ == "__main__":
    main()

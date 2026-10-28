# Suite 33 (GeoServer-Config): Gruppen und Schnellpfade

Die Suite 33 ist in 12 unabhängige Gruppen zerlegt (`33_geoserver_config_01.sh` … `_12.sh`).
Jede Gruppe hat einen eigenen Temp-Bereich (`mktemp -d`), eigene Stub-Logs und einen eigenen
Lazy-Snapshot (`ensure_snap_installed`/`restore_state`). Gemeinsame Teile liegen in
`tests/lib_geoserver.sh`. Die Zerlegung beschleunigt den Lauf durch Parallelisierung über die
Slots von `tests/run.sh`.

## Aufruf

| Ziel | Befehl | Dauer |
|---|---|---|
| alle Gruppen | `JOBS=12 ./tests/run.sh 33_geoserver` | 132 s |
| eine Gruppe | `./tests/run.sh 33_geoserver_config_05` | 73 s |
| nur neue Szenarien 85 bis 96 | `GEOSERVER_ONLY=new ./tests/run.sh 33_geoserver` | 49 s |
| ein neues Szenario | `GEOSERVER_ONLY=new GEOSERVER_SCENARIOS=86 ./tests/run.sh 33_geoserver` | 28 s |

Dauer auf dem sdt-LXC (12 Threads, `JOBS`-Standard = `nproc`). `GEOSERVER_ONLY=new` überspringt
die Bestands-Szenarien 1–84; `GEOSERVER_SCENARIOS` filtert nur die neuen Szenarien (85–96).

## Szenario zu Gruppe

Diese Tabelle wird generiert mit `tests/tools/gs_group_map.sh` (nicht von Hand gepflegt).

| Szenario | Gruppe |
|----------|--------|
| 1 | 02 |
| 2 | 02 |
| 3 | 11 |
| 4 | 04 |
| 5 | 05 |
| 6 | 10 |
| 7 | 03 |
| 8 | 07 |
| 9 | 04 |
| 10 | 06 |
| 11 | 08 |
| 12 | 11 |
| 13 | 11 |
| 14 | 12 |
| 15 | 02 |
| 16 | 07 |
| 17 | 12 |
| 18 | 12 |
| 19 | 03 |
| 20 | 12 |
| 21 | 09 |
| 22 | 12 |
| 23 | 08 |
| 24 | 08 |
| 25 | 04 |
| 26 | 09 |
| 27 | 12 |
| 28 | 05 |
| 29 | 01 |
| 30 | 06 |
| 31 | 09 |
| 32 | 10 |
| 33 | 06 |
| 34 | 07 |
| 35 | 06 |
| 36 | 12 |
| 37 | 08 |
| 38 | 10 |
| 39 | 12 |
| 40 | 12 |
| 41 | 11 |
| 42 | 02 |
| 43 | 03 |
| 44 | 01 |
| 45 | 12 |
| 46 | 12 |
| 47 | 01 |
| 48 | 03 |
| 49 | 05 |
| 50 | 05 |
| 51 | 12 |
| 52 | 02 |
| 53 | 07 |
| 54 | 04 |
| 55 | 04 |
| 55a | 05 |
| 56 | 04 |
| 57 | 05 |
| 58 | 10 |
| 59 | 12 |
| 60 | 07 |
| 61 | 04 |
| 62 | 02 |
| 63 | 12 |
| 64 | 11 |
| 65 | 10 |
| 66 | 11 |
| 67 | 03 |
| 68 | 06 |
| 69 | 03 |
| 70 | 06 |
| 71 | 07 |
| 72 | 12 |
| 73 | 07 |
| 74 | 02 |
| 75 | 03 |
| 76 | 01 |
| 77 | 11 |
| 78 | 12 |
| 79 | 08 |
| 80 | 08 |
| 81 | 11 |
| 82 | 08 |
| 83 | 09 |
| 84 | 05 |
| 85 | 09 |
| 86 | 01 |
| 87 | 08 |
| 88 | 09 |
| 89 | 12 |
| 90 | 12 |
| 91 | 12 |
| 92 | 09 |
| 93 | 10 |
| 94 | 06 |
| 95 | 10 |
| 96 | 10 |

## Regeln für neue Szenarien

1. Neue Szenarien kommen in die kürzeste Gruppe (Tabelle oben).
2. Zustandsketten (Szenario ohne `reset_state`, das auf dem Vorgänger aufsetzt) bleiben in einer Gruppe.
3. Setup immer über `ensure_snap_installed` plus `restore_state`, nie über einen Voll-Install — außer das Szenario prüft den Voll-Install selbst.
4. Szenarien, die Variablen exportieren, laufen in einer Subshell (oder unsetten die Variablen am Szenario-Ende).
5. Keine festen Pfade außerhalb von `$T`.

#!/usr/bin/env bash
# tests/tools/gs_group_map.sh — erzeugt die Szenario-zu-Gruppe-Tabelle für Suite 33.
# Liest tests/suites/33_geoserver_config_*.sh und gibt eine Markdown-Tabelle aus.
# Nur Ausgabe auf stdout, keine Schreibzugriffe. Aufruf:
#   tests/tools/gs_group_map.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

{
  # Legacy-Szenarien: scenario "N" (Bestand 1–84 + Variante 55a); neue (85–96)
  # sind über `if want N` erfasst und werden unten separat ausgegeben.
  for g in "$HERE"/suites/33_geoserver_config_*.sh; do
    gid="$(basename "$g" | sed -E 's/^33_geoserver_config_([0-9]+)\.sh$/\1/')"
    sed -nE 's/^scenario "([^"]+)"/\1/p' "$g" | while IFS= read -r n; do
      case "$n" in
        85|86|87|88|89|90|91|92|93|94|95|96) ;;
        *) printf '%s\t%s\n' "$n" "$gid" ;;
      esac
    done
  done

  # Neue Szenarien: if want N (85–96).
  for g in "$HERE"/suites/33_geoserver_config_*.sh; do
    gid="$(basename "$g" | sed -E 's/^33_geoserver_config_([0-9]+)\.sh$/\1/')"
    sed -nE 's/^if want ([0-9]+); then/\1/p' "$g" | while IFS= read -r n; do
      printf '%s\t%s\n' "$n" "$gid"
    done
  done
} | LC_ALL=C sort -V -k1,1 | awk -F'\t' '
  BEGIN { print "| Szenario | Gruppe |"; print "|----------|--------|" }
  !seen[$1]++ { printf "| %s | %s |\n", $1, $2 }
'

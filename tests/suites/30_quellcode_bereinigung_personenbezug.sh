#!/usr/bin/env bash
# Suite 30: quellcode_bereinigung_personenbezug — statische Prüfung, dass im
# versionierten Quelltext keine Personen-/KI-Namen (Peter als Aufgabenträger,
# Perplexity, DeepSeek) und keine Rollen-/Aufgabenformulierungen stehen.
# Nur git grep über versionierte Dateien, kein Cluster/Netz.

begin_suite "quellcode_bereinigung_personenbezug"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# (a) KI-/Rollennamen müssen vollständig fehlen (keine Ausnahmen).
ai="$(git -C "$REPO" grep -nI -i -E 'perplexity|deepseek|orchestrator|schreib-ki|zeditor' -- . ':!supplement/db-dumps' ':!tests/suites/' 2>/dev/null || true)"
check "a keine KI-/Rollennamen" "" "$ai"

# (b) Aufgabenformulierungen mit Person („Peter macht …“) müssen fehlen.
task="$(git -C "$REPO" grep -nI -i -E 'von Peter|durch Peter|Peter trägt|Peter ersetzt|Peter/Keycloak|muss von Peter|Peter befüllt|Peter erzeugt|Peter macht' -- . ':!supplement/db-dumps' ':!tests/suites/' 2>/dev/null || true)"
check "b keine Aufgabenformulierungen" "" "$task"

# (c) Name „Peter“ nur noch in begründeten Ausnahmen: SPDX-/Copyright-Zeilen,
#     Kontakt-/Autorenangabe (README) und Konfigurationswerte (GitHub-Username
#     „Peter-Koenig/“, E-Mail „peter.koenig@“).
rest="$(git -C "$REPO" grep -nI -i -E '(^|[^[:alpha:]])(peters?|perplexity|deepseek)([^[:alpha:]]|$)' -- . ':!supplement/db-dumps' ':!tests/suites/' 2>/dev/null | grep -vE 'SPDX-FileCopyrightText|Ansprechpartner|Contact:|Peter-Koenig/|peter\.koenig@|Peter prueft' || true)"
check "c nur begründete Ausnahmen" "" "$rest"

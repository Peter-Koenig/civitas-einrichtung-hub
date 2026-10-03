#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2025 p2d2 Contributors
#
# Licensed under the EUPL, Version 1.2 only (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#   https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Licence for the specific language governing permissions and
# limitations under the Licence.
#
# 02_lib.sh — Hilfsfunktionen
#
# Siehe: skriptarchitektur.md (V1), Modul 02
# Enthält keine Installationslogik und keine Seiteneffekte beim Laden.
# set -e wird nicht gesetzt — das Modul wird in den euo-Kontext des
# Entry-Points hinein gesourct.

# ── Logging ──────────────────────────────────────────────────────────────────
log()        { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
log_warn()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $*" >&2; }
log_error()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ── Idempotenz-Hilfsfunktionen ───────────────────────────────────────────────
is_installed()   { command -v "$1" &>/dev/null; }
systemd_active() { systemctl is-active --quiet "$1"; }
k8s_ready()      { kubectl get "$1" "$2" -n "${3:-default}" &>/dev/null; }

# ── Netzwerk ─────────────────────────────────────────────────────────────────
# Nutzt bash built-in /dev/tcp statt nc (nicht auf allen Systemen vorhanden)
tcp_reachable() { timeout 5 bash -c "echo >/dev/tcp/${1}/${2}" &>/dev/null; }
dns_resolves()  { dig +short "$1" | grep -q '.'; }

# ── Warteschleife für Kubernetes-Pods ────────────────────────────────────────
wait_pods_ready() {
  local namespace="$1"
  local timeout="${2:-$TIMEOUT_POD_READY}"
  kubectl wait --for=condition=Ready pods --all \
    -n "$namespace" --timeout="${timeout}s"
}

# ── Fehlercount-Mechanismus (für Phase 3) ────────────────────────────────────
VERIFY_ERRORS=0
check() {
  local description="$1"
  local result="$2"
  if [[ "$result" -eq 0 ]]; then
    log_ok "[VERIFY] ${description} ... OK"
  else
    log_error "[VERIFY] ${description} ... FAILED"
    (( VERIFY_ERRORS++ )) || true
  fi
}

# ── Prüfe Exit-Code mit Abbruch ──────────────────────────────────────────────
assert_success() {
  local message="$1"
  local result="$2"
  if [[ "$result" -ne 0 ]]; then
    log_error "${message} — Abbruch"
    exit 1
  fi
}

# ── Passwort-Generierung nach Policy ──────────────────────────────────────────
# Erzeugt ein Passwort das folgende Policy erfüllt:
#   - mind. 12 Zeichen (konfigurierbar via $1)
#   - mind. 1 Ziffer
#   - mind. 1 Großbuchstabe
#   - mind. 1 Kleinbuchstabe
#   - mind. 1 Sonderzeichen aus: @%^*()+=~?><,.-
#   - KEINE Zeichen, die mit sed (&, #, |), YAML (#, :) oder Shell
#     ($, !, Backtick, Anführungszeichen) kollidieren
#   - KEINE base64-Sonderzeichen (+, /, =)
#   - KEINE geschweiften Klammern ({, }): Jinja2-Kollision, siehe HINWEIS unten
#
# HINWEIS: '%' ist im Charset enthalten, weil das aktuell verwendete
# sed-Trennzeichen in 06_civitas.sh '|' ist (sed -e "s|PLACEHOLDER|${pw}|g").
# Falls das sed-Trennzeichen jemals auf '%' geaendert wird, MUSS '%'
# hier aus dem Charset entfernt werden. Diese Abhaengigkeit ist bewusst
# in Kauf genommen und muss bei Aenderungen an den sed-Aufrufen in
# 06_civitas.sh manuell nachgezogen werden.
#
# HINWEIS (unabhaengig vom sed-Trennzeichen): '{' und '}' sind dauerhaft aus
# dem Charset ausgeschlossen, weil Ansible das Inventory in cc_cli exec per
# Jinja2 rendert. Die Zweizeichenfolgen '{%' und '%}' starten/beenden dort
# einen Jinja-Statement-Block (analog '{{'/'}}' fuer Ausdruecke). Ein zufaellig
# gezogenes Passwort mit '{%', '%}', '{{' oder '}}' fuehrt zu einem
# Ansible-Templating-Fehler ("Encountered unknown tag"). '%' allein ist
# ungefaehrlich und bleibt fuer das sed-Trennzeichen '|' weiterhin erforderlich.
gen_policy_password() {
  local length="${1:-24}"
  local max_attempts=50
  local charset='A-Za-z0-9@%^*()+=~?><,.-'
  local pw
  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    pw="$(tr -dc "${charset}" < /dev/urandom | head -c "${length}" || true)"
    if echo "${pw}" | grep -qP '(?=.*[0-9])(?=.*[A-Z])(?=.*[a-z])(?=.*[@%^*()+=~?><,.-])'; then
      echo "${pw}"
      return 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      local has_digit='nein'; local has_upper='nein'; local has_lower='nein'; local has_special='nein'
      echo "${pw}" | grep -qP '[0-9]' && has_digit='ja'
      echo "${pw}" | grep -qP '[A-Z]' && has_upper='ja'
      echo "${pw}" | grep -qP '[a-z]' && has_lower='ja'
      echo "${pw}" | grep -qP '[@%^*()+=~?><,.-]' && has_special='ja'
      log_error "gen_policy_password: Nach ${max_attempts} Versuchen kein gueltiges Passwort erzeugt"
      log_error "  Letzter Versuch: '${pw}' (Laenge: ${#pw})"
      log_error "  Bedingungen: Ziffer=${has_digit}, Grossbuchstabe=${has_upper}, Kleinbuchstabe=${has_lower}, Sonderzeichen=${has_special}"
      exit 1
    fi
  done
}

# ── CHANGEME-Prüfung (nie abbrechend) ─────────────────────────────────────────
warn_changeme_values() {
  local _wc_when="${1:-}" _wc_name _wc_val _wc_hits=()
  while IFS= read -r _wc_name; do
    [[ "${_wc_name}" == _* || "${_wc_name}" == BASH* ]] && continue
    [[ "${_wc_name}" == WG_* && "${WG_ENABLED:-true}" != "true" ]] && continue
    _wc_val="${!_wc_name:-}"
    [[ "${_wc_val}" == *CHANGEME* ]] || continue
    if [[ "${_wc_val}" =~ ^[A-Za-z0-9._@:/-]*CHANGEME[A-Za-z0-9._:@/-]*$ && ${#_wc_val} -le 64 ]]; then
      _wc_hits+=("${_wc_name}=${_wc_val}")
    else
      _wc_hits+=("${_wc_name} (enthält CHANGEME)")
    fi
  done < <(compgen -v | LC_ALL=C sort)
  if (( ${#_wc_hits[@]} )); then
    log_warn "[${_wc_when}] ${#_wc_hits[@]} Variable(n) mit CHANGEME-Platzhalter — bitte prüfen:"
    local _wc_h
    for _wc_h in "${_wc_hits[@]}"; do
      log_warn "    ${_wc_h}"
    done
  fi
  return 0
}

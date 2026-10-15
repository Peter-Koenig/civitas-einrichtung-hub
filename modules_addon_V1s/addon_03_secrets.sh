#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_03_secrets.sh — gemeinsame Helfer für Passwort-/Secret-Verwaltung.
# Wird von addon_00_postgresql.sh (VM) und vom Host-Teil von
# p2d2-civitas-addon-v1s.sh (Rückweg) gesourct. Sourcebar ohne Cluster-Zugriff;
# kubectl wird erst bei Aufruf der Secret-Funktionen benötigt.
#
# WICHTIG: Funktionen, die Zustand im aufrufenden Prozess setzen (Exporte,
# Merker wie _P2D2_ENV_BACKUP_DONE), dürfen NICHT in Befehlssubstitution
# `$(...)` aufgerufen werden — eine Substitution läuft in einer Subshell und der
# Zustand (insbesondere `export`) geht beim Zurückkehren verloren. Solche
# Funktionen werden direkt aufgerufen und ihr Ergebnis danach gelesen.

# ── Verwaltete Passwort-Variablen (eine Stelle; später erweiterbar) ────────────
# Gibt die Variablennamen aus, deren Werte aufgelöst, im Cluster verwaltet und in
# der .env gespiegelt werden. Reihenfolge: gemeinsame zuerst, dann je Stage.
_p2d2_managed_vars() {
  local stage
  printf '%s\n' P2D2_ADMIN_DB_PASSWORD P2D2_RO_DB_PASSWORD
  for stage in MAIN DEVELOP DE1 DE2 FV; do
    printf 'P2D2_%s_DB_PASSWORD\n' "$stage"
  done
}

# _p2d2_first_err <text> — erste Zeile, auf 200 Zeichen gekürzt, ohne Werte.
_p2d2_first_err() {
  printf '%s' "$1" | head -1 | cut -c1-200
}

# _p2d2_pw_gen — zufälliges Passwort (Hex, ohne Shell-Sonderzeichen).
_p2d2_pw_gen() { openssl rand -hex 24; }

# _p2d2_pw_empty <wert> — leer oder Platzhalter (changeme*/CHANGEME*, case-insens.).
_p2d2_pw_empty() {
  local v="${1:-}"
  [[ -z "${v}" || "${v,,}" == changeme* ]]
}

# _p2d2_pw_is_valid <wert> — sichere Zeichenmenge + Mindestlänge 16, ohne Log.
_p2d2_pw_is_valid() {
  local v="$1"
  [[ "${#v}" -ge 16 && ! "$v" =~ [^A-Za-z0-9._~@%+=:,/-] ]]
}

# _p2d2_pw_validate <name> <wert> — Validierung mit klarer Fehlermeldung (ohne Wert).
_p2d2_pw_validate() {
  local name="$1" value="$2"
  if _p2d2_pw_is_valid "$value"; then
    return 0
  fi
  if [[ "${#value}" -lt 16 ]]; then
    log_error "${name}: Passwort zu kurz (mindestens 16 Zeichen)"
  else
    log_error "${name}: Passwort enthält unzulässige Zeichen"
  fi
  return 1
}

# _p2d2_pw_validate_env — alle verwalteten, aus der Umgebung gesetzten Werte
# vorab validieren (kein Teilzustand). Leer/Platzhalter werden übersprungen.
_p2d2_pw_validate_env() {
  local var value
  while IFS= read -r var; do
    value="${!var:-}"
    _p2d2_pw_empty "$value" && continue
    _p2d2_pw_validate "$var" "$value" || return 1
  done < <(_p2d2_managed_vars)
  return 0
}

# _p2d2_pw_resolve <var> <ns> <secret> <key> — Wert auflösen (Umgebung -> Secret
# -> erzeugt), validieren und <var> im AUFRUFENDEN Prozess setzen+exportieren.
# Gibt nichts auf stdout aus (Rückgabe 0/1); NICHT in Befehlssubstitution aufrufen.
_p2d2_pw_resolve() {
  local var="$1" ns="$2" secret="$3" key="$4" value
  value="${!var:-}"
  if _p2d2_pw_empty "$value"; then
    value="$(_p2d2_secret_get "$ns" "$secret" "$key")"
    if _p2d2_pw_empty "$value"; then
      value="$(_p2d2_pw_gen)"
    elif ! _p2d2_pw_is_valid "$value"; then
      log_warn "${var}: Wert im Cluster-Secret ungültig — neuer Wert wird erzeugt"
      value="$(_p2d2_pw_gen)"
    fi
  else
    _p2d2_pw_validate "$var" "$value" || return 1
  fi
  export "${var}=${value}"
  return 0
}

# _p2d2_secret_get <ns> <name> <key> — Secret-Key auslesen (leer bei Fehlen/Fehler).
_p2d2_secret_get() {
  local ns="$1" name="$2" key="$3"
  kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# _p2d2_secret_apply <ns> <name> <key>=<wert> ... — Secret-Key(s) idempotent setzen.
# Vorhandene Keys bleiben erhalten (Merge); Werte als base64 in einem Manifest
# (temp, Mode 600) + kubectl apply — nie in der Prozessliste. Fehlerursache wird
# kurz (erste Zeile, ohne Wert) geloggt. Kein Seiteneffekt auf die umask.
_p2d2_secret_apply() {
  local ns="$1" name="$2"; shift 2
  local manifest err json kv k v b64
  manifest="$(mktemp)"
  json="$(kubectl -n "$ns" get secret "$name" -o json 2>/dev/null || true)"
  if [[ -n "$json" ]]; then
    json="$(printf '%s' "$json" | jq -c --arg n "$name" --arg ns "$ns" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$n,namespace:$ns},type:(.type // "Opaque"),data:(.data // {})}' 2>/dev/null || true)"
  fi
  [[ -n "$json" ]] || json="{\"apiVersion\":\"v1\",\"kind\":\"Secret\",\"metadata\":{\"name\":\"$name\",\"namespace\":\"$ns\"},\"type\":\"Opaque\",\"data\":{}}"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    b64="$(printf '%s' "$v" | base64 -w0)"
    json="$(printf '%s' "$json" | jq -c --arg k "$k" --arg v "$b64" '.data[$k] = $v')"
  done
  # mktemp legt das Manifest bereits mit Mode 0600 an; die umask bleibt unverändert.
  printf '%s\n' "$json" > "$manifest"
  if ! err="$(kubectl apply -f "$manifest" 2>&1 >/dev/null)"; then
    log_error "Secret ${name}: $(_p2d2_first_err "${err}")"
    rm -f "$manifest"
    return 1
  fi
  rm -f "$manifest"
  return 0
}

# _P2D2_ENV_BACKUP_DONE — Merker: genau ein Backup des Ausgangszustands je Lauf.
_P2D2_ENV_BACKUP_DONE=0

# _p2d2_env_backup_reset — Merker zurücksetzen (neuer Lauf / neue Zieldatei).
_p2d2_env_backup_reset() { _P2D2_ENV_BACKUP_DONE=0; }

# _p2d2_env_read <datei> <var> — Wert einer Variable aus der .env lesen
# (Anführungszeichen entfernt; Kommentar am Zeilenende wird ignoriert).
_p2d2_env_read() {
  local file="$1" var="$2" line re
  re='^[[:space:]]*(export[[:space:]]+)?'"${var}"'=("[^"]*"|[^[:space:]#]*)'
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[2]//\"/}"
      return 0
    fi
  done < "$file"
  return 0
}

# _p2d2_env_mirror <datei> <var> <wert> — Wert in der .env spiegeln.
# Genau ein Backup <datei>.bak (Mode 600) des Ausgangszustands je Lauf, atomar
# (temp + mv), nur bei Änderung; ein Kommentar am Zeilenende bleibt erhalten.
# Schreibfehler -> Warnung + Rückgabe 1 (kein Abbruch; der Wert bleibt im Cluster-Secret).
_p2d2_env_mirror() {
  local file="$1" var="$2" value="$3" cur tmp first=1 line re
  [[ -f "$file" ]] || { log_warn "Env-Datei nicht vorhanden (${file}) — Spiegeln übersprungen"; return 1; }
  cur="$(_p2d2_env_read "$file" "$var")"
  [[ "$cur" == "$value" ]] && return 0
  if [[ "${_P2D2_ENV_BACKUP_DONE}" == "0" ]]; then
    cp "$file" "$file.bak" 2>/dev/null || { log_warn "Backup ${file}.bak fehlgeschlagen — Spiegeln übersprungen"; return 1; }
    chmod 600 "$file.bak" 2>/dev/null || true
    _P2D2_ENV_BACKUP_DONE=1
  fi
  tmp="${file}.tmp.$$"
  re='^([[:space:]]*(export[[:space:]]+)?'"${var}"'=)("[^"]*"|[^[:space:]#]*)(.*)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$first" == 1 && "$line" =~ $re ]]; then
      first=0
      line="${BASH_REMATCH[1]}\"${value}\"${BASH_REMATCH[4]}"
    fi
    printf '%s\n' "$line"
  done < "$file" > "$tmp"
  if [[ "$first" == 1 ]]; then
    printf 'export %s="%s"\n' "$var" "$value" >> "$tmp"
  fi
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; log_warn "Env-Datei ${file} konnte nicht geschrieben werden"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

# _p2d2_env_merge_from <quelle> <ziel> — verwaltete Variablen aus <quelle> in
# <ziel> übernehmen (nur diese Zeilen, keine Ganzdatei-Kopie). Gleiche Regeln wie
# der Spiegel (ein Backup, atomar, idempotent). Fehlende Variable in <quelle> wird
# übersprungen.
_p2d2_env_merge_from() {
  local src="$1" dst="$2" var value
  [[ -f "$src" ]] || { log_warn "Quell-Datei nicht vorhanden (${src}) — Übernahme übersprungen"; return 1; }
  while IFS= read -r var; do
    value="$(_p2d2_env_read "$src" "$var")"
    [[ -z "$value" ]] && continue
    _p2d2_env_mirror "$dst" "$var" "$value" || true
  done < <(_p2d2_managed_vars)
  return 0
}

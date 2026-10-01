#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# Copyright (C) 2024-2026 p2d2 Contributors
#
# addon_35_portal.sh — p2d2-AddOn: Service-Portal-Kacheln (5 p2d2-Stages)
#
# Fügt die 5 p2d2-Stage-Kacheln (p2d2-main, p2d2-dev, p2d2-de1, p2d2-de2,
# p2d2-fv) idempotent und rückbaubar AM ANFANG des CIVITAS/CORE-Service-Portal-
# ConfigMap "apps.js" (Namespace cc-prd-access-stack, Deployment service-portal)
# ein. Der eingefügte Block ist markiert:
#   // p2d2-addon:begin  …  // p2d2-addon:end
#
# Öffentliche Funktionen:
#   portal_apply   — Block einfügen/ersetzen + Portal-Restart
#   portal_remove  — nur den markierten Block entfernen + Restart
#   portal_status  — Zustand anzeigen (read-only)
#   portal_verify  — Verifikation der 5 Kacheln (Marker, Reihenfolge, /check?id=)
#
# Env (überschreibbar): PORTAL_NS, PORTAL_CM, PORTAL_KEY, PORTAL_DEPLOY,
# PORTAL_DOMAIN, PORTAL_INGRESS_IP, PORTAL_ICON (Fallback P2D2_ICON),
# PORTAL_BACKUP_DIR, PORTAL_VERIFY_RETRIES (Default 3), PORTAL_VERIFY_DELAY
# (Default 5 s).
#
# ACHTUNG: Ein erneuter CIVITAS/CORE-Ansible-Lauf überschreibt die ConfigMap
# "apps.js". Danach muss dieses Modul erneut ausgeführt werden (portal_apply),
# sonst fehlen die Kacheln wieder.
#
# Logik übernommen aus dem erprobten Referenzskript p2d2-portal-tiles.sh.
# Abweichungen (nur durch Modul-Konventionen erzwungen, siehe ai-run):
#   - Funktionen statt Standalone-Skript; log_*/_portal_die (return 1) statt die;
#   - Variablen-Präfix PORTAL_* (Global-Namespace der Module);
#   - Schreiben per `kubectl create configmap --dry-run=client | kubectl apply
#     --server-side --field-manager=p2d2-addon-portal --force-conflicts`.
# Bewusst UNVERÄNDERT (Korrektur 8): Marker-Text (auch der veraltete Zusatz
# "verwaltet durch p2d2-portal-tiles.sh"), Einfügepunkt Array-Anfang,
# ${DOMAIN}-Escaping, validate_in_pod.

# Fail-Fast: Modul nicht isoliert sourcen (log_* kommen vom Hauptskript).
if [[ -z "${ADDON_DOMAIN:-}" ]]; then
  echo "FEHLER: ADDON_DOMAIN nicht gesetzt — addon_35_portal.sh nicht isoliert sourcen (nur über p2d2-civitas-addon-v1s.sh)." >&2
  return 1 2>/dev/null || exit 1
fi

export LC_ALL=C.UTF-8

# ── Konfiguration (per Env überschreibbar) ─────────────────────────────────────
PORTAL_NS="${PORTAL_NS:-cc-prd-access-stack}"
PORTAL_CM="${PORTAL_CM:-apps.js}"
PORTAL_KEY="${PORTAL_KEY:-apps.js}"
PORTAL_DEPLOY="${PORTAL_DEPLOY:-deploy/service-portal}"
PORTAL_DOMAIN="${PORTAL_DOMAIN:-${ADDON_DOMAIN}}"
# Korrektur 5: Ingress-IP aus VM_IP_STATIC (vom Hauptskript exportiert) ableiten;
# Literal nur als allerletzter Fallback für isolierte Nutzung.
PORTAL_INGRESS_IP="${PORTAL_INGRESS_IP:-${VM_IP_STATIC:-192.168.12.139}}"
# Korrektur 6: PORTAL_ICON mit Fallback auf P2D2_ICON (Abwärtskompatibilität).
PORTAL_ICON="${PORTAL_ICON:-${P2D2_ICON:-https://www.udp.data-dna.eu/images/p2d2-logo.svg}}"
PORTAL_BACKUP_DIR="${PORTAL_BACKUP_DIR:-/root/civitas-install/backup/service-portal}"
PORTAL_BEGIN_MARK="// p2d2-addon:begin"
PORTAL_END_MARK="// p2d2-addon:end"
PORTAL_IDS="p2d2-main p2d2-dev p2d2-de1 p2d2-de2 p2d2-fv"
PORTAL_VERIFY_RETRIES="${PORTAL_VERIFY_RETRIES:-3}"
PORTAL_VERIFY_DELAY="${PORTAL_VERIFY_DELAY:-5}"

# _portal_die — loggt und beendet die aufrufende Funktion mit Fehlercode.
_portal_die() { log_error "$*"; return 1; }

# _portal_fetch_current <work> — liest data[apps.js] der ConfigMap in <work>/current.js.
_portal_fetch_current() {
  local work="$1"
  kubectl -n "$PORTAL_NS" get cm "$PORTAL_CM" >/dev/null \
    || { _portal_die "ConfigMap $PORTAL_NS/$PORTAL_CM nicht gefunden"; return 1; }
  kubectl -n "$PORTAL_NS" get cm "$PORTAL_CM" -o jsonpath='{.data.apps\.js}' > "$work/current.js"
  [ -s "$work/current.js" ] || { _portal_die "data[apps.js] ist leer"; return 1; }
}

# _portal_strip_block <in> <out> — entfernt den markierten p2d2-Block.
_portal_strip_block() {
  awk -v b="$PORTAL_BEGIN_MARK" -v e="$PORTAL_END_MARK" \
    'index($0,b){skip=1;next} index($0,e){skip=0;next} !skip' "$1" > "$2"
}

# _portal_entry <id> <name> <host> <en> <de> — ein Kachel-Objekt.
_portal_entry() {
cat <<EOF
  {
    id: "$1",
    name: "$2",
    icon: "$PORTAL_ICON",
    description: {
      en: "$4",
      de: "$5"
    },
    role: "",
    url: "https://$3.\${DOMAIN}/",
    iframe: false
  },
EOF
}

# _portal_build_block <work> — erzeugt den markierten Block in <work>/block.js.
_portal_build_block() {
  local work="$1"
  {
    echo "$PORTAL_BEGIN_MARK (verwaltet durch p2d2-portal-tiles.sh, nicht manuell editieren)"
    _portal_entry p2d2-main "p2d2 - Main" www   "p2d2 (Public-Public Data-DNA) - production stage."  "p2d2 (Public-Public Data-DNA) - Produktiv-Stage."
    _portal_entry p2d2-dev  "p2d2 - Dev"  dev   "p2d2 (Public-Public Data-DNA) - development stage." "p2d2 (Public-Public Data-DNA) - Entwicklungs-Stage."
    _portal_entry p2d2-de1  "p2d2 - DE1"  f-de1 "p2d2 (Public-Public Data-DNA) - team DE1 stage."    "p2d2 (Public-Public Data-DNA) - Team-DE1-Stage."
    _portal_entry p2d2-de2  "p2d2 - DE2"  f-de2 "p2d2 (Public-Public Data-DNA) - team DE2 stage."    "p2d2 (Public-Public Data-DNA) - Team-DE2-Stage."
    _portal_entry p2d2-fv   "p2d2 - FV"   f-fv  "p2d2 (Public-Public Data-DNA) - team FV stage."     "p2d2 (Public-Public Data-DNA) - Team-FV-Stage."
    echo "$PORTAL_END_MARK"
  } > "$work/block.js"
}

# _portal_insert_block <stripped> <out> <blockfile> — Block direkt NACH der
# öffnenden Array-Zeile einfügen (Array-Anfang, nicht Array-Ende).
_portal_insert_block() {
  local stripped="$1" out="$2" block="$3"
  awk -v blk="$block" '
    { l[NR]=$0 }
    /^[A-Za-z_$][^=\[\]]*=[[:space:]]*\[[[:space:]]*$/ { s=NR; ns++ }
    /^\];[[:space:]]*$/ { ne++ }
    END {
      if (ns!=1) { printf "Array-Start nicht eindeutig (%d Treffer)\n", ns > "/dev/stderr"; exit 2 }
      if (ne!=1) { printf "Array-Ende \"];\" nicht eindeutig (%d Treffer)\n", ne > "/dev/stderr"; exit 2 }
      for (i=1;i<=s;i++) print l[i]
      while ((getline x < blk) > 0) print x
      for (i=s+1;i<=NR;i++) print l[i]
    }' "$stripped" > "$out"
}

# _portal_validate_in_pod <candidate> — Syntax-/Duplikatprüfung mit Node im Pod.
_portal_validate_in_pod() {
  local candidate="$1"
  if kubectl -n "$PORTAL_NS" exec "$PORTAL_DEPLOY" -- sh -c 'command -v node' >/dev/null 2>&1; then
    kubectl -n "$PORTAL_NS" exec -i "$PORTAL_DEPLOY" -- sh -c 'cat > /tmp/apps.candidate.js && node -e "const a=require(\"/tmp/apps.candidate.js\"); const ids=a.map(x=>x.id); if(new Set(ids).size!==ids.length) throw new Error(\"doppelte ids\"); console.log(ids.length+\" Apps: \"+ids.join(\" \"))"; rc=$?; rm -f /tmp/apps.candidate.js; exit $rc' < "$candidate" \
      || { _portal_die "Kandidat syntaktisch ungueltig oder doppelte IDs - nichts angewendet"; return 1; }
  else
    log_warn "kein node im Portal-Pod gefunden - Syntaxpruefung uebersprungen"
  fi
}

# _portal_show_diff <a> <b> — Diff (delta wenn vorhanden, sonst diff).
_portal_show_diff() {
  if command -v delta >/dev/null 2>&1; then delta "$1" "$2" || true; else diff -u "$1" "$2" || true; fi
}

# _portal_backup <work> — Backup der ConfigMap + current.js.
_portal_backup() {
  local work="$1"
  mkdir -p "$PORTAL_BACKUP_DIR" || { _portal_die "Backup-Verzeichnis nicht anlegbar: $PORTAL_BACKUP_DIR"; return 1; }
  chmod 700 "$PORTAL_BACKUP_DIR"
  local ts; ts="$(date +%Y%m%dT%H%M%S)"
  kubectl -n "$PORTAL_NS" get cm "$PORTAL_CM" -o yaml > "$PORTAL_BACKUP_DIR/apps.js-cm-$ts.yaml"
  cp "$work/current.js" "$PORTAL_BACKUP_DIR/apps.js-$ts.js"
  log "Backup: $PORTAL_BACKUP_DIR/apps.js-cm-$ts.yaml"
}

# _portal_apply_cm <candidate> — ConfigMap server-side anwenden + Restart.
_portal_apply_cm() {
  local candidate="$1"
  kubectl -n "$PORTAL_NS" create configmap "$PORTAL_CM" --from-file="$PORTAL_KEY=$candidate" --dry-run=client -o yaml \
    | kubectl -n "$PORTAL_NS" apply --server-side --field-manager=p2d2-addon-portal --force-conflicts -f - \
    || { _portal_die "ConfigMap apply fehlgeschlagen"; return 1; }
  # subPath-Mount aktualisiert sich nicht selbst -> Restart zwingend (nginx + url_checker)
  kubectl -n "$PORTAL_NS" rollout restart "$PORTAL_DEPLOY" || { _portal_die "rollout restart fehlgeschlagen"; return 1; }
  kubectl -n "$PORTAL_NS" rollout status "$PORTAL_DEPLOY" --timeout=180s || { _portal_die "rollout status fehlgeschlagen"; return 1; }
}

# _portal_status_impl <work> — liest den Zustand und prüft die Hosts (read-only).
_portal_status_impl() {
  local work="$1"
  _portal_fetch_current "$work" || return 1
  log "Marker-Bloecke in ConfigMap: $(grep -c -- "$PORTAL_BEGIN_MARK" "$work/current.js" || true)"
  log "p2d2-IDs in ConfigMap:       $(grep -cE 'id: "p2d2-' "$work/current.js" || true)"
  local i
  for i in $PORTAL_IDS; do
    printf '  %-10s ' "$i"
    curl -sk --max-time 10 --resolve "$PORTAL_DOMAIN:443:$PORTAL_INGRESS_IP" \
      -w ' HTTP %{http_code}\n' "https://$PORTAL_DOMAIN/check?id=$i" || true
  done
  printf '  %-10s ' "apps.js"
  curl -sk --max-time 10 --resolve "$PORTAL_DOMAIN:443:$PORTAL_INGRESS_IP" "https://$PORTAL_DOMAIN/apps.js" | grep -cE 'id: "p2d2-' || true
}

# _portal_apply_impl <work> — Kern der apply-Logik.
_portal_apply_impl() {
  local work="$1"
  _portal_fetch_current "$work" || return 1
  _portal_build_block "$work"
  _portal_strip_block "$work/current.js" "$work/stripped.js"
  _portal_insert_block "$work/stripped.js" "$work/candidate.js" "$work/block.js" || return 1
  if cmp -s "$work/current.js" "$work/candidate.js"; then
    log "Keine Aenderung noetig (idempotent)"
    _portal_status_impl "$work" || true
    return 0
  fi
  _portal_show_diff "$work/current.js" "$work/candidate.js"
  _portal_validate_in_pod "$work/candidate.js" || return 1
  _portal_backup "$work" || return 1
  _portal_apply_cm "$work/candidate.js" || return 1
  log_ok "Service-Portal-Kacheln angewendet"
  _portal_status_impl "$work" || true
  return 0
}

# _portal_remove_impl <work> — Kern der remove-Logik.
_portal_remove_impl() {
  local work="$1"
  _portal_fetch_current "$work" || return 1
  if ! grep -q -- "$PORTAL_BEGIN_MARK" "$work/current.js"; then
    log "Kein p2d2-Block vorhanden - nichts zu tun"
    return 0
  fi
  _portal_strip_block "$work/current.js" "$work/candidate.js"
  _portal_show_diff "$work/current.js" "$work/candidate.js"
  _portal_validate_in_pod "$work/candidate.js" || return 1
  _portal_backup "$work" || return 1
  _portal_apply_cm "$work/candidate.js" || return 1
  log_ok "Service-Portal-Kacheln entfernt"
  return 0
}

# ── Verifikation (portal_verify) ───────────────────────────────────────────────
# Zähler sind Modul-weit (werden in portal_verify zurückgesetzt). _portal_vcheck
# nutzt eine Zuweisung (kein ((++))), damit set -e nicht auf 0-Ergebnis scheitert.
_PORTAL_FAILS=0
_PORTAL_WARNS=0

_portal_vcheck() {  # $1 = Beschreibung, $2 = 0 (ok) | 1 (fail)
  if [[ "$2" -eq 0 ]]; then
    log_ok "$1"
  else
    log_error "$1"
    _PORTAL_FAILS=$((_PORTAL_FAILS + 1))
  fi
}

# _portal_verify_impl — prüft Marker-Block, ID-Reihenfolge und /check?id=.
_portal_verify_impl() {
  local expected="p2d2-main p2d2-dev p2d2-de1 p2d2-de2 p2d2-fv"

  # 1) Genau 1 Marker-Block in der ConfigMap.
  local current marker_count
  current="$(kubectl -n "$PORTAL_NS" get cm "$PORTAL_CM" -o jsonpath='{.data.apps\.js}' 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    log_error "Portal-Kacheln: ConfigMap $PORTAL_NS/$PORTAL_CM nicht lesbar oder data[apps.js] leer"
    _PORTAL_FAILS=$((_PORTAL_FAILS + 1))
    return 1
  fi
  marker_count="$(printf '%s' "$current" | grep -c -- "$PORTAL_BEGIN_MARK" || true)"
  if [[ "$marker_count" == "1" ]]; then
    _portal_vcheck "genau 1 Marker-Block in apps.js" 0
  else
    _portal_vcheck "genau 1 Marker-Block in apps.js (gefunden: ${marker_count})" 1
    if [[ "$marker_count" == "0" ]]; then
      log_warn "Hinweis: Kein p2d2-Block vorhanden. portal_apply erneut ausfuehren (z. B. nach CIVITAS-Ansible-Lauf)."
    fi
  fi

  # 2) Reihenfolge der 5 IDs auf der ausgelieferten https://<domain>/apps.js (mit Retry).
  local order first_five attempt ok=0
  for ((attempt = 1; attempt <= PORTAL_VERIFY_RETRIES; attempt++)); do
    order="$(curl -sk --max-time 15 --resolve "$PORTAL_DOMAIN:443:$PORTAL_INGRESS_IP" "https://$PORTAL_DOMAIN/apps.js" 2>/dev/null \
      | grep -oE 'id: "[^"]+"' | sed -E 's/id: "([^"]+)"/\1/' | tr '\n' ' ' || true)"
    first_five="$(printf '%s' "$order" | awk '{ for(i=1;i<=5;i++) printf "%s%s", $i, (i<5 ? " " : "") }')"
    if [[ "$first_five" == "$expected" ]]; then ok=1; break; fi
    [[ "$attempt" -lt "$PORTAL_VERIFY_RETRIES" ]] && sleep "$PORTAL_VERIFY_DELAY"
  done
  if [[ "$ok" -eq 1 ]]; then
    _portal_vcheck "5 IDs in Reihenfolge und vor allen Nicht-p2d2-Eintraegen" 0
  else
    _portal_vcheck "5 IDs in Reihenfolge und vor allen Nicht-p2d2-Eintraegen (Ist: ${first_five:-<leer>})" 1
  fi

  # 3) /check?id=<id> je ID (mit Retry).
  local id code attempt
  for id in $PORTAL_IDS; do
    code=""
    for ((attempt = 1; attempt <= PORTAL_VERIFY_RETRIES; attempt++)); do
      code="$(curl -sk --max-time 15 --resolve "$PORTAL_DOMAIN:443:$PORTAL_INGRESS_IP" -o /dev/null -w '%{http_code}' "https://$PORTAL_DOMAIN/check?id=$id" 2>/dev/null || true)"
      [[ "$code" == "200" || "$code" == "404" ]] && break
      [[ "$attempt" -lt "$PORTAL_VERIFY_RETRIES" ]] && sleep "$PORTAL_VERIFY_DELAY"
    done
    case "$code" in
      200) _portal_vcheck "/check?id=$id (HTTP 200)" 0 ;;
      404) _portal_vcheck "/check?id=$id (HTTP 404, App unbekannt)" 1 ;;
      *)   _PORTAL_WARNS=$((_PORTAL_WARNS + 1))
           log_warn "/check?id=$id HTTP ${code} (WARN — sporadische TLS-Abbrueche am Edge bekannt)" ;;
    esac
  done

  if [[ "$_PORTAL_FAILS" -eq 0 ]]; then
    log_ok "Portal-Kacheln-Verifikation: bestanden (${_PORTAL_WARNS} WARN)"
    return 0
  fi
  log_error "Portal-Kacheln-Verifikation: ${_PORTAL_FAILS} FAIL"
  return 1
}

# ── Öffentliche Funktionen (von p2d2-civitas-addon-v1s.sh aufgerufen) ──────────

portal_status() {
  log "=== AddOn 35: Service-Portal-Kacheln (status) ==="
  local work rc=0
  work="$(mktemp -d)"
  _portal_status_impl "$work" || rc=$?
  rm -rf "$work"
  return "$rc"
}

portal_apply() {
  log "=== AddOn 35: Service-Portal-Kacheln (apply) ==="
  local work rc=0
  work="$(mktemp -d)"
  _portal_apply_impl "$work" || rc=$?
  rm -rf "$work"
  return "$rc"
}

portal_remove() {
  log "=== AddOn 35: Service-Portal-Kacheln (remove) ==="
  local work rc=0
  work="$(mktemp -d)"
  _portal_remove_impl "$work" || rc=$?
  rm -rf "$work"
  return "$rc"
}

portal_verify() {
  log "=== AddOn 35: Service-Portal-Kacheln (verify) ==="
  _PORTAL_FAILS=0
  _PORTAL_WARNS=0
  _portal_verify_impl
}

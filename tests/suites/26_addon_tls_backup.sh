#!/usr/bin/env bash
# Suite 26: Teil B — AddOn-Zertifikats-Backup (addon_restore_tls_backup /
# addon_export_tls_backup / addon_tls_backup_relevant). Nur Stubs, kein Cluster/Netz.

begin_suite "addon_tls_backup"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"

LOG_BUF="$T/log"
log()      { echo "L:$*" >> "$LOG_BUF"; }
log_ok()   { echo "O:$*" >> "$LOG_BUF"; }
log_warn() { echo "W:$*" >> "$LOG_BUF"; }
log_error(){ echo "E:$*" >> "$LOG_BUF"; }

export ADDON_NS="cc-prd-geodata-stack"
export ADDON_DOMAIN="udp.example.org"
export VM_REMOTE_INSTALL_DIR="$T/install"
mkdir -p "$VM_REMOTE_INSTALL_DIR"
# shellcheck disable=SC1090,SC1091
source "$REPO/modules_addon_V1s/addon_30_frontend.sh"
set +e

# ── Helfer: gültiges/ungültiges TLS-Secret-JSON erzeugen ──────────────────────
# mk_tls_json <name> <host> <issuer_cn> <namespace> [extra_san] [key_file]
mk_tls_json() {
  local name="$1" host="$2" issuer_cn="$3" ns="$4" extra_san="${5:-}" key_file="${6:-}"
  local crt key
  crt="$(mktemp)"; key="$(mktemp)"
  [[ -n "$key_file" ]] && key="$key_file"
  local san="DNS:${host}"
  [[ -n "$extra_san" ]] && san="${san},DNS:${extra_san}"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$crt" \
    -days 90 -subj "/CN=${issuer_cn}" -addext "subjectAltName=${san}" 2>/dev/null
  printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s"},"type":"kubernetes.io/tls","data":{"tls.crt":"%s","tls.key":"%s"}}' \
    "$name" "$ns" "$(base64 -w0 < "$crt")" "$(base64 -w0 < "$key")"
  rm -f "$crt"
  [[ -n "$key_file" ]] || rm -f "$key"
}

# ── addon_tls_backup_relevant (reine Funktion) ────────────────────────────────
valid="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack)"
addon_tls_backup_relevant "$valid" "www.udp.example.org" 30
check "B relevant gültig: rc=0" "0" "$?"

wrong_type="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack)"
wrong_type="$(printf '%s' "$wrong_type" | jq '.type = "Opaque"')"
addon_tls_backup_relevant "$wrong_type" "www.udp.example.org" 30
check "B falscher Typ: rc=1" "1" "$?"

wrong_ns="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-other)"
addon_tls_backup_relevant "$wrong_ns" "www.udp.example.org" 30
check "B falscher Namespace: rc=1" "1" "$?"

staging="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt STAGING' cc-prd-geodata-stack)"
addon_tls_backup_relevant "$staging" "www.udp.example.org" 30
check "B Staging: rc=1" "1" "$?"

foreign_san="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack 'evil.example.com')"
addon_tls_backup_relevant "$foreign_san" "www.udp.example.org" 30
check "B fremde SAN: rc=1" "1" "$?"

# Kurze Restlaufzeit + hoher min_days -> checkend fehlgeschlagen.
short_valid="$(mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack)"
addon_tls_backup_relevant "$short_valid" "www.udp.example.org" 600
check "B Restlaufzeit zu kurz: rc=1" "1" "$?"

# Key-Mismatch: Zertifikat von Schlüssel A, key-Feld von Schlüssel B.
crt_a="$(mktemp)"; key_a="$(mktemp)"; key_b="$(mktemp)"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key_a" -out "$crt_a" \
  -days 90 -subj "/CN=Let's Encrypt" -addext "subjectAltName=DNS:www.udp.example.org" 2>/dev/null
openssl genpkey -algorithm RSA -out "$key_b" 2>/dev/null
mismatch="$(printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"www.udp.example.org-tls","namespace":"cc-prd-geodata-stack"},"type":"kubernetes.io/tls","data":{"tls.crt":"%s","tls.key":"%s"}}' "$(base64 -w0 < "$crt_a")" "$(base64 -w0 < "$key_b")")"
rm -f "$crt_a" "$key_a" "$key_b"
addon_tls_backup_relevant "$mismatch" "www.udp.example.org" 30
check "B Key-Mismatch: rc=1" "1" "$?"

# Keine Zertifikats-/Schlüsselinhalte im Log.
check "B kein Zertifikatsinhalt im Log" "0" "$(grep -c -- 'BEGIN CERTIFICATE\|BEGIN PRIVATE KEY' "$LOG_BUF")"

# ── addon_restore_tls_backup ──────────────────────────────────────────────────
backup_file="$T/install/../p2d2-le-certs-backup.yaml"
# fünf gültige Einträge bauen
{
  mk_tls_json www.udp.example.org-tls www.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack; echo
  mk_tls_json dev.udp.example.org-tls dev.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack; echo
  mk_tls_json f-de1.udp.example.org-tls f-de1.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack; echo
  mk_tls_json f-de2.udp.example.org-tls f-de2.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack; echo
  mk_tls_json f-fv.udp.example.org-tls f-fv.udp.example.org 'Let'"'"'s Encrypt' cc-prd-geodata-stack; echo
} | jq -s '.' > "$backup_file"

EXISTING_SECRETS=""
APPLY_COUNT="$T/apply_count"
: > "$APPLY_COUNT"
kubectl() {
  case "$*" in
    *"get secret"*)
      local n
      n="$(printf '%s' "$*" | sed -n 's/.*get secret \([^ ]*\).*/\1/p')"
      for s in $EXISTING_SECRETS; do [[ "$s" == "$n" ]] && return 0; done
      return 1 ;;
    *"apply"*) echo x >> "$APPLY_COUNT"; return 0 ;;
    *) return 0 ;;
  esac
}

addon_restore_tls_backup >/dev/null 2>&1
check "B restore alle fehlend: 5 apply" "5" "$(wc -l < "$APPLY_COUNT")"

# Vorhandenes Secret bleibt unverändert (nur 4 werden eingespielt).
: > "$APPLY_COUNT"
EXISTING_SECRETS="www.udp.example.org-tls"
addon_restore_tls_backup >/dev/null 2>&1
check "B restore vorhandenes Secret unveraendert: 4 apply" "4" "$(wc -l < "$APPLY_COUNT")"

# ── addon_export_tls_backup ───────────────────────────────────────────────────
# kubectl get secret liefert die 5 Secrets; ADDON_CERT_ISSUER_RESOLVED=acme.
ADDON_CERT_ISSUER_RESOLVED="letsencrypt-prod"
SECRET_MAP=""
mk_secret_map() {
  for stage in main dev de1 de2 fv; do
    case "$stage" in
      main) h="www.udp.example.org" ;; dev) h="dev.udp.example.org" ;;
      de1) h="f-de1.udp.example.org" ;; de2) h="f-de2.udp.example.org" ;;
      fv) h="f-fv.udp.example.org" ;;
    esac
    SECRET_MAP="${SECRET_MAP}${h}-tls $(mk_tls_json "${h}-tls" "$h" 'Let'"'"'s Encrypt' cc-prd-geodata-stack)"$'\n'
  done
}
mk_secret_map
export TARGET_FILE="$T/export.yaml"
kubectl() {
  case "$*" in
    *"get secret"*"-o json"*)
      local n
      n="$(printf '%s' "$*" | sed -n 's/.*get secret \([^ ]*\) -o json.*/\1/p')"
      printf '%s\n' "$SECRET_MAP" | awk -v n="$n" '$1 == n { $1=""; sub(/^ /,""); print; exit }'
      return 0 ;;
    *) return 0 ;;
  esac
}
VM_REMOTE_INSTALL_DIR="$T/expdir"; mkdir -p "$VM_REMOTE_INSTALL_DIR"
addon_export_tls_backup >/dev/null 2>&1
check "B export acme: Datei angelegt" "yes" "$([[ -f "$T/expdir/../p2d2-le-certs-backup.yaml" ]] && echo yes || echo no)"
check "B export acme: 0600" "yes" "$([[ "$(stat -c '%a' "$T/expdir/../p2d2-le-certs-backup.yaml" 2>/dev/null)" == "600" ]] && echo yes || echo no)"

# Nicht-ACME-Issuer -> kein Export.
rm -f "$T/expdir/../p2d2-le-certs-backup.yaml"
ADDON_CERT_ISSUER_RESOLVED="selfsigned-issuer"
addon_export_tls_backup >/dev/null 2>&1
check "B export non-acme: keine Datei" "no" "$([[ -f "$T/expdir/../p2d2-le-certs-backup.yaml" ]] && echo yes || echo no)"

# ── Statisch: Reihenfolge im Hauptskript ──────────────────────────────────────
check "B restore vor cert-preflight" "yes" "$(awk '/addon_restore_tls_backup/{r=NR} /addon_preflight_cert_issuer/{p=NR} END{if(r&&p&&r<p) print "yes"; else print "no"}' "$MAIN")"
check "B Hinweg vor Hop" "yes" "$(awk '/TLS-Backup konnte nicht in die VM kopiert/{h=NR} /TLS-Backup zurückgeholt/{r=NR} END{if(h&&r&&h<r) print "yes"; else print "no"}' "$MAIN")"
check "B Rueckweg vor Exit-Auswertung" "yes" "$(grep -q 'ssh_exit' "$MAIN" && grep -q 'TLS-Backup zurückgeholt' "$MAIN" && echo yes || echo no)"

rm -rf "$T"

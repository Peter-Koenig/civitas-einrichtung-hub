#!/usr/bin/env bash
# Suite 09: 06a_network_certs.sh — backup_usable / resolve_target_state /
# cluster_backup_diverges. Zertifikate werden mit openssl selbstsigniert
# erzeugt (unterschiedliche Laufzeit und Domain), kein Netzwerk.

begin_suite "backup_lifecycle"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Globale, die 06a_network_certs.sh erwartet.
CERT_BACKUP_MIN_DAYS=30
DOMAIN="udp.example.com"
LE_REQUESTS_BLOCKED=false

# shellcheck source=../../modules_V1/06a_network_certs.sh
source "$REPO/modules_V1/06a_network_certs.sh"
set +e

# ── yq-Stub ──────────────────────────────────────────────────────────────────
# Das reale yq auf sdt ist kislyuk 3.x (falscher Flavor). Der Stub bildet nur
# die beiden eval-Muster von backup_usable/cluster_backup_diverges nach:
#   a) Enumeration "select(.kind == \"Secret\") …namespace/…name"
#   b) Extraktion ".data[\"tls.crt\"]" für ein benanntes Secret
yq() {
  local expr="$2" file="$3"
  if [[ "$expr" == *'.kind == "Secret"'* ]]; then
    awk '/^  name:/ { name=$2 } /^  namespace:/ { print $2"/"name }' "$file"
  elif [[ "$expr" == *'.data["tls.crt"]'* ]]; then
    local want="${expr#*select(.metadata.name == \"}"
    want="${want%%\"*}"
    awk -v want="$want" '/^  name:/ { name=$2; m=(name==want) } /^  tls.crt:/ { if (m) print $2 }' "$file"
  fi
  return 0
}

# ── Fixture-Helfer ──────────────────────────────────────────────────────────
# Erzeugt ein selbstsigniertes Zertifikat mit gewünschter Laufzeit und SAN.
gen_cert() {
  local dir="$1" days="$2" san="$3"
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" \
    -days "$days" -nodes -subj "/CN=udp.example.com" \
    -addext "subjectAltName=$san" 2>/dev/null
}

# Baut ein Single-Secret-Backup (kind: Secret, name: host1-tls, ns: ns1).
mk_backup() {
  local f="$1" cert="$2" key="$3"
  local cert_b64 key_b64
  cert_b64=$(base64 -w0 "$cert")
  key_b64=$(base64 -w0 "$key")
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: host1-tls\n  namespace: ns1\ndata:\n'
    printf '  tls.crt: %s\n' "$cert_b64"
    printf '  tls.key: %s\n' "$key_b64"
    printf '%s\n' '---'
  } > "$f"
}

# ── Zertifikate erzeugen ─────────────────────────────────────────────────────
mkdir -p "$T/valid" "$T/wrong" "$T/short"
gen_cert "$T/valid" 90 "DNS:udp.example.com,DNS:*.udp.example.com"
gen_cert "$T/wrong" 90 "DNS:wrong.example.com"
gen_cert "$T/short" 10 "DNS:udp.example.com"

mk_backup "$T/valid.yaml" "$T/valid/cert.pem" "$T/valid/key.pem"
mk_backup "$T/wrong.yaml" "$T/wrong/cert.pem" "$T/wrong/key.pem"
mk_backup "$T/short.yaml" "$T/short/cert.pem" "$T/short/key.pem"

VALID_CERT_B64=$(base64 -w0 "$T/valid/cert.pem")
WRONG_CERT_B64=$(base64 -w0 "$T/wrong/cert.pem")

# ── backup_usable ────────────────────────────────────────────────────────────
# B1: falsche Domain -> unbrauchbar (1)
: > "$LOGBUF"
LE_REQUESTS_BLOCKED=false
backup_usable "$T/wrong.yaml"; rc=$?
check "backup_usable falsche Domain -> 1" "1" "$rc"

# B2: Restlaufzeit unter Minimum -> unbrauchbar (1)
: > "$LOGBUF"
backup_usable "$T/short.yaml"; rc=$?
check "backup_usable kurze Restlaufzeit -> 1" "1" "$rc"

# B3: passendes Backup -> brauchbar (0)
: > "$LOGBUF"
backup_usable "$T/valid.yaml"; rc=$?
check "backup_usable passend -> 0" "0" "$rc"

# B4: LE_REQUESTS_BLOCKED=true + kurze Restlaufzeit -> brauchbar (0)
: > "$LOGBUF"
LE_REQUESTS_BLOCKED=true
backup_usable "$T/short.yaml"; rc=$?
check "backup_usable blocked + kurz -> 0" "0" "$rc"
LE_REQUESTS_BLOCKED=false

# B5: kein Zertifikatsinhalt auf der Konsole (nur Secret-Name/Grund)
: > "$LOGBUF"
backup_usable "$T/wrong.yaml" >/dev/null 2>&1
check "backup_usable kein Zertifikatsinhalt" "no" "$(grep -q 'BEGIN CERTIFICATE\|BEGIN PRIVATE KEY' "$LOGBUF" && echo yes || echo no)"

# ── resolve_target_state ─────────────────────────────────────────────────────
# R1: unbrauchbares Backup wird ignoriert -> request_prod (LE_CERT=true)
CERT_BACKUP_FILE="$T/wrong.yaml"
LE_CERT=true
check "resolve_target_state unbrauchbar -> request_prod" "request_prod" "$(resolve_target_state)"

# R2: brauchbares Backup -> restore_backup
CERT_BACKUP_FILE="$T/valid.yaml"
check "resolve_target_state brauchbar -> restore_backup" "restore_backup" "$(resolve_target_state)"

# ── cluster_backup_diverges ──────────────────────────────────────────────────
CERT_BACKUP_FILE="$T/valid.yaml"

# D1: Cluster-tls.crt weicht ab -> 0 (Backup neu schreiben)
kubectl() { printf '%s' "$WRONG_CERT_B64"; }
cluster_backup_diverges; rc=$?
check "cluster_backup_diverges abweichend -> 0" "0" "$rc"

# D2: Cluster-tls.crt identisch -> 1 (kein Neuschreiben)
kubectl() { printf '%s' "$VALID_CERT_B64"; }
cluster_backup_diverges; rc=$?
check "cluster_backup_diverges identisch -> 1" "1" "$rc"

# D3: ohne Backup-Datei -> 1 (nichts zu vergleichen)
CERT_BACKUP_FILE="$T/nonexistent.yaml"
cluster_backup_diverges; rc=$?
check "cluster_backup_diverges ohne Backup -> 1" "1" "$rc"

rm -rf "$T"

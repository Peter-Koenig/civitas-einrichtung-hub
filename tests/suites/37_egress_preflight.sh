#!/usr/bin/env bash
# Suite 37: check_helm_repo_egress + apply_ipv4_preference — Egress-Preflight und
# IPv4-Präferenz. Nur Stubs (curl, yq), kein Cluster/Netz.

begin_suite "egress_preflight"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
LOGBUF="$T/console.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Suite-spezifische Stubs (vor den globalen tests/stubs im PATH).
STUBS="$T/stubs"; mkdir -p "$STUBS"
export PATH="$STUBS:$PATH"

cat > "$STUBS/yq" <<'YQ'
#!/usr/bin/env bash
case "$*" in
  *helm_repo_url*)
    case "${YQ_MODE:-ok}" in
      ok)    printf 'https://charts.jetstack.io/\nhttps://helm.runix.net/\n' ;;
      empty) : ;;
      error) echo "yq: Error: unknown operator 'objects'" >&2; exit 1 ;;
    esac
    ;;
esac
exit 0
YQ
chmod +x "$STUBS/yq"

cat > "$STUBS/curl" <<'CURL'
#!/usr/bin/env bash
url=""
ipv6=0
for a in "$@"; do
  case "$a" in
    -6) ipv6=1 ;;
    http*) url="$a" ;;
  esac
done
if [ "$ipv6" = "1" ]; then
  [ "${CURL_IPV6_PROBE:-ok}" = "fail" ] && exit 1
  exit 0
fi
base="${url%/index.yaml}"
case " ${CURL_FAIL_URLS:-} " in
  *" ${base} "*) exit 1 ;;
esac
exit 0
CURL
chmod +x "$STUBS/curl"

# Fixture-Repositorystruktur (die yq-Query liefert die URLs aus dem Stub).
export CC_V1_REPO_PATH="$T/repo"
mkdir -p "$CC_V1_REPO_PATH/core_platform/vars"
touch "$CC_V1_REPO_PATH/core_platform/vars/software_references.yml"

# shellcheck source=../../modules_V1s/06_civitas.sh
source "$REPO/modules_V1s/06_civitas.sh"

# ── CC_EGRESS_CHECK-Modi ─────────────────────────────────────────────────────
export CC_EGRESS_CHECK=strict
export CURL_FAIL_URLS=""
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "strict alle erreichbar -> rc=0" "0" "$rc"

export CC_EGRESS_CHECK=strict
export CURL_FAIL_URLS="https://charts.jetstack.io"
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "strict eine nicht erreichbar -> rc=1" "1" "$rc"

export CC_EGRESS_CHECK=warn
export CURL_FAIL_URLS="https://charts.jetstack.io"
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "warn eine nicht erreichbar -> rc=0" "0" "$rc"

export CC_EGRESS_CHECK=off
: > "$LOGBUF"
check_helm_repo_egress >/dev/null 2>&1
check "off übersprungen" "yes" "$(grep -q 'übersprungen' "$LOGBUF" && echo yes || echo no)"

# ── F1: yq-Fehler / leere Liste / fehlende Datei ────────────────────────────
export CC_EGRESS_CHECK=strict
export YQ_MODE=error
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 yq-Fehler strict -> rc=1" "1" "$rc"

export CC_EGRESS_CHECK=warn
export YQ_MODE=error
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 yq-Fehler warn -> rc=0" "0" "$rc"

export CC_EGRESS_CHECK=strict
export YQ_MODE=empty
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 leere Liste strict -> rc=1" "1" "$rc"

export CC_EGRESS_CHECK=warn
export YQ_MODE=empty
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 leere Liste warn -> rc=0" "0" "$rc"

export CC_EGRESS_CHECK=strict
export YQ_MODE=ok
rm -f "$CC_V1_REPO_PATH/core_platform/vars/software_references.yml"
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 fehlende Datei strict -> rc=1" "1" "$rc"

export CC_EGRESS_CHECK=warn
( check_helm_repo_egress >/dev/null 2>&1 ); rc=$?
check "F1 fehlende Datei warn -> rc=0" "0" "$rc"
touch "$CC_V1_REPO_PATH/core_platform/vars/software_references.yml"

# ── Echter mikefarah-yq gegen eine strukturell echte Fixture ───────────────
if yq --version 2>/dev/null | grep -q mikefarah; then
  cat > "$T/fixture.yml" <<'FIX'
software:
  stack_op:
    pgadmin:
      helm_repo_url: https://helm.runix.net/
    velero:
      helm_repo_url: https://vmware-tanzu.github.io/helm-charts
  stack_access:
    apisix:
      helm_repo_url: https://apache.github.io/apisix-helm-chart
FIX
  out="$(yq -r '.. | select(tag == "!!map") | select(has("helm_repo_url")) | .helm_repo_url' "$T/fixture.yml" 2>/dev/null | sort -u)"
  check "F1 echter yq-Filter liefert 3 URLs" "3" "$(printf '%s' "$out" | grep -c '^https')"
else
  echo "SKIP: kein mikefarah-yq im Testumfeld (sdt hat Python-yq) — echter-yq-Filter-Test entfällt"
fi

# ── apply_ipv4_preference (GAI_CONF auf Temp-Pfad) ────────────────────────────
export GAI_CONF="$T/gai.conf"
export NET_PREFER_IPV4=auto
export CURL_IPV6_PROBE=fail
( apply_ipv4_preference >/dev/null 2>&1 )
check "auto probe fail -> gai geschrieben" "yes" \
  "$([[ -f "$GAI_CONF" ]] && grep -q 'precedence ::ffff:0:0/96 100' "$GAI_CONF" && echo yes || echo no)"

( apply_ipv4_preference >/dev/null 2>&1 )
check "idempotent: genau eine precedence-Zeile" "1" "$(grep -c 'precedence ::ffff:0:0/96 100' "$GAI_CONF")"

export NET_PREFER_IPV4=auto
export CURL_IPV6_PROBE=ok
export GAI_CONF="$T/gai2.conf"
( apply_ipv4_preference >/dev/null 2>&1 )
check "auto probe ok -> keine gai-Datei" "no" "$([[ -f "$T/gai2.conf" ]] && echo yes || echo no)"

export NET_PREFER_IPV4=never
export GAI_CONF="$T/gai3.conf"
( apply_ipv4_preference >/dev/null 2>&1 )
check "never -> keine gai-Datei" "no" "$([[ -f "$T/gai3.conf" ]] && echo yes || echo no)"

rm -rf "$T"

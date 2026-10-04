#!/usr/bin/env bash
# Suite 15: addon_ssh_select_key — Schlüsselwahl für den Host→VM-Hop.
# Nur Testwerte, kein Cluster/Netz.

begin_suite "addon_ssh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
LOGBUF="$T/console.log"
SSH_LOG="$T/ssh.log"
SCP_LOG="$T/scp.log"

log()      { echo "L:$*" >> "$LOGBUF"; }
log_ok()   { echo "O:$*" >> "$LOGBUF"; }
log_warn() { echo "W:$*" >> "$LOGBUF"; }
log_error(){ echo "E:$*" >> "$LOGBUF"; }

# Modul-Umgebung.
VM_IP_STATIC="192.0.2.10"
ADDON_SSH_KNOWN_HOSTS="$T/known_hosts"
ADDON_ENV_FILE="$T/no-such-env"     # Standard: fehlt
SSH_CALL_LOG="$SSH_LOG"
SCP_CALL_LOG="$SCP_LOG"
export SSH_CALL_LOG SCP_CALL_LOG
# Stub-Steuerung exportieren (Stubs sind eigene Prozesse).
export SSH_REJECT SSHKEYGEN_REJECT

# shellcheck disable=SC1090
source "$REPO/modules_addon_V1s/addon_05_ssh.sh"
set +e

# Erreichbarkeit im Test steuerbar (Standard: erreichbar).
VM_REACHABLE=1
addon_ssh_vm_reachable() { [[ "${VM_REACHABLE}" == "1" ]]; }

# run_select — in Subshell, damit exit 1 der Suite nicht die Suite beendet.
run_select() { ( addon_ssh_select_key ); }

# log_has <needle>
log_has() { grep -qF "$1" "$LOGBUF" && echo yes || echo no; }

# reset_case — Zustand zwischen den Testfällen zurücksetzen.
reset_case() {
  : > "$LOGBUF"; : > "$SSH_LOG"; : > "$SCP_LOG"
  SSHKEYGEN_REJECT=""; SSH_REJECT=""; VM_REACHABLE=1
  ADDON_SSH_KEY_FILE=""
  INSTALL_KEY_DIR=""
  unset ADDON_SSH_KEY ADDON_SSH_OPTS
}

# mk_priv <pfad> — legt eine (fiktive) private Schlüsseldatei an (0600).
mk_priv() { printf 'PRIVATE KEY\n' > "$1"; chmod 600 "$1"; }

# ── Test 1: Installer-Schlüssel vorhanden und akzeptiert ─────────────────────
reset_case
KD="$T/kd1"; mkdir -p "$KD"; mk_priv "$KD/id_ed25519"
INSTALL_KEY_DIR="$KD"
run_select; rc=$?
check "1 rc=0" "0" "$rc"
check "1 id_ed25519 gewählt" "yes" "$(log_has "SSH-Zugang: ${KD}/id_ed25519")"
check "1 Fingerprint geloggt" "yes" "$(log_has "Fingerprint:")"
check "1 ssh mit id_ed25519" "yes" "$(grep -qF "ssh -i ${KD}/id_ed25519" "$SSH_LOG" && echo yes || echo no)"

# ── Test 2: erster Kandidat abgelehnt, zweiter akzeptiert ────────────────────
reset_case
KD="$T/kd2"; mkdir -p "$KD"; mk_priv "$KD/id_ed25519"; mk_priv "$KD/beta_key"
INSTALL_KEY_DIR="$KD"
SSH_REJECT="id_ed25519"
run_select; rc=$?
check "2 rc=0" "0" "$rc"
check "2 beta_key gewählt" "yes" "$(log_has "SSH-Zugang: ${KD}/beta_key")"

# ── Test 3: nur ADDON_SSH_KEY_FILE passt (Verzeichnis leer) ──────────────────
reset_case
KD="$T/kd3"; mkdir -p "$KD"
INSTALL_KEY_DIR="$KD"
AK="$T/admin_key"; mk_priv "$AK"
ADDON_SSH_KEY_FILE="$AK"
run_select; rc=$?
check "3 rc=0" "0" "$rc"
check "3 admin_key gewählt" "yes" "$(log_has "SSH-Zugang: ${AK}")"

# ── Test 4: kein Kandidat passt → exit != 0, kein scp ────────────────────────
reset_case
KD="$T/kd4"; mkdir -p "$KD"; mk_priv "$KD/id_ed25519"
INSTALL_KEY_DIR="$KD"
SSH_REJECT="id_ed25519"
run_select; rc=$?
check "4 rc!=0" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "4 kein scp-Aufruf" "0" "$(wc -l < "$SCP_LOG")"

# ── Test 5: Passphrase + *.pub + known_hosts werden übersprungen ─────────────
reset_case
KD="$T/kd5"; mkdir -p "$KD"
printf 'PASSPHRASE\n' > "$KD/passphrase_key"; chmod 600 "$KD/passphrase_key"
printf 'ssh-ed25519 AAAA fake\n' > "$KD/id_ed25519.pub"
printf 'known_hosts content\n' > "$KD/known_hosts"
INSTALL_KEY_DIR="$KD"
SSHKEYGEN_REJECT="passphrase_key"
run_select; rc=$?
check "5 rc!=0" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "5 passphrase übersprungen" "yes" "$(log_has "passphrase_key nicht verwendbar")"
check "5 .pub nicht getestet" "0" "$(grep -cF 'id_ed25519.pub' "$LOGBUF")"
check "5 known_hosts nicht getestet" "0" "$(grep -cF 'known_hosts' "$LOGBUF")"

# ── Test 6: VM nicht erreichbar → eigene Meldung, keine Schlüsselprüfung ─────
reset_case
KD="$T/kd6"; mkdir -p "$KD"; mk_priv "$KD/id_ed25519"
INSTALL_KEY_DIR="$KD"
VM_REACHABLE=0
run_select; rc=$?
check "6 rc!=0" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "6 keine Schlüsselprüfung" "0" "$(wc -l < "$SSH_LOG")"
check "6 eigene Meldung" "yes" "$(log_has "nicht erreichbar")"

# ── Test 7: ADDON_SSH_KEY_FILE fehlt → Warnung, kein Treffer ────────────────
reset_case
KD="$T/kd7"; mkdir -p "$KD"
INSTALL_KEY_DIR="$KD"
ADDON_SSH_KEY_FILE="$T/missing_key"
run_select; rc=$?
check "7 rc!=0" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "7 Warnung fehlende Datei" "yes" "$(log_has "missing_key nicht gefunden")"

# ── Test 8: statisch — kein StrictHostKeyChecking=no, ssh/scp nutzen ADDON_SSH_OPTS ─
MAIN="$REPO/p2d2-civitas-addon-v1s.sh"
check "8 kein StrictHostKeyChecking=no" "0" "$(grep -c 'StrictHostKeyChecking=no' "$MAIN")"
check "8 ssh nutzt ADDON_SSH_OPTS" "yes" "$(grep -qF 'ssh "${ADDON_SSH_OPTS[@]}"' "$MAIN" && echo yes || echo no)"
check "8 scp nutzt ADDON_SSH_OPTS" "yes" "$(grep -qF 'scp "${ADDON_SSH_OPTS[@]}"' "$MAIN" && echo yes || echo no)"

# ── Test 9: --help und unbekannte Argumente wie bisher ───────────────────────
out="$(bash "$MAIN" --help 2>&1)"; rc=$?
check "9 --help rc=0" "0" "$rc"
check "9 --help nennt ADDON_SSH_KEY_FILE" "yes" "$(grep -qF 'ADDON_SSH_KEY_FILE' <<< "$out" && echo yes || echo no)"
out="$(bash "$MAIN" --bogus 2>&1)"; rc=$?
check "9 unbekannt rc!=0" "yes" "$([[ $rc -ne 0 ]] && echo yes || echo no)"

rm -rf "$T"

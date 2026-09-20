#!/usr/bin/env bash
#
# p2d2-Frontend Stage de2 — dünner Wrapper um build-stage.sh (Turn 55).
# Aufruf: ./build-de2.sh  (set -a; source ../.env.p2d2-addon; set +a vorher)
set -euo pipefail
exec "$(dirname "$0")/build-stage.sh" de2

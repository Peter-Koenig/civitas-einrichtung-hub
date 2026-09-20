#!/usr/bin/env bash
#
# p2d2-Frontend Stage main — dünner Wrapper um build-stage.sh (Turn 55).
# Aufruf: ./build-main.sh  (set -a; source ../.env.p2d2-addon; set +a vorher)
set -euo pipefail
exec "$(dirname "$0")/build-stage.sh" main

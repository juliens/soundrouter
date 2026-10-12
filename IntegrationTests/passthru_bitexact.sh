#!/usr/bin/env bash
# Integration (spec J1): pass-thru bit-exact at 48 kHz (and optionally other rates).
#   IntegrationTests/passthru_bitexact.sh [DEVICE_NAME_OR_UID] [RATES...]
# Default device "SoundRouter", rates 48000. The device must contain only the pass-thru
# source (1:1 routes, gain 1), volume 1, no monitor.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-SoundRouter}"
shift || true
RATES=("${@:-48000}")
[[ ${#RATES[@]} -gt 0 ]] || RATES=(48000)
rc=0
for r in "${RATES[@]}"; do
    echo "== pass-thru bit-exact @ $r Hz on '$DEVICE'"
    "$HERE/run_tool.sh" passthru_bitexact --device "$DEVICE" --rate "$r" --seconds 3 || rc=1
done
exit $rc

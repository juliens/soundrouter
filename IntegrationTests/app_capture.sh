#!/usr/bin/env bash
# Integration (spec J2): application capture. A test process (afplay) plays a known signal;
# the engine captures it through a process tap into a SoundRouter device; the device input is
# recorded and correlated with the reference.
#
#   IntegrationTests/app_capture.sh [DEVICE]      (default: creates "SR-IT-Capture")
#
# Needs build/srctl (make srctl, signed with the app's identity) and the Audio Capture
# permission already granted to the engine. The afplay source is matched by executable path.
# If automation is impossible (permissions, XPC refused), follow the manual steps in
# IntegrationTests/README.md ("app_capture — manual").
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRCTL="$ROOT/build/srctl"
[[ -x "$SRCTL" ]] || { echo "build/srctl missing: run 'make srctl'"; exit 1; }
WORK="$(mktemp -d)"
TONE="$WORK/signal.wav"
CREATED=""
cleanup() {
    [[ -n "${AFPLAY_PID:-}" ]] && kill "$AFPLAY_PID" 2>/dev/null || true
    [[ -n "$CREATED" ]] && "$SRCTL" delete-device "$CREATED" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

"$SRCTL" hello
DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
    DEVICE="$("$SRCTL" create-device SR-IT-Capture --rate 48000 --channels 2)"
    CREATED="$DEVICE"
    echo "created device $DEVICE"
    sleep 2   # driver publication
fi
"$SRCTL" add-app "$DEVICE" --path /usr/bin/afplay --no-mute

"$HERE/run_tool.sh" tone_gen "$TONE" --rate 48000 --seconds 12 --kind signal
afplay "$TONE" &
AFPLAY_PID=$!
sleep 2   # tap attaches when the process starts playing

"$HERE/run_tool.sh" capture_check --device "$DEVICE" --reference "$TONE" --seconds 4 --min-corr 0.9
"$SRCTL" status | grep -A3 -i '"state"' | head -20 || true

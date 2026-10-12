#!/usr/bin/env bash
# Integration: driver loaded by coreaudiod, devices visible with the expected formats.
# Run on a Mac with SoundRouter installed and at least one device created.
#   IntegrationTests/driver_visible.sh [--rates 44100,48000,96000]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_JSON="/Library/Application Support/SoundRouter/devices.json"
DRIVER="/Library/Audio/Plug-Ins/HAL/SoundRouter.driver"

echo "== driver bundle"
[[ -d "$DRIVER" ]] || { echo "FAIL: $DRIVER not installed"; exit 1; }
[[ "$(stat -f %Su "$DRIVER")" == root ]] || { echo "FAIL: $DRIVER not owned by root"; exit 1; }
codesign --verify --strict "$DRIVER" && echo "signature ok"

echo "== devices.json"
[[ -r "$DEVICES_JSON" ]] || { echo "FAIL: $DEVICES_JSON missing"; exit 1; }
cat "$DEVICES_JSON"; echo

echo "== system_profiler"
if system_profiler SPAudioDataType 2>/dev/null | grep -i -A6 'SoundRouter'; then :; else
    echo "WARN: no SoundRouter entry in system_profiler (device names are user-defined; checking UIDs below)"
fi

echo "== Core Audio (UID, channels, rate)"
"$HERE/run_tool.sh" list_devices --devices-json "$DEVICES_JSON" "$@"

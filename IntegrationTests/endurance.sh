#!/usr/bin/env bash
# Endurance (spec J3 / test table): run for N hours and log the engine underrun counters.
# Setup (manual, see README.md): a device with two sources at different clock domains, e.g.
# a USB microphone at 44.1 kHz + an application (or pass-thru) on a 48 kHz device, and
# something continuously playing. Exit 1 if any device's underrun counter increased.
#
#   IntegrationTests/endurance.sh [HOURS=8] [INTERVAL_SECONDS=60] [LOGFILE]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRCTL="$ROOT/build/srctl"
HOURS="${1:-8}"
INTERVAL="${2:-60}"
LOG="${3:-$ROOT/build/endurance-$(date +%Y%m%d-%H%M%S).log}"
[[ -x "$SRCTL" ]] || { echo "build/srctl missing: run 'make srctl'"; exit 1; }
mkdir -p "$(dirname "$LOG")"

END=$(( $(date +%s) + $(awk "BEGIN{print int($HOURS*3600)}") ))
BASELINE="$("$SRCTL" underruns)"
echo "endurance: ${HOURS}h, every ${INTERVAL}s, log $LOG"
printf '%s\n' "$BASELINE" | sed 's/^/baseline\t/' | tee -a "$LOG"

errors=0
while [[ $(date +%s) -lt $END ]]; do
    sleep "$INTERVAL"
    ts="$(date '+%Y-%m-%dT%H:%M:%S')"
    if ! now="$("$SRCTL" underruns 2>&1)"; then
        echo "$ts ENGINE-UNREACHABLE $now" | tee -a "$LOG"
        errors=$((errors + 1))
        continue
    fi
    printf '%s\n' "$now" | sed "s/^/$ts\t/" >> "$LOG"
    echo "$ts $(printf '%s' "$now" | awk -F'\t' '{printf "%s=%s ", $2, $3}')"
done

FINAL="$("$SRCTL" underruns)"
fail=0
while IFS=$'\t' read -r id name count; do
    [[ -z "$id" ]] && continue
    base="$(printf '%s\n' "$BASELINE" | awk -F'\t' -v id="$id" '$1==id{print $3}')"
    delta=$(( count - ${base:-0} ))
    echo "$name ($id): +$delta underruns" | tee -a "$LOG"
    [[ $delta -eq 0 ]] || fail=1
done <<< "$FINAL"
[[ $errors -eq 0 ]] || { echo "engine unreachable $errors time(s)" | tee -a "$LOG"; fail=1; }
[[ $fail -eq 0 ]] && echo "PASS" | tee -a "$LOG" || echo "FAIL" | tee -a "$LOG"
exit $fail

#!/usr/bin/env bash
# Compile (cached) and run an integration tool: IntegrationTests/run_tool.sh <tool> [args...]
#   tools: list_devices, passthru_bitexact, tone_gen, capture_check (see IntegrationTests/Tools)
# Binaries go to build/it/<tool>; rebuilt when a source is newer.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/IntegrationTests/Tools"
OUT="$ROOT/build/it"

[[ $# -ge 1 ]] || { echo "usage: $0 <tool> [args...]" >&2; exit 2; }
tool="$1"; shift
src="$TOOLS/$tool.swift"
[[ -f "$src" && "$tool" != srctl && "$tool" != CoreAudioUtil ]] || { echo "unknown tool: $tool" >&2; exit 2; }

mkdir -p "$OUT"
bin="$OUT/$tool"
if [[ ! -x "$bin" || "$src" -nt "$bin" || "$TOOLS/CoreAudioUtil.swift" -nt "$bin" ]]; then
    echo "[run_tool] compiling $tool" >&2
    xcrun swiftc -O -parse-as-library -module-name "$tool" "$TOOLS/CoreAudioUtil.swift" "$src" -o "$bin"
fi
exec "$bin" "$@"

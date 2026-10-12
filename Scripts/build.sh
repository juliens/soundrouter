#!/usr/bin/env bash
# Build SoundRouter (universal release) and assemble + sign build/SoundRouter.app.
#
# Layout: see docs/ARCHITECTURE.md ("App bundle layout").
#
# Environment:
#   SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)". Unset/empty = ad-hoc ("-").
#   SKIP_SWIFT_BUILD=1  do not run swift build; use binaries already in the release scratch path
#                       (or stubs when STUB_BINARIES=1).
#   SKIP_DRIVER_BUILD=1 do not run `make -C Driver`; use an existing build/SoundRouter.driver
#                       (or a stub when STUB_BINARIES=1).
#   STUB_BINARIES=1     use placeholder executables / driver bundle (tests the assembly and
#                       signing logic while the real targets do not build). Skips swift build
#                       and make -C Driver (a real build/SoundRouter.driver is used if present).
#   STUB_DRIVER=1       only the driver is a placeholder (real Swift build).
#   ARCHS               default "arm64 x86_64".
#   SR_SANDBOXED=1      source Scripts/env.sh and pass sandbox-friendly SwiftPM flags.
#   BUILD_NUMBER        CFBundleVersion (default: UTC timestamp YYYYMMDDHHMM).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ -n "$VERSION" ]] || die "VERSION file is empty"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SCRATCH="$ROOT/.build/release"
OUT="$ROOT/build"
APP="$OUT/SoundRouter.app"
ENGINE_APP_REL="Contents/Library/LoginItems/SoundRouterEngine.app"
RES="$ROOT/Resources"

mkdir -p "$OUT"

# ---------------------------------------------------------------- swift build
# (Arrays are never empty: macOS bash 3.2 + set -u rejects "${empty[@]}".)
SWIFT_ARGS=(-c release --scratch-path "$SCRATCH")
for a in $ARCHS; do SWIFT_ARGS+=(--arch "$a"); done
if [[ "${SR_SANDBOXED:-0}" == 1 ]]; then
    # shellcheck source=Scripts/env.sh
    source "$ROOT/Scripts/env.sh"
    SWIFT_ARGS+=(--cache-path "${TMPDIR:-/tmp}/spmcache" --manifest-cache local --disable-sandbox)
fi

APP_BIN="" ENGINE_BIN=""
if [[ "${STUB_BINARIES:-0}" == 1 ]]; then
    log "STUB_BINARIES=1: creating placeholder executables"
    STUB_DIR="$OUT/stubs"
    mkdir -p "$STUB_DIR"
    printf 'int main(void){return 0;}\n' > "$STUB_DIR/stub.c"
    CLANG_ARCHS=()
    for a in $ARCHS; do CLANG_ARCHS+=(-arch "$a"); done
    for n in SoundRouter SoundRouterEngine; do
        if ! xcrun clang "${CLANG_ARCHS[@]}" -mmacosx-version-min=14.2 -o "$STUB_DIR/$n" "$STUB_DIR/stub.c" 2>/dev/null; then
            printf '#!/bin/sh\necho "%s stub"\n' "$n" > "$STUB_DIR/$n"
            chmod +x "$STUB_DIR/$n"
        fi
    done
    APP_BIN="$STUB_DIR/SoundRouter"
    ENGINE_BIN="$STUB_DIR/SoundRouterEngine"
else
    if [[ "${SKIP_SWIFT_BUILD:-0}" != 1 ]]; then
        log "swift build -c release ($ARCHS)"
        swift build "${SWIFT_ARGS[@]}" --product SoundRouterEngine
        swift build "${SWIFT_ARGS[@]}" --product SoundRouter
    fi
    BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
    APP_BIN="$BIN_DIR/SoundRouter"
    ENGINE_BIN="$BIN_DIR/SoundRouterEngine"
fi
[[ -x "$APP_BIN" ]] || die "missing app executable: $APP_BIN"
[[ -x "$ENGINE_BIN" ]] || die "missing engine executable: $ENGINE_BIN"

# ---------------------------------------------------------------- driver
find_driver() {
    local c
    for c in "$OUT/SoundRouter.driver" "$ROOT/Driver/build/SoundRouter.driver"; do
        [[ -d "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
STUB_DRIVER="${STUB_DRIVER:-${STUB_BINARIES:-0}}"
if [[ "${SKIP_DRIVER_BUILD:-0}" != 1 && "$STUB_DRIVER" != 1 ]]; then
    [[ -f "$ROOT/Driver/Makefile" ]] || die "Driver/Makefile not found"
    log "make -C Driver"
    make -C "$ROOT/Driver"
fi
if ! DRIVER_SRC="$(find_driver)"; then
    if [[ "$STUB_DRIVER" == 1 ]]; then
        log "STUB_DRIVER=1: creating placeholder driver bundle"
        DRIVER_SRC="$OUT/stubs/SoundRouter.driver"
        rm -rf "$DRIVER_SRC"
        mkdir -p "$DRIVER_SRC/Contents/MacOS"
        cp "$ENGINE_BIN" "$DRIVER_SRC/Contents/MacOS/SoundRouter"
        cat > "$DRIVER_SRC/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.soundrouter.driver</string>
<key>CFBundleExecutable</key><string>SoundRouter</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
EOF
    else
        die "driver bundle not found (expected build/SoundRouter.driver)"
    fi
fi

# ---------------------------------------------------------------- assemble
fill_plist() { # template dest
    sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$1" > "$2"
    plutil -lint -s "$2" >/dev/null || die "invalid plist: $2"
}

log "assembling $APP"
rm -rf "$APP"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Library/LoginItems" "$C/Library/LaunchAgents"

fill_plist "$RES/App/Info.plist" "$C/Info.plist"
printf 'APPL????' > "$C/PkgInfo"
ditto "$APP_BIN" "$C/MacOS/SoundRouter"
if [[ -f "$RES/App/AppIcon.icns" ]]; then
    cp "$RES/App/AppIcon.icns" "$C/Resources/AppIcon.icns"
    plutil -replace CFBundleIconFile -string AppIcon "$C/Info.plist"
fi

E="$APP/$ENGINE_APP_REL/Contents"
mkdir -p "$E/MacOS" "$E/Resources"
fill_plist "$RES/Engine/Info.plist" "$E/Info.plist"
printf 'APPL????' > "$E/PkgInfo"
ditto "$ENGINE_BIN" "$E/MacOS/SoundRouterEngine"

cp "$RES/io.soundrouter.engine.plist" "$C/Library/LaunchAgents/io.soundrouter.engine.plist"
plutil -lint -s "$C/Library/LaunchAgents/io.soundrouter.engine.plist" >/dev/null

ditto "$DRIVER_SRC" "$C/Resources/SoundRouter.driver"
install -m 0755 "$ROOT/Scripts/install-driver.sh" "$C/Resources/install-driver.sh"
install -m 0755 "$ROOT/Scripts/uninstall.sh" "$C/Resources/uninstall.sh"

# Sanity: BundleProgram must point at the engine executable.
BP="$(plutil -extract BundleProgram raw "$C/Library/LaunchAgents/io.soundrouter.engine.plist")"
[[ -x "$APP/$BP" ]] || die "LaunchAgent BundleProgram does not resolve: $BP"

# ---------------------------------------------------------------- sign (inside-out)
if [[ -n "$SIGN_IDENTITY" ]]; then
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
    log "signing with '$SIGN_IDENTITY' (hardened runtime, timestamp)"
else
    SIGN_ARGS=(--force --sign - --options runtime --timestamp=none)
    log "SIGN_IDENTITY unset: ad-hoc signing (local use only, not distributable)"
fi
sign() { codesign "${SIGN_ARGS[@]}" "$@"; }

# Entitlements (no comments allowed in these files, AMFI rejects them):
#   driver: none (loaded by coreaudiod). engine: device.audio-input (microphones; process taps
#   are gated by TCC through NSAudioCaptureUsageDescription). app: nothing (never touches audio).
#   None is sandboxed; hardened runtime comes from --options runtime.
sign --identifier io.soundrouter.driver --entitlements "$RES/Driver.entitlements" "$C/Resources/SoundRouter.driver"
sign --identifier io.soundrouter.engine --entitlements "$RES/Engine/SoundRouterEngine.entitlements" "$APP/$ENGINE_APP_REL"
sign --identifier io.soundrouter.app --entitlements "$RES/App/SoundRouter.entitlements" "$APP"

log "verifying signature"
codesign --verify --strict --deep --verbose=1 "$APP"
if [[ -n "$SIGN_IDENTITY" ]]; then
    spctl --assess --type execute --verbose "$APP" 2>&1 || warn "spctl rejected the app (expected before notarization)"
fi

log "done: $APP (version $VERSION, build $BUILD_NUMBER)"

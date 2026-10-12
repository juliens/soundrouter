#!/usr/bin/env bash
# Build build/SoundRouter-<version>.pkg from build/SoundRouter.app (run Scripts/build.sh first).
#
# The package installs SoundRouter.app into /Applications; its postinstall runs the app's
# embedded install-driver.sh (driver -> /Library/Audio/Plug-Ins/HAL, support dir, coreaudiod restart).
#
# Environment:
#   INSTALLER_IDENTITY  "Developer ID Installer: Name (TEAMID)" to sign the product archive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/SoundRouter.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PKG="$OUT/SoundRouter-$VERSION.pkg"
WORK="$OUT/pkg-work"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d "$APP" ]] || die "$APP not found; run Scripts/build.sh first"
codesign --verify --strict --deep "$APP" || die "$APP signature is invalid"

rm -rf "$WORK"
mkdir -p "$WORK/root/Applications" "$WORK/scripts"
ditto "$APP" "$WORK/root/Applications/SoundRouter.app"
install -m 0755 "$ROOT/Resources/pkg/scripts/preinstall" "$WORK/scripts/preinstall"
install -m 0755 "$ROOT/Resources/pkg/scripts/postinstall" "$WORK/scripts/postinstall"

# Component plist: never relocate the app to another copy found on disk, allow downgrade-free upgrades.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
plutil -replace 0.BundleOverwriteAction -string upgrade "$WORK/component.plist"

log "pkgbuild"
pkgbuild --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --scripts "$WORK/scripts" \
    --identifier io.soundrouter.pkg.app \
    --version "$VERSION" \
    --install-location / \
    "$WORK/SoundRouter-app.pkg"

sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/pkg/Distribution.xml" > "$WORK/Distribution.xml"

SIGN_ARGS=()
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--sign "$INSTALLER_IDENTITY" --timestamp)
    log "signing with '$INSTALLER_IDENTITY'"
else
    log "INSTALLER_IDENTITY unset: unsigned package (cannot be notarized)"
fi

log "productbuild"
rm -f "$PKG"
productbuild --distribution "$WORK/Distribution.xml" \
    --package-path "$WORK" \
    "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" \
    "$PKG"

[[ -n "${INSTALLER_IDENTITY:-}" ]] && pkgutil --check-signature "$PKG" || true
log "done: $PKG"

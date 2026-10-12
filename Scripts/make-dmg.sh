#!/usr/bin/env bash
# Build build/SoundRouter-<version>.dmg (drag-to-Applications) from build/SoundRouter.app.
# With a DMG install the driver is installed by the app's first-run assistant (admin prompt).
#
# Environment:
#   SIGN_IDENTITY  "Developer ID Application: ..." to sign the disk image (recommended before notarizing).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/SoundRouter.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DMG="$OUT/SoundRouter-$VERSION.dmg"
STAGE="$OUT/dmg-stage"

[[ -d "$APP" ]] || { echo "error: $APP not found; run Scripts/build.sh first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SoundRouter.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "SoundRouter $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
echo "==> done: $DMG"

#!/usr/bin/env bash
# Notarize and staple SoundRouter artifacts (.pkg, .dmg or .app).
#
# usage: NOTARY_PROFILE=<profile> Scripts/notarize.sh build/SoundRouter-0.1.0.pkg [more files...]
#
# Create the keychain profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID> --password <app-specific pw>
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -n "${NOTARY_PROFILE:-}" ]] || die "set NOTARY_PROFILE to a notarytool keychain profile"
[[ $# -gt 0 ]] || die "usage: $0 <file.pkg|file.dmg|App.app>..."

for f in "$@"; do
    [[ -e "$f" ]] || die "not found: $f"
    submit="$f"
    tmpzip=""
    case "$f" in
        *.app|*.app/)
            f="${f%/}"
            tmpzip="$(mktemp -d)/$(basename "$f" .app).zip"
            log "zipping $f"
            ditto -c -k --keepParent "$f" "$tmpzip"
            submit="$tmpzip" ;;
        *.pkg|*.dmg) ;;
        *) die "unsupported artifact: $f" ;;
    esac

    log "submitting $submit"
    out="$(xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    printf '%s\n' "$out"
    status="$(printf '%s' "$out" | plutil -extract status raw - 2>/dev/null || true)"
    id="$(printf '%s' "$out" | plutil -extract id raw - 2>/dev/null || true)"
    [[ -n "$tmpzip" ]] && rm -rf "$(dirname "$tmpzip")"
    if [[ "$status" != "Accepted" ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        die "notarization failed for $f (status: ${status:-unknown})"
    fi

    log "stapling $f"
    xcrun stapler staple "$f"
    xcrun stapler validate "$f"
done
log "done"

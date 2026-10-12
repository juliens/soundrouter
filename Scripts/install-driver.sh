#!/usr/bin/env bash
# Install the SoundRouter HAL driver. Must run as root (sudo, admin prompt, or .pkg postinstall).
#
# usage: install-driver.sh [--no-restart] [path/to/SoundRouter.driver]
#   default driver path: SoundRouter.driver next to this script (app's Contents/Resources).
#
# Idempotent: re-running replaces the driver and keeps the existing devices.json.
set -euo pipefail

HAL_DIR="/Library/Audio/Plug-Ins/HAL"
DEST="$HAL_DIR/SoundRouter.driver"
SUPPORT_DIR="/Library/Application Support/SoundRouter"
DEVICES_JSON="$SUPPORT_DIR/devices.json"

log() { printf '[install-driver] %s\n' "$*"; }
die() { printf '[install-driver] error: %s\n' "$*" >&2; exit 1; }

RESTART=1
SRC=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-restart) RESTART=0 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) SRC="$1" ;;
    esac
    shift
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$SCRIPT_DIR/SoundRouter.driver}"

[[ "$(id -u)" -eq 0 ]] || die "must be run as root (try: sudo $0)"
[[ -d "$SRC" && -f "$SRC/Contents/Info.plist" ]] || die "driver bundle not found: $SRC"
BID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$SRC/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BID" == "io.soundrouter.driver" ]] || die "unexpected bundle identifier '$BID' in $SRC"

# 1. Driver bundle (copy to a temp name, then swap, so coreaudiod never sees a half copy).
log "installing $SRC -> $DEST"
mkdir -p "$HAL_DIR"
TMP="$HAL_DIR/.SoundRouter.driver.installing.$$"
rm -rf "$TMP"
trap 'rm -rf "$TMP"' EXIT
/usr/bin/ditto "$SRC" "$TMP"
chown -R root:wheel "$TMP"
chmod -R go-w "$TMP"
rm -rf "$DEST"
mv "$TMP" "$DEST"
trap - EXIT

# 2. Shared support directory, owned by the console user so the engine agent can write devices.json.
CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || echo root)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    CONSOLE_USER="${SUDO_USER:-}"
fi
mkdir -p "$SUPPORT_DIR"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
    chown "$CONSOLE_USER":staff "$SUPPORT_DIR"
    log "$SUPPORT_DIR owned by $CONSOLE_USER"
else
    log "warning: no console user; $SUPPORT_DIR stays root-owned (re-run after login, or the engine cannot publish devices)"
fi
chmod 0755 "$SUPPORT_DIR"
if [[ ! -s "$DEVICES_JSON" ]]; then
    printf '{"schemaVersion":1,"devices":[]}\n' > "$DEVICES_JSON"
    log "created empty $DEVICES_JSON"
else
    log "keeping existing $DEVICES_JSON"
fi
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]]; then
    chown "$CONSOLE_USER":staff "$DEVICES_JSON"
fi
chmod 0644 "$DEVICES_JSON"

# 3. Restart coreaudiod so it loads the (new) plug-in.
if [[ "$RESTART" -eq 1 ]]; then
    log "restarting coreaudiod"
    if ! /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
        /usr/bin/killall coreaudiod 2>/dev/null || log "warning: could not restart coreaudiod (log out/in or reboot)"
    fi
else
    log "skipping coreaudiod restart (--no-restart)"
fi
log "done"

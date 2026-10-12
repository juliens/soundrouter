#!/usr/bin/env bash
# Uninstall SoundRouter. Must run as root.
#
# usage: uninstall.sh [--keep-config] [--remove-app] [--no-restart]
#   --keep-config  keep ~/Library/Application Support/SoundRouter (config.json + .bak)
#   --remove-app   also delete /Applications/SoundRouter.app
#   --no-restart   do not restart coreaudiod
#
# Removes: engine LaunchAgent (for the console user), HAL driver,
# /Library/Application Support/SoundRouter, user config (unless --keep-config),
# TCC grants of the engine, installer receipts. Shared-memory segments cannot be removed
# from a shell; they disappear when the engine and coreaudiod exit.
set -euo pipefail

log() { printf '[uninstall] %s\n' "$*"; }
die() { printf '[uninstall] error: %s\n' "$*" >&2; exit 1; }

KEEP_CONFIG=0 REMOVE_APP=0 RESTART=1
for arg in "$@"; do
    case "$arg" in
        --keep-config) KEEP_CONFIG=1 ;;
        --remove-app) REMOVE_APP=1 ;;
        --no-restart) RESTART=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done
[[ "$(id -u)" -eq 0 ]] || die "must be run as root (try: sudo $0)"

AGENT_LABEL="io.soundrouter.engine"
CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
    CONSOLE_USER="${SUDO_USER:-}"
fi

# 1. Agent (for the logged-in user). The app should call SMAppService.unregister() before
#    running this; bootout covers the case where it could not.
if [[ -n "$CONSOLE_USER" ]]; then
    CONSOLE_UID="$(id -u "$CONSOLE_USER")"
    log "stopping agent gui/$CONSOLE_UID/$AGENT_LABEL"
    /bin/launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true
    /usr/bin/pkill -x SoundRouterEngine 2>/dev/null || true

    USER_HOME="$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    USER_HOME="${USER_HOME:-/Users/$CONSOLE_USER}"
    if [[ "$KEEP_CONFIG" -eq 0 ]]; then
        log "removing $USER_HOME/Library/Application Support/SoundRouter"
        rm -rf "$USER_HOME/Library/Application Support/SoundRouter"
        rm -rf "$USER_HOME/Library/Logs/SoundRouter"
        rm -f "$USER_HOME/Library/Preferences/io.soundrouter.app.plist" \
              "$USER_HOME/Library/Preferences/io.soundrouter.engine.plist"
    else
        log "keeping user configuration (--keep-config)"
    fi
    # Forget TCC grants (Audio Capture, Microphone) so a reinstall asks again.
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
        /usr/bin/tccutil reset All io.soundrouter.engine >/dev/null 2>&1 || true
else
    log "warning: no console user found; skipping agent and user configuration"
fi

# 2. Driver and shared support directory.
log "removing /Library/Audio/Plug-Ins/HAL/SoundRouter.driver"
rm -rf "/Library/Audio/Plug-Ins/HAL/SoundRouter.driver"
log "removing /Library/Application Support/SoundRouter"
rm -rf "/Library/Application Support/SoundRouter"

# 3. Installer receipts.
for pkg in $(/usr/sbin/pkgutil --pkgs 2>/dev/null | grep '^io\.soundrouter\.' || true); do
    /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1 || true
done

# 4. coreaudiod (unloads the plug-in).
if [[ "$RESTART" -eq 1 ]]; then
    log "restarting coreaudiod"
    if ! /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
        /usr/bin/killall coreaudiod 2>/dev/null || log "warning: could not restart coreaudiod (reboot to finish)"
    fi
fi

# 5. App last (this script may live inside it; bash keeps the open file readable).
if [[ "$REMOVE_APP" -eq 1 ]]; then
    log "removing /Applications/SoundRouter.app"
    rm -rf "/Applications/SoundRouter.app"
fi
log "done"

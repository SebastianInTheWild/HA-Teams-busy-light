#!/bin/bash
#
# Installs (or updates) the Teams Busy Light menu bar app for the current
# macOS user. No administrator rights are needed.
#
# Uses "Teams Busy Light.app" next to this script (release download) or
# builds it with build.sh (needs the Xcode Command Line Tools). Settings of
# the earlier script version (settings.sh) are taken over.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Teams Busy Light.app"
APP_ID="com.teamsbusylight.app"
LABEL="com.teamsbusylight.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
OLD_DIR="$HOME/Library/Application Support/TeamsBusyLight"

if [ -d "$SRC/Teams Busy Light.app" ]; then
    NEW_APP="$SRC/Teams Busy Light.app"
elif [ -f "$SRC/build.sh" ]; then
    bash "$SRC/build.sh"
    NEW_APP="$SRC/build/Teams Busy Light.app"
else
    echo "Teams Busy Light.app not found next to install.sh." >&2
    exit 1
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

# Some installers (e.g. VPN clients) create ~/Library/LaunchAgents as root;
# the app needs it to start at login
if [ ! -w "$HOME/Library/LaunchAgents" ]; then
    echo "$HOME/Library/LaunchAgents is not writable (owner: $(stat -f '%Su' "$HOME/Library/LaunchAgents"))." >&2
    echo "Fix it once with administrator rights, then run this installer again:" >&2
    echo "  sudo chown \"\$(whoami)\" ~/Library/LaunchAgents" >&2
    exit 1
fi

# Stop the running version. The script version was kept alive by its
# LaunchAgent (KeepAlive), so that one is removed; the app writes its own.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if grep -q KeepAlive "$PLIST" 2>/dev/null; then
    rm -f "$PLIST"
fi
pkill -f "TeamsBusyLight/teams-busy-light.sh" 2>/dev/null || true
pkill -f "Teams Busy Light.app/Contents/MacOS/applet" 2>/dev/null || true
# The app sends "offline" when it is stopped
pkill -TERM -x TeamsBusyLight 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x TeamsBusyLight >/dev/null || break
    sleep 0.5
done

# Take over the settings of the script version
if [ -f "$OLD_DIR/settings.sh" ]; then
    # shellcheck disable=SC1091
    OLD_SETTINGS="$(. "$OLD_DIR/settings.sh"; printf '%s\n%s\n%s' "$HA_WEBHOOK_URL" "$HEARTBEAT_SECONDS" "$POLL_SECONDS")"
    { read -r OLD_URL; read -r OLD_HEARTBEAT; read -r OLD_POLL; } <<< "$OLD_SETTINGS"
    if [ -n "$OLD_URL" ] && ! defaults read "$APP_ID" webhookURL >/dev/null 2>&1; then
        defaults write "$APP_ID" webhookURL -string "$OLD_URL"
        case "$OLD_HEARTBEAT" in '' | *[!0-9]*) ;; *) defaults write "$APP_ID" heartbeatSeconds -int "$OLD_HEARTBEAT" ;; esac
        case "$OLD_POLL" in '' | *[!0-9]*) ;; *) defaults write "$APP_ID" pollSeconds -int "$OLD_POLL" ;; esac
        echo "Settings of the previous version taken over."
    fi
fi
rm -rf "$OLD_DIR"

# The AppleScript app of the script version has another signature; forget
# the access granted to it so macOS asks again for the new app
if [ -f "$APP/Contents/MacOS/applet" ]; then
    tccutil reset All "$APP_ID" >/dev/null 2>&1 || true
fi

rm -rf "$APP"
ditto "$NEW_APP" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"

echo "Installed: $APP"
echo "Teams Busy Light runs in the menu bar and starts automatically after login."
echo "Teams Busy Light needs Full Disk Access to read the Teams logs; the app shows the steps."
echo "If macOS asks whether it may find devices on your local network, click Allow."

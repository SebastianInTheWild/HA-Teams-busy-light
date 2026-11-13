#!/bin/bash
#
# Removes Teams Busy Light of the current macOS user.

APP_ID="com.teamsbusylight.app"
LABEL="com.teamsbusylight.agent"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# The app sends "offline" when it is stopped
pkill -TERM -x TeamsBusyLight 2>/dev/null || true
pkill -f "TeamsBusyLight/teams-busy-light.sh" 2>/dev/null || true
pkill -f "Teams Busy Light.app/Contents/MacOS/applet" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x TeamsBusyLight >/dev/null || break
    sleep 0.5
done
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Teams Busy Light.app"
rm -rf "$HOME/Library/Application Support/TeamsBusyLight"
rm -f "$HOME/Library/Logs/TeamsBusyLight.log" "$HOME/Library/Logs/TeamsBusyLight.log.old"
defaults delete "$APP_ID" >/dev/null 2>&1 || true
# Forget the access granted to the app
tccutil reset All "$APP_ID" >/dev/null 2>&1 || true

echo "Teams Busy Light has been removed."

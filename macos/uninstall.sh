#!/bin/bash
#
# Removes the Teams Busy Light sender of the current macOS user.

LABEL="com.teamsbusylight.agent"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "TeamsBusyLight/teams-busy-light.sh" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Teams Busy Light.app"
rm -rf "$HOME/Library/Application Support/TeamsBusyLight"
rm -f "$HOME/Library/Logs/TeamsBusyLight.log"
# Forget the access granted to the app
tccutil reset All com.teamsbusylight.app >/dev/null 2>&1 || true

echo "Teams Busy Light has been removed."

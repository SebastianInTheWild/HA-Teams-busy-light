#!/bin/bash
#
# Installs the Teams Busy Light sender for the current macOS user.
# No administrator rights are needed. Run again to update or change the URL.
#
# The script runs inside a small app ("Teams Busy Light.app") so macOS can
# grant it access to the Teams logs, instead of giving /bin/bash Full Disk
# Access. The app only starts the script, so updating the script or the
# settings does not change the app and the granted access is kept.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/TeamsBusyLight"
APP="$HOME/Applications/Teams Busy Light.app"
APP_ID="com.teamsbusylight.app"
# Increase when the app itself changes; the app is then rebuilt and macOS asks
# for its permissions again
APP_BUILD="3"
LABEL="com.teamsbusylight.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/TeamsBusyLight.log"

# The webhook URL is shown in Home Assistant after adding the
# "Teams Busy Light" integration (and later in its options).
CURRENT_URL=""
if [ -f "$DEST/settings.sh" ]; then
    # shellcheck source-path=SCRIPTDIR source=settings.sh
    CURRENT_URL="$(. "$DEST/settings.sh"; printf '%s' "$HA_WEBHOOK_URL")"
fi
if [ -n "$CURRENT_URL" ]; then
    read -r -p "Home Assistant webhook URL [$CURRENT_URL]: " URL
    URL="${URL:-$CURRENT_URL}"
else
    read -r -p "Home Assistant webhook URL (https://.../api/webhook/...): " URL
fi
case "$URL" in
    http*://*/api/webhook/?*) ;;
    *) echo "This does not look like a Home Assistant webhook URL (.../api/webhook/<id>)." >&2; exit 1 ;;
esac

mkdir -p "$DEST" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Some installers (e.g. VPN clients) create ~/Library/LaunchAgents as root
if [ ! -w "$HOME/Library/LaunchAgents" ]; then
    echo "$HOME/Library/LaunchAgents is not writable (owner: $(stat -f '%Su' "$HOME/Library/LaunchAgents"))." >&2
    echo "Fix it once with administrator rights, then run this installer again:" >&2
    echo "  sudo chown \"\$(whoami)\" ~/Library/LaunchAgents" >&2
    exit 1
fi

# Stop a running instance
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "TeamsBusyLight/teams-busy-light.sh" 2>/dev/null || true

# Keep an existing settings.sh (only the URL is replaced)
if [ ! -f "$DEST/settings.sh" ]; then
    cp "$SRC/settings.sh" "$DEST/settings.sh"
fi
awk -v url="$URL" '/^HA_WEBHOOK_URL=/ { print "HA_WEBHOOK_URL=\"" url "\""; next } { print }' \
    "$DEST/settings.sh" > "$DEST/settings.sh.tmp"
mv "$DEST/settings.sh.tmp" "$DEST/settings.sh"

cp "$SRC/teams-busy-light.sh" "$DEST/"
rm -f "$DEST/languages.sh"
chmod +x "$DEST/teams-busy-light.sh"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Build the app once; rebuilding would change its signature and macOS would
# ask for the access again. An incomplete or older app is rebuilt.
if [ "$(/usr/libexec/PlistBuddy -c 'Print :TeamsBusyLightBuild' "$APP/Contents/Info.plist" 2>/dev/null)" != "$APP_BUILD" ]; then
    rm -rf "$APP"
    echo "Creating $APP"
    # $HOME is expanded by the shell that "do shell script" starts
    # shellcheck disable=SC2016
    osacompile -o "$APP" -e '
try
    do shell script "exec /bin/bash \"$HOME/Library/Application Support/TeamsBusyLight/teams-busy-light.sh\" >> \"$HOME/Library/Logs/TeamsBusyLight.log\" 2>&1"
end try'
    # Background app without Dock icon, with an own bundle identifier
    plutil -replace LSUIElement -bool YES "$APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$APP_ID" "$APP/Contents/Info.plist"
    plutil -replace CFBundleName -string "Teams Busy Light" "$APP/Contents/Info.plist"
    # Name shown in permission prompts (e.g. local network) instead of "applet"
    plutil -replace CFBundleDisplayName -string "Teams Busy Light" "$APP/Contents/Info.plist"
    plutil -replace TeamsBusyLightBuild -string "$APP_BUILD" "$APP/Contents/Info.plist"
    # App icon from icon.png (the brand icon of the integration). Newer
    # osacompile versions add an asset catalog that would take precedence.
    if [ -f "$SRC/icon.png" ]; then
        ICONSET="$(mktemp -d)/applet.iconset"
        mkdir -p "$ICONSET"
        for size in 16 32 128 256 512; do
            sips -z "$size" "$size" "$SRC/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
            if [ "$size" -le 256 ]; then
                sips -z $((size * 2)) $((size * 2)) "$SRC/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
            fi
        done
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/applet.icns"
        rm -rf "$(dirname "$ICONSET")" "$APP/Contents/Resources/Assets.car"
        plutil -remove CFBundleIconName "$APP/Contents/Info.plist" 2>/dev/null || true
        plutil -replace CFBundleIconFile -string applet "$APP/Contents/Info.plist"
    fi
    codesign --force --sign - "$APP"
fi

# Start the app at login via LaunchServices, restart it if it stops
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>-g</string>
        <string>-a</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Installed to: $DEST"
echo "App:          $APP"
echo "Log file:     $LOG"
echo "Teams Busy Light is running and starts automatically after login."
echo "If macOS asks whether \"Teams Busy Light\" may access data from other apps or find"
echo "devices on your local network, click Allow."

#!/bin/bash
#
# Builds "Teams Busy Light.app" (Universal: Apple silicon and Intel) into
# macos/build. Needs the Xcode Command Line Tools (xcode-select --install).
#
# Signing (the same certificate keeps the permissions granted by macOS
# across updates):
#   MACOS_SIGNING_P12        base64 of the .p12 from create-signing-certificate.sh
#   MACOS_SIGNING_PASSWORD   its password
# or SIGNING_IDENTITY with the name or SHA-1 of a certificate in the keychain.
# Without them the app is signed ad hoc.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC/build"
APP="$BUILD/Teams Busy Light.app"
MANIFEST="$SRC/../custom_components/teams_status/manifest.json"
VERSION="$(plutil -extract version raw -o - "$MANIFEST" 2>/dev/null || echo 0.0.0)"
TARGET="13.0"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    echo "Compiling for $arch"
    xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos$TARGET" \
        -o "$BUILD/TeamsBusyLight-$arch" "$SRC"/app/*.swift
done
lipo -create -output "$APP/Contents/MacOS/TeamsBusyLight" "$BUILD"/TeamsBusyLight-arm64 "$BUILD"/TeamsBusyLight-x86_64
rm "$BUILD"/TeamsBusyLight-arm64 "$BUILD"/TeamsBusyLight-x86_64

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.teamsbusylight.app</string>
    <key>CFBundleName</key>
    <string>Teams Busy Light</string>
    <key>CFBundleDisplayName</key>
    <string>Teams Busy Light</string>
    <key>CFBundleExecutable</key>
    <string>TeamsBusyLight</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>LSMinimumSystemVersion</key>
    <string>$TARGET</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Teams Busy Light sends your Teams status to Home Assistant in your local network.</string>
</dict>
</plist>
EOF

# App icon from icon.png (the brand icon of the integration)
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    if [ "$size" -le 256 ]; then
        sips -z $((size * 2)) $((size * 2)) "$SRC/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Signing
KEYCHAIN=""
cleanup() {
    if [ -n "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    fi
}
trap cleanup EXIT

IDENTITY="${SIGNING_IDENTITY:--}"
SIGN_OPTIONS=()
if [ -n "${MACOS_SIGNING_P12:-}" ]; then
    # Temporary keychain, removed again after signing
    KEYCHAIN="$BUILD/signing.keychain-db"
    KEYCHAIN_PASSWORD="$(uuidgen)"
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    printf '%s' "$MACOS_SIGNING_P12" | base64 --decode > "$BUILD/signing.p12"
    security import "$BUILD/signing.p12" -k "$KEYCHAIN" -P "${MACOS_SIGNING_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
    rm -f "$BUILD/signing.p12"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    # The self-signed certificate is not trusted, so it is selected by its SHA-1
    IDENTITY="$(security find-certificate -a -Z "$KEYCHAIN" | awk '/^SHA-1 hash:/ { print $3; exit }')"
    SIGN_OPTIONS=(--keychain "$KEYCHAIN")
fi

codesign --force --sign "$IDENTITY" ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (version $VERSION)"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^.*designated => /Designated requirement: /p'

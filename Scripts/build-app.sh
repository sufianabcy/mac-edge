#!/bin/bash
# Builds EdgePal.app and installs it in ~/Applications.
# Usage: bash Scripts/build-app.sh          (build and install)
#        bash Scripts/build-app.sh --run    (build, install, then open it)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "macOS $(sw_vers -productVersion) · $(swift --version 2>&1 | head -n 1)"
swift build -c release --product EdgePal
swift build -c release --product EdgePalMedia

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/EdgePal.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EdgePal" "$APP/Contents/MacOS/EdgePal"
cp "$BIN_DIR/libEdgePalMedia.dylib" "$APP/Contents/Resources/"
cp Support/media-helper.pl "$APP/Contents/Resources/"
cp Support/Info.plist "$APP/Contents/Info.plist"
chmod -R u+rwX,go+rX "$APP"
xattr -cr "$APP" 2>/dev/null || true

# macOS remembers Accessibility permission by the app's signature. An ad-hoc signature ("-")
# changes with every build, so you'd have to re-allow EdgePal after each one. If you create a
# code-signing certificate named "EdgePal Dev" in Keychain Access (Certificate Assistant →
# Create a Certificate → Code Signing), it's used instead and the permission sticks.
SIGN_IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "EdgePal Dev"; then
    SIGN_IDENTITY="EdgePal Dev"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/libEdgePalMedia.dylib"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Signed with: $SIGN_IDENTITY"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Support/Info.plist)"
mkdir -p dist
rm -f dist/EdgePal-*.zip
ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/EdgePal-$VERSION.zip"
echo "Release zip: dist/EdgePal-$VERSION.zip"

INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
pkill -x EdgePal 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALL_DIR/EdgePal.app"
cp -R "$APP" "$INSTALL_DIR/EdgePal.app"
echo "Installed: $INSTALL_DIR/EdgePal.app"

if [[ "${1:-}" == "--run" ]]; then
    open "$INSTALL_DIR/EdgePal.app"
fi

#!/bin/bash
# Build Headroom.app (release), with icon and an ad-hoc signature, into ./dist.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Headroom
swift build -c release --product headroom-cli
BIN=.build/release
APP=dist/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Headroom" "$APP/Contents/MacOS/Headroom"
cp "$BIN/headroom-cli" "$APP/Contents/Resources/headroom-cli"

# Icon: rendered by the app, sliced into an .icns.
ICONSET=$(mktemp -d)/Headroom.iconset
mkdir -p "$ICONSET"
"$BIN/Headroom" --icon "$ICONSET/base.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Headroom.icns"

VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
# Optional release feed (see scripts/release.sh); empty = the app never checks for updates.
FEED="${HEADROOM_UPDATE_FEED:-}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>app.headroom.Headroom</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>HeadroomUpdateFeed</key><string>${FEED}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Headroom</string>
</dict></plist>
PLIST

# Signing. Default: ad-hoc (runs on this Mac). For other Macs set HEADROOM_SIGN_ID to your
# "Developer ID Application: …" identity (hardened runtime + timestamp), and HEADROOM_NOTARY_PROFILE
# to a profile saved with `xcrun notarytool store-credentials` to notarize and staple.
SIGN_ID="${HEADROOM_SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP" >/dev/null
else
  # Inside out, no --deep: the bundled CLI first, then the app.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/Resources/headroom-cli"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if [ -n "${HEADROOM_NOTARY_PROFILE:-}" ]; then
    ZIP=$(mktemp -d)/Headroom.zip
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$HEADROOM_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
    ditto -c -k --keepParent "$APP" dist/Headroom.zip
    echo "notarized: dist/Headroom.zip is ready to share"
  fi
fi
echo "built $APP ($(du -sh "$APP" | cut -f1))"

# Install next to the source: the repo lives in /Applications/Headroom, so the app the user
# launches is /Applications/Headroom/Headroom.app (Launchpad, Spotlight and login items find it).
if [ "${1:-}" != "--no-install" ]; then
  pkill -x Headroom 2>/dev/null || true
  rm -rf Headroom.app
  cp -R "$APP" Headroom.app
  cp "$BIN/headroom-cli" headroom-cli
  echo "installed $(pwd)/Headroom.app and $(pwd)/headroom-cli"
fi

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

VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1.0)
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Headroom</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
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

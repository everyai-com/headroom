#!/bin/bash
# Build the Mac App Store edition: sandboxed (-DAPPSTORE), universal, signed with Apple Distribution,
# the provisioning profile embedded, packaged as a signed .pkg in ./dist ready for App Store Connect.
#
#   scripts/appstore.sh                 build dist/Headroom-AppStore.pkg
#   scripts/appstore.sh --upload        …then upload it with `asc builds upload` (asks App Store Connect
#                                        for the app by bundle ID; needs `asc auth login` done once)
#
# Signing assets (made once with asc, see docs/APPSTORE.md) live outside the repo in ~/.headroom-signing:
#   Headroom_AppStore.provisionprofile, and the "Apple Distribution" and "3rd Party Mac Developer
#   Installer" identities in the login keychain. Override with HEADROOM_MAS_* below.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${HEADROOM_MAS_BUNDLE_ID:-com.saphaare.headroom}"
TEAM="${HEADROOM_MAS_TEAM:-M359MD8CXK}"
APP_SIGN="${HEADROOM_MAS_SIGN_ID:-Apple Distribution: SAPHAARE LABS PRIVATE LIMITED ($TEAM)}"
PKG_SIGN="${HEADROOM_MAS_INSTALLER_ID:-3rd Party Mac Developer Installer: SAPHAARE LABS PRIVATE LIMITED ($TEAM)}"
PROFILE="${HEADROOM_MAS_PROFILE:-$HOME/.headroom-signing/Headroom_AppStore.provisionprofile}"
ENTITLEMENTS=scripts/appstore/Headroom.entitlements
[ -f "$PROFILE" ] || { echo "no provisioning profile at $PROFILE (see docs/APPSTORE.md)"; exit 1; }

INTENT_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
              -Xswiftc -Xfrontend -Xswiftc "$(pwd)/scripts/appintents-protocols.json")
BUILD_DIR=.build/appstore-release
swift build -c release --product Headroom --arch arm64 --arch x86_64 --build-path "$BUILD_DIR" \
  -Xswiftc -DAPPSTORE "${INTENT_FLAGS[@]}"
BIN="$BUILD_DIR/apple/Products/Release"
APP=dist/appstore/Headroom.app
rm -rf dist/appstore
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Headroom" "$APP/Contents/MacOS/Headroom"
lipo -info "$APP/Contents/MacOS/Headroom"

# Icon: rendered by the app, sliced into an .icns (the unsigned build runs outside the sandbox).
ICONSET=$(mktemp -d)/Headroom.iconset
mkdir -p "$ICONSET"
"$BIN/Headroom" --icon "$ICONSET/base.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Headroom.icns"

# Shortcuts & Siri metadata, as in bundle.sh.
if xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  LISTS=$(mktemp -d)
  ls "$(pwd)"/Sources/Headroom/*.swift > "$LISTS/sources.txt"
  find "$(pwd)/$BUILD_DIR" -path "*Headroom.build*" -name "*.swiftconstvalues" > "$LISTS/constvals.txt"
  xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" --module-name Headroom \
    --sdk-root "$(xcrun --show-sdk-path --sdk macosx)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 15.0 --target-triple "arm64-apple-macosx15.0" \
    --binary-file "$APP/Contents/MacOS/Headroom" --source-file-list "$LISTS/sources.txt" \
    --swift-const-vals-list "$LISTS/constvals.txt" --force --quiet-warnings >/dev/null || echo "(App Intents metadata skipped)"
fi

VERSION=$(cat VERSION)
# Every upload needs a higher build number; the commit count only grows.
BUILD="${HEADROOM_MAS_BUILD:-$(git rev-list --count HEAD)}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>Headroom</string>
  <key>CFBundleIconName</key><string>Headroom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© 2026 SAPHAARE LABS PRIVATE LIMITED</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
    <key>CFBundleURLSchemes</key><array><string>headroom</string></array>
  </dict></array>
</dict></plist>
PLIST

cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox" || { echo "not sandboxed!"; exit 1; }

PKG=dist/Headroom-AppStore.pkg
productbuild --component "$APP" /Applications --sign "$PKG_SIGN" "$PKG"
pkgutil --check-signature "$PKG" | head -3
echo "built $PKG ($(du -h "$PKG" | cut -f1)) — ${BUNDLE_ID} ${VERSION} (${BUILD})"

if [ "${1:-}" = "--upload" ]; then
  APP_ID=$(asc apps list --bundle-id "$BUNDLE_ID" --output json | python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])")
  asc builds upload --app "$APP_ID" --pkg "$PKG" --version "$VERSION" --build-number "$BUILD" --wait
fi

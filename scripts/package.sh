#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
VERSION=0.1.5
OUT="$PWD/dist"
APP="$OUT/DroidBridge.app"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB_PATH:-$SDK/platform-tools/adb}"
SCRCPY="${SCRCPY_PATH:-$(command -v scrcpy)}"
SERVER="${SCRCPY_SERVER_PATH:-/opt/homebrew/share/scrcpy/scrcpy-server}"
[ -x "$ADB" ] || { echo "Missing adb: $ADB" >&2; exit 1; }
[ -f "$SERVER" ] || { echo "Missing scrcpy server: $SERVER" >&2; exit 1; }
SCRCPY_VERSION="$("$SCRCPY" --version | head -n 1)"
[[ "$SCRCPY_VERSION" == "scrcpy 5.0.1 "* ]] || { echo "Pinned scrcpy 5.0.1 required, got $SCRCPY_VERSION" >&2; exit 1; }
swift build -c release
scripts/build-icon-helper.sh
mkdir -p "$OUT"
mkdir -p .build/package-backups
if [ -e "$APP" ]; then mv "$APP" ".build/package-backups/DroidBridge.previous.$(date +%s).app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Runtime/bin" "$APP/Contents/Resources/Runtime/share/scrcpy" "$APP/Contents/Resources/Runtime/lib" "$APP/Contents/Resources/licenses"
cp .build/release/DroidBridge "$APP/Contents/MacOS/"
cp .build/release/DroidBridgeSupervisor "$APP/Contents/Resources/Runtime/bin/"
cp .build/release/DroidBridgeAvailability "$APP/Contents/Resources/Runtime/bin/"
cp "$ADB" "$APP/Contents/Resources/Runtime/bin/adb"
cp "$SCRCPY" "$APP/Contents/Resources/Runtime/bin/scrcpy"
cp "$SERVER" "$APP/Contents/Resources/Runtime/share/scrcpy/scrcpy-server"
mkdir -p "$APP/Contents/Resources/Runtime/share/droidbridge"
cp .build/icon-helper/icon-helper.jar "$APP/Contents/Resources/Runtime/share/droidbridge/icon-helper.jar"
python3 scripts/bundle-dylibs.py "$APP/Contents/Resources/Runtime"

if [ -f Resources/DroidBridge.icns ]; then cp Resources/DroidBridge.icns "$APP/Contents/Resources/"; fi
for file in README.md ARCHITECTURE.md BUILD.md TESTING.md COMPATIBILITY.md KNOWN_ISSUES.md PIXEL_VERIFICATION.md THIRD_PARTY.md WRAPPER_DESIGN.md APP_ONBOARDING_DESIGN.md; do
    if [ -f "$file" ]; then cp "$file" "$APP/Contents/Resources/"; fi
done
if [ -f scripts/collect-licenses.py ]; then python3 scripts/collect-licenses.py; fi
if [ -d Resources/licenses ]; then cp -R Resources/licenses/. "$APP/Contents/Resources/licenses/"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleName</key><string>DroidBridge</string><key>CFBundleDisplayName</key><string>DroidBridge</string><key>CFBundleIdentifier</key><string>app.droidbridge.desktop</string><key>CFBundleExecutable</key><string>DroidBridge</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>10</string><key>DroidBridgeManagedNamingVersion</key><integer>2</integer><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/><key>NSHumanReadableCopyright</key><string>Copyright © 2026 DroidBridge contributors</string></dict></plist>
PLIST
find "$APP/Contents/Resources/Runtime" -type f \( -name '*.dylib' -o -name adb -o -name scrcpy -o -name DroidBridgeSupervisor -o -name DroidBridgeAvailability \) -print0 | while IFS= read -r -d '' item; do codesign --force --sign - "$item"; done
"$APP/Contents/Resources/Runtime/bin/adb" version > "$APP/Contents/Resources/Runtime/versions.txt"
"$APP/Contents/Resources/Runtime/bin/scrcpy" --version >> "$APP/Contents/Resources/Runtime/versions.txt"
shasum -a 256 "$SERVER" >> "$APP/Contents/Resources/Runtime/versions.txt"
PLAYER="$APP/Contents/Resources/Runtime/Player.app"
mkdir -p "$PLAYER/Contents/MacOS" "$PLAYER/Contents/Resources"
cp "$APP/Contents/Resources/Runtime/bin/scrcpy" "$PLAYER/Contents/MacOS/scrcpy"
ln -s ../../lib "$PLAYER/Contents/lib"
cp "$APP/Contents/Resources/DroidBridge.icns" "$PLAYER/Contents/Resources/"
cat > "$PLAYER/Contents/Info.plist" <<'PLAYERPLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.droidbridge.player</string><key>CFBundleName</key><string>DroidBridge Player</string><key>CFBundleExecutable</key><string>scrcpy</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>5.0.1</string><key>CFBundleVersion</key><string>1</string><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLAYERPLIST
codesign --force --sign - "$PLAYER"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "$OUT/dmg-stage.XXXXXX")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DroidBridge -srcfolder "$STAGE" -ov -format UDZO "$OUT/DroidBridge-$VERSION-arm64.dmg"
rm -rf "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/DroidBridge-$VERSION-arm64.zip"
(cd "$OUT" && shasum -a 256 "DroidBridge-$VERSION-arm64.dmg" "DroidBridge-$VERSION-arm64.zip" > SHA256SUMS)
echo "Packaged $APP"

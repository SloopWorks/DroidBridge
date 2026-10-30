#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
VERSION=0.1.8
sign_adhoc() {
    local signing_attempt
    for signing_attempt in 1 2 3; do
        if codesign --force --sign - "$1"; then return 0; fi
        [ "$signing_attempt" -eq 3 ] || sleep 0.2
    done
    return 1
}
OUT="$PWD/dist"
PUBLISHED_APP="$OUT/DroidBridge.app"
mkdir -p "$PWD/.build"
BUILD_STAGE=$(mktemp -d "$PWD/.build/droidbridge-package.XXXXXX")
# Assemble all mutable resources outside an application bundle. Publish once.
APP="$BUILD_STAGE/DroidBridge.bundle"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="${ADB_PATH:-$SDK/platform-tools/adb}"
SCRCPY="${SCRCPY_PATH:-$(command -v scrcpy)}"
SERVER="${SCRCPY_SERVER_PATH:-/opt/homebrew/share/scrcpy/scrcpy-server}"
[ -x "$ADB" ] || { echo "Missing adb: $ADB" >&2; exit 1; }
[ -f "$SERVER" ] || { echo "Missing scrcpy server: $SERVER" >&2; exit 1; }
SCRCPY_VERSION="$("$SCRCPY" --version | head -n 1)"
[[ "$SCRCPY_VERSION" == "scrcpy 5.0.1 "* ]] || { echo "Pinned scrcpy 5.0.1 required, got $SCRCPY_VERSION" >&2; exit 1; }
scripts/build-audio-client.sh
swift build -c release
scripts/build-icon-helper.sh
mkdir -p "$OUT"
mkdir -p .build/package-backups
RUNTIME_STAGE=$(mktemp -d "$PWD/.build/droidbridge-runtime.XXXXXX")
RUNTIME="$RUNTIME_STAGE/Runtime"
# Relocate Mach-O files outside an application bundle, then assemble and sign.
mkdir -p "$APP/Contents/MacOS" "$RUNTIME/bin" "$RUNTIME/share/scrcpy" "$RUNTIME/lib" "$APP/Contents/Resources/licenses"
cp .build/release/DroidBridge "$APP/Contents/MacOS/"
cp .build/release/DroidBridgeSupervisor "$RUNTIME/bin/"
cp .build/release/DroidBridgeAvailability "$RUNTIME/bin/"
cp "$ADB" "$RUNTIME/bin/adb"
cp "$SCRCPY" "$RUNTIME/bin/scrcpy"
cp .build/audio-client/DroidBridgeAudioClient "$RUNTIME/bin/"
cp "$SERVER" "$RUNTIME/share/scrcpy/scrcpy-server"
mkdir -p "$RUNTIME/share/droidbridge"
mkdir -p "$APP/Contents/Resources/licenses/droidbridge-audio-client"
cp scripts/patches/audio-output-ready.patch "$APP/Contents/Resources/licenses/droidbridge-audio-client/"
cp Vendor/scrcpy/LICENSE "$APP/Contents/Resources/licenses/droidbridge-audio-client/"
printf 'Modified pinned scrcpy 5.0.1 source a60891aea193d92e7e5c3942700eca63f9d19a5f: output readiness, supervised audio identity, unique staged server path and non-rebinding forward lifecycle. Build: scripts/build-audio-client.sh in SloopWorks/DroidBridge.\n' > "$APP/Contents/Resources/licenses/droidbridge-audio-client/NOTICE.txt"
cp .build/icon-helper/icon-helper.jar "$RUNTIME/share/droidbridge/icon-helper.jar"
python3 scripts/bundle-dylibs.py "$RUNTIME"
mv "$RUNTIME" "$APP/Contents/Resources/Runtime"
if [ -d "$RUNTIME_STAGE/licenses" ]; then ditto "$RUNTIME_STAGE/licenses" "$APP/Contents/Resources/licenses"; fi
rm -rf "$RUNTIME_STAGE"
RUNTIME="$APP/Contents/Resources/Runtime"

if [ -f Resources/DroidBridge.icns ]; then cp Resources/DroidBridge.icns "$APP/Contents/Resources/"; fi
for file in README.md ARCHITECTURE.md BUILD.md TESTING.md COMPATIBILITY.md KNOWN_ISSUES.md PIXEL_VERIFICATION.md THIRD_PARTY.md WRAPPER_DESIGN.md APP_ONBOARDING_DESIGN.md LAUNCHER_UX_DESIGN.md AUDIO_DESIGN.md; do
    if [ -f "$file" ]; then cp "$file" "$APP/Contents/Resources/"; fi
done
if [ -f scripts/collect-licenses.py ]; then python3 scripts/collect-licenses.py; fi
if [ -d Resources/licenses ]; then cp -R Resources/licenses/. "$APP/Contents/Resources/licenses/"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleName</key><string>DroidBridge</string><key>CFBundleDisplayName</key><string>DroidBridge</string><key>CFBundleIdentifier</key><string>app.droidbridge.desktop</string><key>CFBundleExecutable</key><string>DroidBridge</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>14</string><key>DroidBridgeManagedNamingVersion</key><integer>2</integer><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/><key>NSHumanReadableCopyright</key><string>Copyright © 2026 DroidBridge contributors</string></dict></plist>
PLIST
find "$RUNTIME" -type f \( -name '*.dylib' -o -name adb -o -name scrcpy -o -name DroidBridgeSupervisor -o -name DroidBridgeAvailability -o -name DroidBridgeAudioClient \) -print0 | while IFS= read -r -d '' item; do sign_adhoc "$item"; done
"$RUNTIME/bin/adb" version > "$RUNTIME/versions.txt"
"$RUNTIME/bin/scrcpy" --version >> "$RUNTIME/versions.txt"
shasum -a 256 "$SERVER" >> "$RUNTIME/versions.txt"
PLAYER="$RUNTIME/Player.app"
mkdir -p "$PLAYER/Contents/MacOS" "$PLAYER/Contents/Resources"
cp "$RUNTIME/bin/scrcpy" "$PLAYER/Contents/MacOS/scrcpy"
ln -s ../../lib "$PLAYER/Contents/lib"
cp "$APP/Contents/Resources/DroidBridge.icns" "$PLAYER/Contents/Resources/"
cat > "$PLAYER/Contents/Info.plist" <<'PLAYERPLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.droidbridge.player</string><key>CFBundleName</key><string>DroidBridge Player</string><key>CFBundleExecutable</key><string>scrcpy</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>5.0.1</string><key>CFBundleVersion</key><string>1</string><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLAYERPLIST
sign_adhoc "$PLAYER"
mv "$APP" "$BUILD_STAGE/DroidBridge.app"
APP="$BUILD_STAGE/DroidBridge.app"
sign_adhoc "$APP"
codesign --verify --deep --strict "$APP"
if [ -e "$PUBLISHED_APP" ]; then mv "$PUBLISHED_APP" ".build/package-backups/DroidBridge.previous.$(date +%s).app"; fi
mv "$APP" "$PUBLISHED_APP"
APP="$PUBLISHED_APP"
rmdir "$BUILD_STAGE"
codesign --verify --deep --strict "$APP"
STAGE="$(mktemp -d "$OUT/dmg-stage.XXXXXX")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DroidBridge -srcfolder "$STAGE" -ov -format UDZO "$OUT/DroidBridge-$VERSION-arm64.dmg"
rm -rf "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/DroidBridge-$VERSION-arm64.zip"
(cd "$OUT" && shasum -a 256 "DroidBridge-$VERSION-arm64.dmg" "DroidBridge-$VERSION-arm64.zip" > SHA256SUMS)
echo "Packaged $APP"

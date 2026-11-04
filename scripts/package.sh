#!/bin/bash
set -euo pipefail
# Capture the caller's Python before adding Homebrew tools. Some Homebrew
# Python installations have incompatible extension-library dependencies.
PACKAGE_PYTHON="$(command -v python3)"
case "$PACKAGE_PYTHON" in /*) ;; *) PACKAGE_PYTHON="$PWD/$PACKAGE_PYTHON" ;; esac
[ -f "$PACKAGE_PYTHON" ] && [ -x "$PACKAGE_PYTHON" ] || { echo "A working caller python3 is required" >&2; exit 1; }
"$PACKAGE_PYTHON" -c 'import argparse, hashlib, json, os, pathlib, plistlib, re, secrets, shutil, stat, subprocess, sys, zipfile, zlib, xml.parsers.expat; print("Package Python:", sys.executable, sys.version.split()[0])'
export PATH="$(dirname "$PACKAGE_PYTHON"):/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
VERSION="${DROIDBRIDGE_VERSION:-0.2.0}"
BUILD_NUMBER="${DROIDBRIDGE_BUILD_NUMBER:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid build number" >&2; exit 1; }
# Validate all release credentials before builds or publication can replace a candidate.
SIGNING_MODE="${DROIDBRIDGE_SIGNING_MODE:-adhoc}"
SOURCE_COMMIT=""
if [ "$SIGNING_MODE" = developer-id ]; then
    SOURCE_COMMIT="$("$PACKAGE_PYTHON" scripts/release_signing.py source-revision)"
fi
"$PACKAGE_PYTHON" scripts/release_signing.py preflight
COMPANION_APK="${DROIDBRIDGE_COMPANION_APK:-}"
sign_code() {
    local sign_target="$1"
    shift
    local signing_attempt
    for signing_attempt in 1 2 3; do
        if "$PACKAGE_PYTHON" scripts/release_signing.py sign --path "$sign_target" "$@"; then return 0; fi
        [ "$signing_attempt" -eq 3 ] || sleep 0.2
    done
    return 1
}
OUT="${DROIDBRIDGE_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
PUBLISHED_APP="$OUT/DroidBridge.app"
mkdir -p "$PWD/.build"
BUILD_STAGE=$(mktemp -d "$PWD/.build/droidbridge-package.XXXXXX")
# Assemble all mutable resources outside an application bundle. Publish once.
APP="$BUILD_STAGE/DroidBridge.bundle"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "$COMPANION_APK" ]; then
    android_signing_properties="${DROIDBRIDGE_ANDROID_SIGNING:-$(AndroidCompanion/prepare-local-signing.py)}"
    DROIDBRIDGE_ANDROID_SIGNING="$android_signing_properties" AndroidCompanion/build.sh -PsloopworksInternalTools=false :app:assembleRelease
    COMPANION_APK="$PWD/AndroidCompanion/app/build/outputs/apk/release/app-release.apk"
fi
[ -f "$COMPANION_APK" ] || { echo "Missing release companion APK: $COMPANION_APK" >&2; exit 1; }
"$SDK/build-tools/35.0.0/apksigner" verify "$COMPANION_APK"
if [ -z "${ADB_PATH:-}" ]; then scripts/build-adb-runtime.sh; fi
ADB="${ADB_PATH:-$PWD/.build/adb-runtime/adb}"
if [ "$SIGNING_MODE" = developer-id ]; then
    # Keep source/build provenance beside this independently signed release cohort.
    SIGNED_ADB_ROOT=$(mktemp -d "$PWD/.build/release-adb-$VERSION-$BUILD_NUMBER.XXXXXX")
    "$PACKAGE_PYTHON" scripts/release_signing.py prepare-adb --source "$(dirname "$ADB")" --destination "$SIGNED_ADB_ROOT/adb-runtime"
    ADB="$SIGNED_ADB_ROOT/adb-runtime/adb"
fi
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
cp .build/release/DroidBridgeCompanionBroker "$RUNTIME/bin/"
mkdir -p "$APP/Contents/Resources/Companion"
cp "$COMPANION_APK" "$APP/Contents/Resources/Companion/DroidBridgeCompanion.apk"
"$PACKAGE_PYTHON" scripts/collect-companion-notices.py "$COMPANION_APK" "$APP/Contents/Resources/licenses/android-companion"
shasum -a 256 "$COMPANION_APK" | awk '{print $1 "  DroidBridgeCompanion.apk"}' > "$APP/Contents/Resources/Companion/APK-SHA256.txt"
"$PACKAGE_PYTHON" scripts/stage-adb-runtime.py --adb "$ADB" --destination "$RUNTIME/bin" --notices-destination "$APP/Contents/Resources/licenses/adb-source-runtime"
cp "$SCRCPY" "$RUNTIME/bin/scrcpy"
cp .build/audio-client/DroidBridgeAudioClient "$RUNTIME/bin/"
cp "$SERVER" "$RUNTIME/share/scrcpy/scrcpy-server"
mkdir -p "$RUNTIME/share/droidbridge"
mkdir -p "$APP/Contents/Resources/licenses/droidbridge-audio-client"
cp scripts/patches/audio-output-ready.patch "$APP/Contents/Resources/licenses/droidbridge-audio-client/"
cp Vendor/scrcpy/LICENSE "$APP/Contents/Resources/licenses/droidbridge-audio-client/"
printf 'Modified pinned scrcpy 5.0.1 source a60891aea193d92e7e5c3942700eca63f9d19a5f: output readiness, supervised audio identity, unique staged server path and non-rebinding forward lifecycle. Build: scripts/build-audio-client.sh in SloopWorks/DroidBridge.\n' > "$APP/Contents/Resources/licenses/droidbridge-audio-client/NOTICE.txt"
cp .build/icon-helper/icon-helper.jar "$RUNTIME/share/droidbridge/icon-helper.jar"
"$PACKAGE_PYTHON" scripts/bundle-dylibs.py "$RUNTIME"
mv "$RUNTIME" "$APP/Contents/Resources/Runtime"
if [ -d "$RUNTIME_STAGE/licenses" ]; then ditto "$RUNTIME_STAGE/licenses" "$APP/Contents/Resources/licenses"; fi
rm -rf "$RUNTIME_STAGE"
RUNTIME="$APP/Contents/Resources/Runtime"

if [ -f Resources/DroidBridge.icns ]; then cp Resources/DroidBridge.icns "$APP/Contents/Resources/"; fi
for file in README.md PRIVACY.md SUPPORT.md SECURITY.md ARCHITECTURE.md BUILD.md TESTING.md COMPATIBILITY.md KNOWN_ISSUES.md PIXEL_VERIFICATION.md THIRD_PARTY.md WRAPPER_DESIGN.md APP_ONBOARDING_DESIGN.md LAUNCHER_UX_DESIGN.md AUDIO_DESIGN.md; do
    if [ -f "$file" ]; then cp "$file" "$APP/Contents/Resources/"; fi
done
if [ -f scripts/collect-licenses.py ]; then "$PACKAGE_PYTHON" scripts/collect-licenses.py "$RUNTIME"; fi
if [ -d Resources/licenses ]; then cp -R Resources/licenses/. "$APP/Contents/Resources/licenses/"; fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleName</key><string>DroidBridge</string><key>CFBundleDisplayName</key><string>DroidBridge</string><key>CFBundleIdentifier</key><string>app.droidbridge.desktop</string><key>CFBundleExecutable</key><string>DroidBridge</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$VERSION</string><key>CFBundleVersion</key><string>$BUILD_NUMBER</string><key>DroidBridgeManagedNamingVersion</key><integer>2</integer><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/><key>NSCameraUsageDescription</key><string>Scan the pairing QR code shown on your Android phone to connect it to this Mac.</string><key>NSHumanReadableCopyright</key><string>Copyright © 2026 DroidBridge contributors</string></dict></plist>
PLIST
if [ -n "$SOURCE_COMMIT" ]; then
    /usr/libexec/PlistBuddy -c "Add :DroidBridgeSourceCommit string $SOURCE_COMMIT" "$APP/Contents/Info.plist"
fi
find "$RUNTIME" -type f \( -name '*.dylib' -o -name adb -o -name scrcpy -o -name DroidBridgeSupervisor -o -name DroidBridgeAvailability -o -name DroidBridgeCompanionBroker -o -name DroidBridgeAudioClient \) -print0 | while IFS= read -r -d '' item; do
    if [ -f "$RUNTIME/bin/adb-runtime.json" ] && [ "$(dirname "$item")" = "$RUNTIME/bin" ]; then
        case "$(basename "$item")" in adb|adb-lib*.dylib) continue ;; esac
    fi
    sign_code "$item"
done
"$PACKAGE_PYTHON" scripts/stage-adb-runtime.py --adb "$RUNTIME/bin/adb"
"$RUNTIME/bin/adb" version > "$RUNTIME/versions.txt"
"$RUNTIME/bin/scrcpy" --version >> "$RUNTIME/versions.txt"
shasum -a 256 "$SERVER" >> "$RUNTIME/versions.txt"
PLAYER="$RUNTIME/Player.app"
mkdir -p "$PLAYER/Contents/MacOS" "$PLAYER/Contents/Resources"
cp "$RUNTIME/bin/scrcpy" "$PLAYER/Contents/MacOS/scrcpy"
# A nested signed application must own its libraries; an escaping symlink makes
# standalone strict signature verification fail even when the outer app passes.
"$PACKAGE_PYTHON" scripts/verify-package.py "$PLAYER" --stage-player-libraries-from "$RUNTIME" --output "$BUILD_STAGE/player-libraries.json"
cp "$APP/Contents/Resources/DroidBridge.icns" "$PLAYER/Contents/Resources/"
cat > "$PLAYER/Contents/Info.plist" <<'PLAYERPLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.droidbridge.player</string><key>CFBundleName</key><string>DroidBridge Player</string><key>CFBundleExecutable</key><string>scrcpy</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>5.0.1</string><key>CFBundleVersion</key><string>1</string><key>CFBundleIconFile</key><string>DroidBridge</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLAYERPLIST
sign_code "$PLAYER"
"$PACKAGE_PYTHON" scripts/verify-package.py "$PLAYER" --player-only --output "$BUILD_STAGE/player-verification.json"
mv "$APP" "$BUILD_STAGE/DroidBridge.app"
APP="$BUILD_STAGE/DroidBridge.app"
sign_code "$APP" --entitlements "$PWD/Resources/Release.entitlements"
"$PACKAGE_PYTHON" scripts/verify-package.py "$APP" --signatures-only --output "$BUILD_STAGE/signature-verification.json"
codesign --verify --deep --strict "$APP"
EVIDENCE="$BUILD_STAGE/release-evidence"
mkdir -p "$EVIDENCE"
if [ "$SIGNING_MODE" = developer-id ]; then
    [ "$("$PACKAGE_PYTHON" scripts/release_signing.py source-revision)" = "$SOURCE_COMMIT" ] || { echo "Source revision changed during packaging" >&2; exit 1; }
    "$PACKAGE_PYTHON" scripts/release_signing.py verify --path "$APP" > "$EVIDENCE/developer-id.json"
    # Staple the app before creating any final delivery archive.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD_STAGE/notarization.zip"
    "$PACKAGE_PYTHON" scripts/release_signing.py notarize --path "$BUILD_STAGE/notarization.zip" --staple "$APP" --evidence "$EVIDENCE"
fi
STAGE="$(mktemp -d "$BUILD_STAGE/dmg-stage.XXXXXX")"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname DroidBridge -srcfolder "$STAGE" -ov -format UDZO "$BUILD_STAGE/DroidBridge-$VERSION-arm64.dmg"
rm -rf "$STAGE"
if [ "$SIGNING_MODE" = developer-id ]; then
    "$PACKAGE_PYTHON" scripts/release_signing.py sign --disk-image --path "$BUILD_STAGE/DroidBridge-$VERSION-arm64.dmg"
    "$PACKAGE_PYTHON" scripts/release_signing.py notarize --path "$BUILD_STAGE/DroidBridge-$VERSION-arm64.dmg" --staple "$BUILD_STAGE/DroidBridge-$VERSION-arm64.dmg" --evidence "$EVIDENCE"
    spctl --assess --type execute --verbose=2 "$APP" > "$EVIDENCE/gatekeeper.log" 2>&1
    "$PACKAGE_PYTHON" scripts/create-release-manifest.py --app "$APP" --dmg "$BUILD_STAGE/DroidBridge-$VERSION-arm64.dmg" --output "$BUILD_STAGE/release-manifest.json" --require-notarized --team-id "$DROIDBRIDGE_DEVELOPMENT_TEAM"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD_STAGE/DroidBridge-$VERSION-arm64.zip"
# Publish local outputs only after all required checks and notarization succeed.
if [ -e "$PUBLISHED_APP" ]; then mv "$PUBLISHED_APP" ".build/package-backups/DroidBridge.previous.$(date +%s).app"; fi
mv "$APP" "$PUBLISHED_APP"
for suffix in dmg zip; do mv "$BUILD_STAGE/DroidBridge-$VERSION-arm64.$suffix" "$OUT/"; done
if [ -f "$BUILD_STAGE/release-manifest.json" ]; then mv "$BUILD_STAGE/release-manifest.json" "$OUT/"; fi
cp "$BUILD_STAGE/signature-verification.json" "$EVIDENCE/"
"$PACKAGE_PYTHON" - "$EVIDENCE/package-inputs.json" "$SIGNING_MODE" "$VERSION" "$BUILD_NUMBER" "$ADB" <<'PY'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps(dict(zip(('signing_mode','version','build','adb'),sys.argv[2:])),indent=2)+'\n')
PY
if [ -e "$OUT/release-evidence-$VERSION-$BUILD_NUMBER" ]; then
    mv "$OUT/release-evidence-$VERSION-$BUILD_NUMBER" ".build/package-backups/evidence.previous.$(date +%s)"
fi
mv "$EVIDENCE" "$OUT/release-evidence-$VERSION-$BUILD_NUMBER"
rm "$BUILD_STAGE/player-libraries.json" "$BUILD_STAGE/player-verification.json" "$BUILD_STAGE/signature-verification.json"
rm -f "$BUILD_STAGE/notarization.zip"
rmdir "$BUILD_STAGE"
(cd "$OUT" && shasum -a 256 "DroidBridge-$VERSION-arm64.dmg" "DroidBridge-$VERSION-arm64.zip" > SHA256SUMS)
echo "Packaged $PUBLISHED_APP ($SIGNING_MODE)"

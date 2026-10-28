#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-wrapper-failure.XXXXXX)
QA_STATE="$HOME/Library/Application Support/DroidBridge/sessions-wrapper.json"
if [ -f "$QA_STATE" ]; then cp "$QA_STATE" "$QA_ROOT/prior-state"; fi
cleanup() {
  if [ -f "$QA_ROOT/prior-state" ]; then cp "$QA_ROOT/prior-state" "$QA_STATE"; else rm -f "$QA_STATE"; fi
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT
ln -s "$PWD/scripts/verify-wrapper-failure-fixture.py" "$QA_ROOT/adb"
ln -s "$PWD/scripts/verify-wrapper-failure-fixture.py" "$QA_ROOT/scrcpy"
chmod +x scripts/verify-wrapper-failure-fixture.py
touch "$QA_ROOT/server"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=red:s=64x64 -frames:v 1 -c:v libx264 -tune zerolatency -profile:v baseline -pix_fmt yuv420p -f h264 "$QA_ROOT/frame.h264"
printf '%s' native-clean > "$QA_ROOT/mode"
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/Launcher.swift Sources/DroidBridge/NativeWindow.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-wrapper-failure.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/qa-wrapper-failure
mkdir -p verification/launcher-fix/qa
DROIDBRIDGE_QA_H264="$QA_ROOT/frame.h264" DROIDBRIDGE_ICON_HELPER="$QA_ROOT/server" DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_SCRCPY="$QA_ROOT/scrcpy" DROIDBRIDGE_SERVER="$QA_ROOT/server" DROIDBRIDGE_QA_MODE="$QA_ROOT/mode" .build/qa-wrapper-failure --wrapper 2>&1 | tee verification/launcher-fix/qa/failure-retention.log
# An erroneous terminate(nil) exits zero before the assertions complete.
rg -q '^PASS: shipping wrapper retains' verification/launcher-fix/qa/failure-retention.log

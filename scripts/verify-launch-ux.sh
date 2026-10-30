#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-launch-ux.XXXXXX)
QA_STATE="$HOME/Library/Application Support/DroidBridge/sessions-wrapper.json"
if [ -f "$QA_STATE" ]; then cp -p "$QA_STATE" "$QA_ROOT/prior-state"; fi
cleanup() {
  if [ -f "$QA_ROOT/mode.listener-pids" ]; then
    while IFS= read -r QA_PID; do
      if ps -p "$QA_PID" -o command= | rg -F -q "fixture.py serve $QA_ROOT/mode"; then kill "$QA_PID" 2>/dev/null || true; fi
    done < "$QA_ROOT/mode.listener-pids"
  fi
  if [ -f "$QA_ROOT/prior-state" ]; then cp -p "$QA_ROOT/prior-state" "$QA_STATE"; else rm -f "$QA_STATE"; fi
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT
ln -s "$PWD/scripts/fixtures/launch-ux.py" "$QA_ROOT/adb"
ln -s "$PWD/scripts/fixtures/launch-ux.py" "$QA_ROOT/scrcpy"
touch "$QA_ROOT/server"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=red:s=64x64 -frames:v 1 -c:v libx264 -tune zerolatency -profile:v baseline -pix_fmt yuv420p -f h264 "$QA_ROOT/frame.h264"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=black:s=64x64 -frames:v 1 -c:v libx264 -tune zerolatency -profile:v baseline -pix_fmt yuv420p -f h264 "$QA_ROOT/black.h264"
printf '%s' native-present > "$QA_ROOT/mode"
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/Launcher.swift Sources/DroidBridge/LauncherUI.swift Sources/DroidBridge/PhoneDisplayControls.swift Sources/DroidBridge/ManagedAppNameRepair.swift Sources/DroidBridge/DeviceOnboarding.swift Sources/DroidBridge/DeviceOnboardingUI.swift Sources/DroidBridge/DeviceOnboardingAgent.swift Sources/DroidBridge/NativeWindow.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-launch-ux.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/qa-launch-ux
QA_OUT="${DROIDBRIDGE_QA_OUTPUT:-verification/launch-ux/qa}"
mkdir -p "$QA_OUT"
rm -f "$QA_OUT/results.json"
DROIDBRIDGE_ICON_HELPER="$QA_ROOT/server" DROIDBRIDGE_QA_BLACK_H264="$QA_ROOT/black.h264" DROIDBRIDGE_QA_H264="$QA_ROOT/frame.h264" DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_SCRCPY="$QA_ROOT/scrcpy" DROIDBRIDGE_SERVER="$QA_ROOT/server" DROIDBRIDGE_QA_MODE="$QA_ROOT/mode" .build/qa-launch-ux --wrapper --launch dev.droidbridge.testapp --serial qa-no-device --name 'Launch UX Probe' 2>&1 | tee "$QA_OUT/run.log"
rg -q '^PASS: launch UX' "$QA_OUT/run.log"

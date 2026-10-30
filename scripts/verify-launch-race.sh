#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-launch-race.XXXXXX)
QA_STATE="$HOME/Library/Application Support/DroidBridge/sessions-wrapper.json"
if [ -f "$QA_STATE" ]; then cp "$QA_STATE" "$QA_ROOT/prior-state"; fi
cleanup() {
  if [ -f "$QA_ROOT/prior-state" ]; then cp "$QA_ROOT/prior-state" "$QA_STATE"; else rm -f "$QA_STATE"; fi
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT
cat > "$QA_ROOT/adb" <<'ADB'
#!/bin/sh
case "$4" in
getprop) if [ "$5" = ro.build.version.sdk ]; then echo 35; else echo 1; fi ;;
cmd)
  if [ "$6" = resolve-activity ]; then
    touch "$DROIDBRIDGE_QA_MARKER"
    sleep 0.6
    echo dev.droidbridge.testapp/.MainActivity
  else
    echo package:/system/framework/framework-res.apk
  fi ;;
esac
ADB
cat > "$QA_ROOT/scrcpy" <<'SCRCPY'
#!/bin/sh
echo scrcpy 5.0.1
SCRCPY
chmod +x "$QA_ROOT/adb" "$QA_ROOT/scrcpy"
touch "$QA_ROOT/server"
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/Launcher.swift Sources/DroidBridge/LauncherUI.swift Sources/DroidBridge/PhoneDisplayControls.swift Sources/DroidBridge/ManagedAppNameRepair.swift Sources/DroidBridge/DeviceOnboarding.swift Sources/DroidBridge/DeviceOnboardingUI.swift Sources/DroidBridge/DeviceOnboardingAgent.swift Sources/DroidBridge/NativeWindow.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-launch-race.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/qa-launch-race
QA_OUT="${DROIDBRIDGE_QA_OUTPUT:-verification/review/launch-race}"
mkdir -p "$QA_OUT"
DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_SCRCPY="$QA_ROOT/scrcpy" DROIDBRIDGE_SERVER="$QA_ROOT/server" DROIDBRIDGE_QA_MARKER="$QA_ROOT/started" .build/qa-launch-race --wrapper 2>&1 | tee "$QA_OUT/run.log"

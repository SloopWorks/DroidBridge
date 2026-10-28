#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-intent.XXXXXX)
QA_STATE="$HOME/Library/Application Support/DroidBridge/sessions-wrapper.json"
if [ -f "$QA_STATE" ]; then cp "$QA_STATE" "$QA_ROOT/prior-state"; fi
cleanup() {
 if [ -f "$QA_ROOT/prior-state" ]; then cp "$QA_ROOT/prior-state" "$QA_STATE"; else rm -f "$QA_STATE"; fi
 rm -rf "$QA_ROOT"
}
trap cleanup EXIT
cat > "$QA_ROOT/adb" <<'ADB'
#!/bin/sh
if [ "$4" = getprop ]; then
 touch "$DROIDBRIDGE_QA_MARKER"
 sleep 0.4
 echo 1
else
 echo package:/system/framework/framework-res.apk
fi
ADB
chmod +x "$QA_ROOT/adb"
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/Launcher.swift Sources/DroidBridge/DeviceOnboarding.swift Sources/DroidBridge/DeviceOnboardingUI.swift Sources/DroidBridge/DeviceOnboardingAgent.swift Sources/DroidBridge/NativeWindow.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-intent-replacement.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/verify-intent-replacement
DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_QA_MARKER="$QA_ROOT/ready" .build/verify-intent-replacement --wrapper

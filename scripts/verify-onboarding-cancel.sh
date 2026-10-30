#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-onboarding-cancel.XXXXXX)
trap 'rm -rf "$QA_ROOT"' EXIT
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
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/Launcher.swift Sources/DroidBridge/LauncherUI.swift Sources/DroidBridge/PhoneDisplayControls.swift Sources/DroidBridge/AudioControls.swift Sources/DroidBridge/ManagedAppNameRepair.swift Sources/DroidBridge/DeviceOnboarding.swift Sources/DroidBridge/DeviceOnboardingUI.swift Sources/DroidBridge/DeviceOnboardingAgent.swift Sources/DroidBridge/NativeWindow.swift Sources/DroidBridge/MacAppWrapper.swift scripts/verify-onboarding-cancel.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/verify-onboarding-cancel
DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_QA_MARKER="$QA_ROOT/ready" .build/verify-onboarding-cancel

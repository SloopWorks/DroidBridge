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
UI_SOURCES=()
for source in Sources/DroidBridge/*.swift; do
    [[ "$source" == */main.swift ]] || UI_SOURCES+=("$source")
done
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-onboarding-cancel.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o "$BIN"/AnonymousUsage.build/*.o -o .build/verify-onboarding-cancel
DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_QA_MARKER="$QA_ROOT/ready" .build/verify-onboarding-cancel

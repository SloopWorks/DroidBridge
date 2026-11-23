#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DROIDBRIDGE_QUICK_HOST:?Set packaged shipping DroidBridge.app path}"
EVIDENCE="$PWD/verification/quick-open-2026-11-21"
mkdir -p "$EVIDENCE"
QA_ROOT=$(mktemp -d /private/tmp/droidbridge-quick-open.XXXXXX)
chmod 700 "$QA_ROOT"
QA_RESULT=failed
cleanup() {
    if [ -d "$QA_ROOT/Logs" ]; then ditto "$QA_ROOT/Logs" "$EVIDENCE/session-logs-$QA_RESULT"; fi
    rm -rf "$QA_ROOT"
}
trap cleanup EXIT
exec > >(tee "$EVIDENCE/runtime.log") 2>&1
printf '%s\n' 'COMMAND: swift build'
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r QA_SOURCE; do UI_SOURCES+=("$QA_SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
printf '%s\n' 'COMMAND: swiftc -parse-as-library shipping UI + verify-quick-access.swift'
ditto "$DROIDBRIDGE_QUICK_HOST" "$QA_ROOT/QuickAccessQA.app"
QA_EXEC="$QA_ROOT/QuickAccessQA.app/Contents/MacOS/VerifyQuickAccess"
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-quick-access.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o "$BIN"/AnonymousUsage.build/*.o -o "$QA_EXEC"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable VerifyQuickAccess' "$QA_ROOT/QuickAccessQA.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.droidbridge.qa.quickaccess' "$QA_ROOT/QuickAccessQA.app/Contents/Info.plist"
printf 'COMMAND: %s --companion-qa-root %s --serial emulator-5580\n' "$QA_EXEC" "$QA_ROOT"
DROIDBRIDGE_GUI_EVIDENCE="$EVIDENCE" DROIDBRIDGE_QUICK_HOST="$DROIDBRIDGE_QUICK_HOST" "$QA_EXEC" --companion-qa-root "$QA_ROOT" --serial emulator-5580
QA_RESULT=passed

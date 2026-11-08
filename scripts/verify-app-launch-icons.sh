#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
EVIDENCE="${DROIDBRIDGE_LAUNCH_EVIDENCE:-$PWD/verification/app-launch-icons-2026-11-07/runtime}"
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/run.log") 2>&1
REVIEW_APP="${DROIDBRIDGE_LAUNCH_REVIEW_APP:?Set the packaged external review application}"
QA_ROOT=$(mktemp -d /private/tmp/droidbridge-app-icons.XXXXXX)
chmod 700 "$QA_ROOT"
printf '%s\n' '{"bulkWrapperOnboardingEnabled":false,"deviceAudioRoutes":{"emulator-5580":"phone"}}' > "$QA_ROOT/preferences.json"
cleanup() {
  cp -R "$QA_ROOT/Logs" "$EVIDENCE/" 2>/dev/null || true
  if [ "${QA_PASSED:-0}" = 1 ]; then rm -rf "$QA_ROOT"; else printf 'Retained failed QA root: %s\n' "$QA_ROOT"; fi
}
trap cleanup EXIT
printf '%s\n' 'COMMAND: swift build, then compile all shipping UI sources with actual-emulator wrapper fixture'
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r SOURCE; do UI_SOURCES+=("$SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-app-launch-icons.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o "$QA_ROOT/verify-app-icons"
printf '%s\n' 'COMMAND: packaged factory + Launch Services + actual decoded video, isolated scope on emulator-5580'
DROIDBRIDGE_LAUNCH_REVIEW_APP="$REVIEW_APP" DROIDBRIDGE_LAUNCH_EVIDENCE="$EVIDENCE" DROIDBRIDGE_ADB="$REVIEW_APP/Contents/Resources/Runtime/bin/adb" DROIDBRIDGE_ICON_HELPER="$REVIEW_APP/Contents/Resources/Runtime/share/droidbridge/icon-helper.jar" "$QA_ROOT/verify-app-icons" --companion-qa-root "$QA_ROOT" --serial emulator-5580
QA_PASSED=1

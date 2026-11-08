#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
EVIDENCE="${DROIDBRIDGE_RESOLVER_EVIDENCE:-$PWD/verification/app-launch-icons-2026-11-07/resolver}"
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/run.log") 2>&1
rm -f "$EVIDENCE/resolver-results.json"
QA_ROOT=$(mktemp -d /private/tmp/droidbridge-resolver.XXXXXX)
chmod 700 "$QA_ROOT"
trap 'rm -rf "$QA_ROOT"' EXIT
printf '%s\n' 'COMMAND: swiftc shipping UI sources except main + existing Core/Streaming objects + metadata-only resolver fixture'
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r SOURCE; do UI_SOURCES+=("$SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-app-launch-resolver.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o "$QA_ROOT/verify-resolver"
printf '%s\n' 'COMMAND: private resolver fixture --companion-qa-root <owned /private/tmp root> --serial emulator-5580'
DROIDBRIDGE_RESOLVER_EVIDENCE="$EVIDENCE" "$QA_ROOT/verify-resolver" --companion-qa-root "$QA_ROOT" --serial emulator-5580

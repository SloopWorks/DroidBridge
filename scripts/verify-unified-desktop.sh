#!/bin/bash
# Shipping AppKit composition with an anonymous broker; no device/credential/service access.
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /private/tmp/droidbridge-unified-desktop.XXXXXX)
chmod 700 "$QA_ROOT"
cleanup() { rm -rf "$QA_ROOT"; }
trap cleanup EXIT
EVIDENCE="$PWD/verification/unified-desktop/fixture"
mkdir -p "$EVIDENCE"
rm -f "$EVIDENCE/results.json"
exec > >(tee "$EVIDENCE/run.log") 2>&1
printf '%s\n' 'COMMAND: swift build'
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r QA_SOURCE; do UI_SOURCES+=("$QA_SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
printf '%s\n' 'COMMAND: swiftc shipping DroidBridge UI sources + isolated unified-desktop fixture'
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-unified-desktop.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o "$QA_ROOT/verify-unified-desktop"
printf '%s\n' 'COMMAND: private fixture executable --companion-qa-root <mode-700-private-root> --serial emulator-5580 (ADB/scrcpy disabled)'
DROIDBRIDGE_GUI_EVIDENCE="$EVIDENCE" DROIDBRIDGE_ADB=/usr/bin/false DROIDBRIDGE_SCRCPY=/usr/bin/false DROIDBRIDGE_SERVER="$QA_ROOT/nonexistent-server" "$QA_ROOT/verify-unified-desktop" --companion-qa-root "$QA_ROOT" --serial emulator-5580
